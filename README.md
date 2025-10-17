# MySQL Snowflake ID Generator

A distributed unique ID generation system for MySQL using the Snowflake algorithm with connection-based sharding and non-blocking concurrency control.

## Architecture

### ID Structure (64-bit)

```
[41 bits: timestamp] [5 bits: node_id] [8 bits: conn_shard] [10 bits: sequence]
```

- **Timestamp (41 bits)**: Milliseconds since custom epoch (2020-01-01 00:00:00 UTC)
- **Node ID (5 bits)**: Supports up to 32 database nodes (0-31)
- **Connection Shard (8 bits)**: 256 shards per node for concurrent access
- **Sequence (10 bits)**: Up to 1024 IDs per millisecond per shard

### Capacity
- **Maximum throughput**: 262M IDs/second per node (256 shards × 1024 IDs/ms)
- **Timeline**: ~69 years from 2020 epoch before timestamp overflow
- **Scalability**: 32 nodes × 262M IDs/sec = 8.4B IDs/second total

These can/should be adjusted to your personal needs.

### Concurrency Model
- **Connection sharding**: Each database connection gets deterministic shard assignment using `CONNECTION_ID() MOD 256`
- **Non-blocking locks**: Uses `SELECT ... FOR UPDATE SKIP LOCKED` to avoid contention
- **Automatic fallback**: If preferred shard is busy, probes up to 256 shards before failing

## Core Components

### Tables
- **`snowflake_config`**: Node configuration (single node_id per database)
- **`snowflake_state`**: Per-shard state tracking (node_id, conn_shard, last_ms, seq, updated_at)

### Functions
- **`sf_current_ms()`**: Returns current timestamp in milliseconds using `UNIX_TIMESTAMP(SYSDATE(3))`
- **`snowflake()`**: Main ID generator with sharding, locking, and clock drift handling

### Integration
Tables integrate via dual triggers:
- **BEFORE INSERT**: Generates snowflake ID when `id IS NULL OR id = 0`
- **AFTER INSERT**: Sets `LAST_INSERT_ID(NEW.id)` for MySQL compatibility

## Setup

### 1. Create Database
```sql
CREATE DATABASE your_database_name;
```

### 2. Install Core System
Execute these files in order:
```bash
mysql -h host -P port -u user -p database_name < core/snowflake_config_table.sql
mysql -h host -P port -u user -p database_name < core/snowflake_state_table.sql
mysql -h host -P port -u user -p database_name < core/snowflake_current_milliseconds_function.sql
mysql -h host -P port -u user -p database_name < core/snowflake_id_generator_function.sql
```

### 3. Configure Node ID
```sql
INSERT INTO snowflake_config (node_id) VALUES (1);
```

### 4. Apply to Tables
For each table requiring snowflake IDs, create triggers (replace `your_table` with actual table name):
```sql
-- Use core/snowflake_create_triggers_example.sql as template
CREATE TRIGGER your_table_sft_before
    BEFORE INSERT ON your_table
    FOR EACH ROW
BEGIN
    IF NEW.id IS NULL OR NEW.id = 0 THEN
        SET NEW.id = snowflake();
    END IF;
END;

CREATE TRIGGER your_table_sft_after
    AFTER INSERT ON your_table
    FOR EACH ROW
BEGIN
    DO LAST_INSERT_ID(NEW.id);
END;
```

## Benchmarking

### Run Performance Tests
```bash
./benchmark.sh [host] [port] [username] [password] [database_name] [entry_count]
```

This runs 4 performance tests comparing auto-increment vs snowflake ID:

1. **Transaction-based inserts**: Single transaction with N entries
2. **Concurrent connections**: 5 parallel connections, each inserting N entries
3. **Individual commits**: N entries without transaction batching
4. **Bulk insert**: Single INSERT statement with N values

Example output:

```
==============================================
[INFO] FINAL BENCHMARK SUMMARY
==============================================
Test 1 - 10000 entries in transaction:
  Regular ID:   170ms
  Snowflake ID: 542ms

Test 2 - 5 concurrent connections (10000 entries each):
  Regular ID:   579ms
  Snowflake ID: 944ms

Test 3 - 10000 entries without transactions:
  Regular ID:   7201ms
  Snowflake ID: 8087ms

Test 4 - 10000 entries bulk insert:
  Regular ID:   123ms
  Snowflake ID: 498ms
==============================================
```

## Requirements
- MySQL 8.0+ (requires `FOR UPDATE SKIP LOCKED`)
- InnoDB storage engine (for row-level locking)
