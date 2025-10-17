-- Fill functions for benchmark testing
-- These procedures are used to populate test tables with data

-- Drop fill procedures if they exist
DROP PROCEDURE IF EXISTS fill_n;
DROP PROCEDURE IF EXISTS fill_n_transaction;

DELIMITER //

CREATE PROCEDURE fill_n(IN p_table VARCHAR(128), IN p_amount INT UNSIGNED)
BEGIN
    DECLARE i INT UNSIGNED DEFAULT 0;
    DECLARE stmt_sql TEXT;

    -- Safely quote the table identifier (no schema support here)
    SET @tbl = CONCAT('`', REPLACE(p_table, '`', '``'), '`');
    SET @sql = CONCAT('INSERT INTO ', @tbl, ' (id) VALUES (NULL)');

    PREPARE stmt FROM @sql;

    WHILE i < p_amount DO
        EXECUTE stmt;
        SET i = i + 1;
    END WHILE;

    DEALLOCATE PREPARE stmt;
END//

DELIMITER ;

DELIMITER //

CREATE PROCEDURE fill_n_transaction(IN p_table VARCHAR(128), IN p_amount INT UNSIGNED)
BEGIN
    DECLARE i INT UNSIGNED DEFAULT 0;
    DECLARE stmt_sql TEXT;

    -- Safely quote the table identifier (no schema support here)
    SET @tbl = CONCAT('`', REPLACE(p_table, '`', '``'), '`');
    SET @sql = CONCAT('INSERT INTO ', @tbl, ' (id) VALUES (NULL)');

    PREPARE stmt FROM @sql;

    START TRANSACTION;
    WHILE i < p_amount DO
        EXECUTE stmt;
        SET i = i + 1;
    END WHILE;
    COMMIT;

    DEALLOCATE PREPARE stmt;
END
//

DELIMITER ;
