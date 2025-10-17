-- Setup test tables for benchmarking regular ID vs snowflake ID
-- NOTE: This script requires the snowflake infrastructure to be set up first

-- Drop triggers first to avoid dependency issues (if they exist)
DROP TRIGGER IF EXISTS test_table_snowflake_before_insert;
DROP TRIGGER IF EXISTS test_table_snowflake_after_insert;

-- Drop tables if they exist
DROP TABLE IF EXISTS test_table_regular;
DROP TABLE IF EXISTS test_table_snowflake;

-- Create table with regular auto-increment primary key
CREATE TABLE test_table_regular (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    PRIMARY KEY (id)
) ENGINE=InnoDB;

-- Create table with snowflake ID (will use triggers)
CREATE TABLE test_table_snowflake (
    id BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB;

-- Create triggers for snowflake ID generation
DELIMITER //

CREATE TRIGGER test_table_snowflake_before_insert
    BEFORE INSERT
    ON test_table_snowflake
    FOR EACH ROW
BEGIN
    IF NEW.id IS NULL OR NEW.id = 0 THEN
        SET NEW.id = snowflake();
    END IF;
END//

CREATE TRIGGER test_table_snowflake_after_insert
    AFTER INSERT
    ON test_table_snowflake
    FOR EACH ROW
BEGIN
    DO LAST_INSERT_ID(NEW.id);
END//

DELIMITER ;
