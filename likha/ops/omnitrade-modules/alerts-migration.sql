-- 库存预警增量表；先执行inventory-migration.sql，不修改已有业务表。
CREATE TABLE IF NOT EXISTS erp_inventory.t_repair_alert_settings (
  id INT NOT NULL PRIMARY KEY,
  enable_alert TINYINT NOT NULL DEFAULT 1,
  default_advance_days INT NOT NULL DEFAULT 3,
  default_notify_to VARCHAR(1000) NOT NULL DEFAULT '',
  updated_by BIGINT NULL,
  update_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
INSERT IGNORE INTO erp_inventory.t_repair_alert_settings (id) VALUES (1);

CREATE TABLE IF NOT EXISTS erp_inventory.t_repair_alert_rule (
  id BIGINT NOT NULL PRIMARY KEY,
  product_id BIGINT NULL,
  sku VARCHAR(100) NOT NULL DEFAULT '',
  product_name VARCHAR(255) NOT NULL DEFAULT '',
  warehouse_id BIGINT NOT NULL,
  warehouse_name VARCHAR(200) NOT NULL,
  safe_stock INT NOT NULL,
  alert_stock INT NOT NULL,
  min_stock INT NOT NULL DEFAULT 0,
  alert_type VARCHAR(20) NOT NULL DEFAULT 'LOW',
  advance_days INT NOT NULL DEFAULT 3,
  notify_type VARCHAR(100) NOT NULL DEFAULT 'SYSTEM',
  notify_to VARCHAR(1000) NOT NULL DEFAULT '',
  email_list VARCHAR(1000) NOT NULL DEFAULT '',
  phone_list VARCHAR(1000) NOT NULL DEFAULT '',
  enabled TINYINT NOT NULL DEFAULT 1,
  remark VARCHAR(1000) NOT NULL DEFAULT '',
  deleted TINYINT NOT NULL DEFAULT 0,
  create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  update_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_rule_scope (warehouse_id, enabled, deleted)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS erp_inventory.t_repair_alert_record (
  id BIGINT NOT NULL PRIMARY KEY,
  rule_id BIGINT NOT NULL,
  inventory_id BIGINT NOT NULL,
  product_id BIGINT NULL,
  sku VARCHAR(100) NOT NULL,
  product_name VARCHAR(255) NOT NULL,
  warehouse_id BIGINT NOT NULL,
  warehouse_name VARCHAR(200) NOT NULL,
  current_stock INT NOT NULL,
  alert_stock INT NOT NULL,
  safe_stock INT NOT NULL,
  alert_type VARCHAR(20) NOT NULL,
  message VARCHAR(1000) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
  handler_id BIGINT NULL,
  handler_name VARCHAR(200) NULL,
  handle_time DATETIME NULL,
  handle_remark VARCHAR(1000) NOT NULL DEFAULT '',
  notified TINYINT NOT NULL DEFAULT 0,
  create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  update_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  pending_slot TINYINT GENERATED ALWAYS AS (CASE WHEN status='PENDING' THEN 1 ELSE NULL END) STORED,
  UNIQUE KEY uk_pending_rule_inventory (rule_id, inventory_id, pending_slot),
  KEY idx_record_warehouse_time (warehouse_id, create_time),
  KEY idx_record_status (status, create_time),
  KEY idx_record_inventory (inventory_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS erp_inventory.t_repair_alert_replenishment (
  id BIGINT NOT NULL PRIMARY KEY,
  alert_id BIGINT NOT NULL,
  rule_id BIGINT NOT NULL,
  inventory_id BIGINT NOT NULL,
  product_id BIGINT NULL,
  sku VARCHAR(100) NOT NULL,
  product_name VARCHAR(255) NOT NULL,
  warehouse_id BIGINT NOT NULL,
  warehouse_name VARCHAR(200) NOT NULL,
  current_stock INT NOT NULL,
  safe_stock INT NOT NULL,
  suggested_quantity BIGINT NOT NULL,
  estimated_price DECIMAL(18,2) NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
  confirm_user_id BIGINT NULL,
  confirm_user_name VARCHAR(200) NULL,
  confirm_time DATETIME NULL,
  remark VARCHAR(1000) NOT NULL DEFAULT '',
  suggested_date DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expected_arrival_date DATETIME NULL,
  create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  update_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  pending_slot TINYINT GENERATED ALWAYS AS (CASE WHEN status='PENDING' THEN 1 ELSE NULL END) STORED,
  UNIQUE KEY uk_replenishment_alert (alert_id),
  UNIQUE KEY uk_pending_replenishment_inventory (rule_id, inventory_id, pending_slot),
  KEY idx_replenishment_warehouse_status (warehouse_id, status),
  KEY idx_replenishment_inventory (inventory_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 手动补货数量单独保存，不改已部署的补货表；清理建议时级联清理。
CREATE TABLE IF NOT EXISTS erp_inventory.t_repair_alert_quantity_override (
  suggestion_id BIGINT NOT NULL PRIMARY KEY,
  quantity INT NOT NULL,
  CONSTRAINT fk_alert_quantity_suggestion FOREIGN KEY (suggestion_id)
    REFERENCES erp_inventory.t_repair_alert_replenishment(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
