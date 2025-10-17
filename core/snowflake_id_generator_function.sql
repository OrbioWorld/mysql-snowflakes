DROP FUNCTION IF EXISTS snowflake;

DELIMITER //

CREATE FUNCTION snowflake()
    RETURNS BIGINT UNSIGNED
    NOT DETERMINISTIC
    MODIFIES SQL DATA
BEGIN
    DECLARE v_node_id INT UNSIGNED;
    DECLARE v_now_ms BIGINT UNSIGNED;
    DECLARE v_last_ms BIGINT UNSIGNED DEFAULT 0;
    DECLARE v_seq INT UNSIGNED DEFAULT 0;

    DECLARE v_node_bits INT DEFAULT 5;
    DECLARE v_conn_bits INT DEFAULT 8;
    DECLARE v_seq_bits INT DEFAULT 10;
    DECLARE v_max_seq INT UNSIGNED DEFAULT (1 << v_seq_bits) - 1;
    DECLARE v_time_bits INT DEFAULT 41;

    DECLARE v_shard_count INT UNSIGNED DEFAULT (1 << v_conn_bits);
    DECLARE v_base_shard INT UNSIGNED;
    DECLARE v_conn_shard INT UNSIGNED;
    DECLARE v_probe INT UNSIGNED DEFAULT 0;
    DECLARE v_acquired TINYINT(1) DEFAULT 0;

    -- Custom epoch: 2020-01-01T00:00:00Z = 1577836800000 ms
    DECLARE v_epoch BIGINT UNSIGNED DEFAULT 1577836800000;

    DECLARE v_wait_deadline_ms BIGINT UNSIGNED;

    SELECT c.node_id INTO v_node_id
    FROM snowflake_config c
    LIMIT 1;

    IF v_node_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'snowflake: missing node_id in config';
    END IF;

    IF v_node_id >= (1 << v_node_bits) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'snowflake: node_id out of range for node_bits';
    END IF;

    SET v_base_shard = (CONNECTION_ID() MOD v_shard_count);

    shard_probe: WHILE v_probe < v_shard_count DO
        SET v_conn_shard = (v_base_shard + v_probe) MOD v_shard_count;

        INSERT INTO snowflake_state (node_id, conn_shard, last_ms, seq)
        VALUES (v_node_id, v_conn_shard, 0, 0)
        ON DUPLICATE KEY UPDATE node_id = node_id;

        BEGIN
            DECLARE CONTINUE HANDLER FOR SQLSTATE '02000' SET v_acquired = 0;
            SET v_acquired = 1;

            SELECT last_ms, seq
            INTO v_last_ms, v_seq
            FROM snowflake_state
            WHERE node_id = v_node_id
                AND conn_shard = v_conn_shard
            FOR UPDATE SKIP LOCKED;
        END;

        IF v_acquired = 1 THEN
            LEAVE shard_probe;
        END IF;

        SET v_probe = v_probe + 1;
    END WHILE shard_probe;

    -- Its possible to wait and retry here or leave up to the caller to retry'
    IF v_probe = v_shard_count THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'snowflake: all shards busy';
    END IF;

    SET v_now_ms = sf_current_ms();

    -- This can happen if the system clock is somehow adjusted backwards
    -- It's possibly a good idea to do some sleeping here to compensate
    IF v_now_ms < v_last_ms THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'snowflake: clock moved backwards (deadline exceeded)';
    END IF;

    IF v_now_ms = v_last_ms THEN
        IF v_seq < v_max_seq THEN
            SET v_seq = v_seq + 1;
        ELSE
            REPEAT
                DO SLEEP(0.0005);
                SET v_now_ms = sf_current_ms();
            UNTIL v_now_ms > v_last_ms
            END REPEAT;
            SET v_seq = 0;
        END IF;
    ELSE
        SET v_seq = 0;
    END IF;

    UPDATE snowflake_state
    SET last_ms = v_now_ms,
        seq = v_seq
    WHERE node_id = v_node_id
        AND conn_shard = v_conn_shard;

    IF ((v_now_ms - v_epoch) >= (1 << v_time_bits)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'snowflake: timestamp overflow';
    END IF;

    RETURN ((v_now_ms - v_epoch) << (v_node_bits + v_conn_bits + v_seq_bits))
        | (v_node_id << (v_conn_bits + v_seq_bits))
        | (v_conn_shard << v_seq_bits)
        | v_seq;
END//

DELIMITER ;
