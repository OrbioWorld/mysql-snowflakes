#!/bin/bash

# Snowflake ID Performance Benchmark Script

set -e

DB_HOST="${1:-localhost}"
DB_PORT="${2:-3306}"
DB_USER="${3:-}"
DB_PASS="${4:-}"
DB_NAME="${5:-}"
ENTRY_COUNT="${6:-50000}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

execute_mysql() {
    local sql="$1"
    local use_db="${2:-true}"
    local out
    local args=( -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" )
    [ "$use_db" = "true" ] && args+=( "$DB_NAME" )

    if ! out=$(mysql "${args[@]}" -e "$sql" 2>&1); then
        print_error "$out"
        return 1
    fi
}

execute_mysql_file() {
    local file="$1"
    local use_db="${2:-true}"
    local out
    local args=( -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" )
    [ "$use_db" = "true" ] && args+=( "$DB_NAME" )

    if ! out=$(mysql "${args[@]}" 2>&1 < "$file"); then
        print_error "$out"
        return 1
    fi
}


get_timestamp_ms() {
    # Try the Linux/GNU date format first
    if date +%s%3N 2>/dev/null | grep -qv 'N$'; then
        date +%s%3N
    else
        # Fallback for systems without %N support (like macOS)
        # Use Python to get milliseconds precision
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "import time; print(int(time.time() * 1000))"
        elif command -v python >/dev/null 2>&1; then
            python -c "import time; print(int(time.time() * 1000))"
        else
            # Last resort: use seconds and append 000 for milliseconds
            echo "$(date +%s)000"
        fi
    fi
}

print_info "Starting Snowflake ID Performance Benchmark"
print_info "Database: $DB_HOST:$DB_PORT"
print_info "User: $DB_USER"
print_info "Database Name: $DB_NAME"

print_info "Testing database connection..."
if ! execute_mysql "SELECT 1;" false >/dev/null 2>&1; then
    print_error "Failed to connect to MySQL server"
    exit 1
fi
print_success "Database connection successful"

print_info "Checking if benchmark database exists..."
if ! execute_mysql "USE $DB_NAME;" false >/dev/null 2>&1; then
    print_error "Database '$DB_NAME' does not exist. Please create the database before running this benchmark."
    exit 1
fi
print_success "Database exists and is accessible"

print_info "Setting up snowflake functions and tables..."

if [ ! -d "core" ]; then
    print_error "core directory not found"
    exit 1
fi

if [ ! -d "benchmark" ]; then
    print_error "benchmark directory not found"
    exit 1
fi

files_to_execute=(
    "core/snowflake_config_table.sql"
    "core/snowflake_state_table.sql"
    "core/snowflake_current_milliseconds_function.sql"
    "core/snowflake_id_generator_function.sql"
)

for file in "${files_to_execute[@]}"; do
    if [ ! -f "$file" ]; then
        print_error "$file not found"
        exit 1
    fi
    print_info "Executing $file..."
    execute_mysql_file "$file"
done

print_success "Snowflake functions and tables set up"

print_info "Setting up test tables..."

test_files=(
    "benchmark/snowflake_test_tables.sql"
    "benchmark/snowflake_fill_functions.sql"
)

for file in "${test_files[@]}"; do
    if [ ! -f "$file" ]; then
        print_error "$file not found"
        exit 1
    fi
    print_info "Executing $file..."
    execute_mysql_file "$file"
done

print_info "Inserting a base value into configs table"

execute_mysql "INSERT INTO snowflake_config (node_id) VALUES (1) ON DUPLICATE KEY UPDATE node_id = node_id;"

print_success "Base value added to configs table"

print_success "Test tables set up"

print_info "Starting performance tests..."
echo "=============================================="

print_info "Test 1: $ENTRY_COUNT entries within transaction"
echo "----------------------------------------------"

print_info "Testing regular auto-increment table..."
start_time=$(get_timestamp_ms)
execute_mysql "CALL fill_n_transaction('test_table_regular', $ENTRY_COUNT);"
end_time=$(get_timestamp_ms)
regular_time_tx=$((end_time - start_time))
print_success "Regular table (transaction): ${regular_time_tx}ms"

print_info "Testing snowflake ID table..."
start_time=$(get_timestamp_ms)
execute_mysql "CALL fill_n_transaction('test_table_snowflake', $ENTRY_COUNT);"
end_time=$(get_timestamp_ms)
snowflake_time_tx=$((end_time - start_time))
print_success "Snowflake table (transaction): ${snowflake_time_tx}ms"

execute_mysql "TRUNCATE test_table_regular; TRUNCATE test_table_snowflake;"

echo "=============================================="
print_info "Test 1 Results:"
echo "Regular ID (transaction):  ${regular_time_tx}ms"
echo "Snowflake ID (transaction): ${snowflake_time_tx}ms"
if [ $snowflake_time_tx -gt $regular_time_tx ]; then
    overhead=$((snowflake_time_tx - regular_time_tx))
    percentage=$((overhead * 100 / regular_time_tx))
    echo "Snowflake overhead: ${overhead}ms (${percentage}%)"
else
    improvement=$((regular_time_tx - snowflake_time_tx))
    percentage=$((improvement * 100 / regular_time_tx))
    echo "Snowflake improvement: ${improvement}ms (${percentage}%)"
fi
echo "=============================================="

test1_regular_result=$regular_time_tx
test1_snowflake_result=$snowflake_time_tx

print_info "Test 2: 5 concurrent connections doing $ENTRY_COUNT entries each"
echo "----------------------------------------------"

cat > concurrent_test_regular.sh << EOF
#!/bin/bash
DB_HOST="\$1"
DB_PORT="\$2"
DB_USER="\$3"
DB_PASS="\$4"
DB_NAME="\$5"
CONN_ID="\$6"

mysql -h"\$DB_HOST" -P"\$DB_PORT" -u"\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e "
CALL fill_n_transaction('test_table_regular', $ENTRY_COUNT);" 2>/dev/null
EOF
chmod +x concurrent_test_regular.sh

cat > concurrent_test_snowflake.sh << EOF
#!/bin/bash
DB_HOST="\$1"
DB_PORT="\$2"
DB_USER="\$3"
DB_PASS="\$4"
DB_NAME="\$5"
CONN_ID="\$6"

mysql -h"\$DB_HOST" -P"\$DB_PORT" -u"\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e "
CALL fill_n_transaction('test_table_snowflake', $ENTRY_COUNT);" 2>/dev/null
EOF
chmod +x concurrent_test_snowflake.sh

print_info "Testing regular table with 5 concurrent connections..."
start_time=$(get_timestamp_ms)
for i in {1..5}; do
    ./concurrent_test_regular.sh "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$DB_NAME" "$i" &
done
wait
end_time=$(get_timestamp_ms)
regular_time_concurrent=$((end_time - start_time))
print_success "Regular table (concurrent): ${regular_time_concurrent}ms"

execute_mysql "TRUNCATE test_table_regular;"

print_info "Testing snowflake table with 5 concurrent connections..."
start_time=$(get_timestamp_ms)
for i in {1..5}; do
    ./concurrent_test_snowflake.sh "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$DB_NAME" "$i" &
done
wait
end_time=$(get_timestamp_ms)
snowflake_time_concurrent=$((end_time - start_time))
print_success "Snowflake table (concurrent): ${snowflake_time_concurrent}ms"

execute_mysql "TRUNCATE test_table_regular; TRUNCATE test_table_snowflake;"

echo "=============================================="
print_info "Test 2 Results:"
echo "Regular ID (concurrent):   ${regular_time_concurrent}ms"
echo "Snowflake ID (concurrent): ${snowflake_time_concurrent}ms"
if [ $snowflake_time_concurrent -gt $regular_time_concurrent ]; then
    overhead=$((snowflake_time_concurrent - regular_time_concurrent))
    percentage=$((overhead * 100 / regular_time_concurrent))
    echo "Snowflake overhead: ${overhead}ms (${percentage}%)"
else
    improvement=$((regular_time_concurrent - snowflake_time_concurrent))
    percentage=$((improvement * 100 / regular_time_concurrent))
    echo "Snowflake improvement: ${improvement}ms (${percentage}%)"
fi
echo "=============================================="

test2_regular_result=$regular_time_concurrent
test2_snowflake_result=$snowflake_time_concurrent

print_info "Test 3: $ENTRY_COUNT entries without scoped transactions (individual commits)"
echo "----------------------------------------------"

print_info "Testing regular table without transactions..."
start_time=$(get_timestamp_ms)
execute_mysql "CALL fill_n('test_table_regular', $ENTRY_COUNT);"
end_time=$(get_timestamp_ms)
regular_time_notx=$((end_time - start_time))
print_success "Regular table (no transaction): ${regular_time_notx}ms"

print_info "Testing snowflake table without transactions..."
start_time=$(get_timestamp_ms)
execute_mysql "CALL fill_n('test_table_snowflake', $ENTRY_COUNT);"
end_time=$(get_timestamp_ms)
snowflake_time_notx=$((end_time - start_time))
print_success "Snowflake table (no transaction): ${snowflake_time_notx}ms"

execute_mysql "TRUNCATE test_table_regular; TRUNCATE test_table_snowflake;"

echo "=============================================="
print_info "Test 3 Results:"
echo "Regular ID (no transaction):   ${regular_time_notx}ms"
echo "Snowflake ID (no transaction): ${snowflake_time_notx}ms"
if [ $snowflake_time_notx -gt $regular_time_notx ]; then
    overhead=$((snowflake_time_notx - regular_time_notx))
    percentage=$((overhead * 100 / regular_time_notx))
    echo "Snowflake overhead: ${overhead}ms (${percentage}%)"
else
    improvement=$((regular_time_notx - snowflake_time_notx))
    percentage=$((improvement * 100 / regular_time_notx))
    echo "Snowflake improvement: ${improvement}ms (${percentage}%)"
fi
echo "=============================================="

test3_regular_result=$regular_time_notx
test3_snowflake_result=$snowflake_time_notx

print_info "Test 4: $ENTRY_COUNT entries using one big insert statement"
echo "----------------------------------------------"

print_info "Generating bulk insert data..."
VALUES="(NULL)"
for i in $(seq 1 $ENTRY_COUNT); do
    VALUES="$VALUES,(NULL)"
done

print_info "Testing regular table with bulk insert..."
start_time=$(get_timestamp_ms)
execute_mysql "INSERT INTO test_table_regular (id) VALUES $VALUES;"
end_time=$(get_timestamp_ms)
regular_time_bulk=$((end_time - start_time))
print_success "Regular table (bulk): ${regular_time_bulk}ms"

print_info "Testing snowflake table with bulk insert..."
start_time=$(get_timestamp_ms)
execute_mysql "INSERT INTO test_table_snowflake (id) VALUES $VALUES;"
end_time=$(get_timestamp_ms)
snowflake_time_bulk=$((end_time - start_time))
print_success "Snowflake table (bulk): ${snowflake_time_bulk}ms"

echo "=============================================="
print_info "Test 4 Results:"
echo "Regular ID (bulk):   ${regular_time_bulk}ms"
echo "Snowflake ID (bulk): ${snowflake_time_bulk}ms"
if [ $snowflake_time_bulk -gt $regular_time_bulk ]; then
    overhead=$((snowflake_time_bulk - regular_time_bulk))
    percentage=$((overhead * 100 / regular_time_bulk))
    echo "Snowflake overhead: ${overhead}ms (${percentage}%)"
else
    improvement=$((regular_time_bulk - snowflake_time_bulk))
    percentage=$((improvement * 100 / regular_time_bulk))
    echo "Snowflake improvement: ${improvement}ms (${percentage}%)"
fi
echo "=============================================="

test4_regular_result=$regular_time_bulk
test4_snowflake_result=$snowflake_time_bulk

# Cleanup concurrent test scripts
rm -f concurrent_test_regular.sh concurrent_test_snowflake.sh

print_info "All tests completed!"

echo ""
echo "=============================================="
print_info "FINAL BENCHMARK SUMMARY"
echo "=============================================="
echo "Test 1 - ${ENTRY_COUNT} entries in transaction:"
echo "  Regular ID:   ${test1_regular_result}ms"
echo "  Snowflake ID: ${test1_snowflake_result}ms"
echo ""
echo "Test 2 - 5 concurrent connections (${ENTRY_COUNT} entries each):"
echo "  Regular ID:   ${test2_regular_result}ms"
echo "  Snowflake ID: ${test2_snowflake_result}ms"
echo ""
echo "Test 3 - ${ENTRY_COUNT} entries without transactions:"
echo "  Regular ID:   ${test3_regular_result}ms"
echo "  Snowflake ID: ${test3_snowflake_result}ms"
echo ""
echo "Test 4 - ${ENTRY_COUNT} entries bulk insert:"
echo "  Regular ID:   ${test4_regular_result}ms"
echo "  Snowflake ID: ${test4_snowflake_result}ms"
echo "=============================================="
