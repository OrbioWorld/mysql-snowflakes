DELIMITER //

CREATE TRIGGER `table_name_sft_before`
    BEFORE INSERT ON `table_name`
    FOR EACH ROW
BEGIN
    IF NEW.`id` IS NULL OR NEW.`id` = 0 THEN
        SET NEW.`id` = snowflake(); -- generate id
    END IF;
END//

CREATE TRIGGER `table_name_sft_after`
    AFTER INSERT ON `table_name`
    FOR EACH ROW
BEGIN
    DO LAST_INSERT_ID(NEW.`id`);
END//

DELIMITER ;
