CREATE TABLE IF NOT EXISTS snowflake_config (
    node_id INT UNSIGNED NOT NULL,
    PRIMARY KEY (node_id),
    UNIQUE KEY uq_node_id (node_id)
) ENGINE=InnoDB;
