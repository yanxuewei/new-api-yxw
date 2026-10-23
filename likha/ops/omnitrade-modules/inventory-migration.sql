-- 库存修复增量表；保留全部原表和数据，可重复执行。
CREATE TABLE IF NOT EXISTS erp_inventory.t_repair_inventory_guard (
  id INT NOT NULL PRIMARY KEY
) ENGINE=InnoDB;
INSERT IGNORE INTO erp_inventory.t_repair_inventory_guard (id) VALUES (1);

CREATE TABLE IF NOT EXISTS erp_warehouse.t_repair_warehouse_extra (
  warehouse_id BIGINT NOT NULL PRIMARY KEY,
  email VARCHAR(200) NOT NULL DEFAULT '',
  is_default TINYINT NOT NULL DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS erp_warehouse.t_repair_warehouse_location (
  id BIGINT NOT NULL PRIMARY KEY,
  warehouse_id BIGINT NOT NULL,
  location_code VARCHAR(100) NOT NULL,
  location_type VARCHAR(50) NOT NULL,
  zone VARCHAR(100) NOT NULL DEFAULT '',
  row_code VARCHAR(100) NOT NULL DEFAULT '',
  column_code VARCHAR(100) NOT NULL DEFAULT '',
  level_code VARCHAR(100) NOT NULL DEFAULT '',
  status TINYINT NOT NULL DEFAULT 1,
  deleted TINYINT NOT NULL DEFAULT 0,
  create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  update_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_warehouse_location (warehouse_id, location_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS erp_inventory.t_repair_inventory_location (
  inventory_id BIGINT NOT NULL PRIMARY KEY,
  location_id BIGINT NOT NULL,
  KEY idx_location (location_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
