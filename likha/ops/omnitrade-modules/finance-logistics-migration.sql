-- 增量迁移：不清空、不覆盖既有流水；旧流水通过独立关联表兼容。
CREATE DATABASE IF NOT EXISTS erp_finance CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS erp_finance.t_finance_flow (
 id BIGINT NOT NULL PRIMARY KEY,
 flow_type VARCHAR(50) NOT NULL,
 order_no VARCHAR(100),
 amount DECIMAL(18,2) NOT NULL,
 currency_code VARCHAR(10) NOT NULL,
 category VARCHAR(100),
 remark VARCHAR(500),
 create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 KEY idx_order_no (order_no), KEY idx_create_time (create_time)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS erp_finance.t_finance_account (
 id BIGINT NOT NULL PRIMARY KEY,
 account_no VARCHAR(100) NOT NULL,
 account_name VARCHAR(150) NOT NULL,
 account_type VARCHAR(30) NOT NULL,
 bank_name VARCHAR(150) NOT NULL DEFAULT '',
 currency VARCHAR(3) NOT NULL,
 balance DECIMAL(18,2) NOT NULL DEFAULT 0,
 status TINYINT NOT NULL DEFAULT 1,
 is_default TINYINT NOT NULL DEFAULT 0,
 default_currency VARCHAR(3) GENERATED ALWAYS AS (CASE WHEN is_default=1 THEN currency ELSE NULL END) STORED,
 create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 UNIQUE KEY uk_finance_account_no (account_no),
 UNIQUE KEY uk_finance_default_currency (default_currency)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS erp_finance.t_finance_category (
 id BIGINT NOT NULL PRIMARY KEY,
 name VARCHAR(100) NOT NULL,
 type VARCHAR(20) NOT NULL,
 parent_id BIGINT NULL,
 sort INT NOT NULL DEFAULT 0,
 status TINYINT NOT NULL DEFAULT 1,
 CONSTRAINT fk_finance_category_parent FOREIGN KEY (parent_id) REFERENCES erp_finance.t_finance_category(id)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS erp_finance.t_finance_flow_meta (
 flow_id BIGINT NOT NULL PRIMARY KEY,
 record_no VARCHAR(100) NOT NULL,
 account_id BIGINT NOT NULL,
 category_id BIGINT NULL,
 create_by VARCHAR(100) NOT NULL DEFAULT '',
 UNIQUE KEY uk_finance_record_no (record_no),
 KEY idx_finance_account (account_id), KEY idx_finance_category (category_id),
 CONSTRAINT fk_finance_meta_flow FOREIGN KEY (flow_id) REFERENCES erp_finance.t_finance_flow(id),
 CONSTRAINT fk_finance_meta_account FOREIGN KEY (account_id) REFERENCES erp_finance.t_finance_account(id),
 CONSTRAINT fk_finance_meta_category FOREIGN KEY (category_id) REFERENCES erp_finance.t_finance_category(id)
) ENGINE=InnoDB;
CREATE DATABASE IF NOT EXISTS erp_logistics CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS erp_logistics.t_logistics_channel (
 code VARCHAR(60) NOT NULL PRIMARY KEY,
 name VARCHAR(150) NOT NULL,
 carrier VARCHAR(100) NOT NULL,
 type VARCHAR(20) NOT NULL,
 coverage JSON NOT NULL,
 features JSON NOT NULL,
 avg_delivery_days INT NOT NULL,
 tracking_support TINYINT NOT NULL DEFAULT 1,
 status TINYINT NOT NULL DEFAULT 1,
 create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
-- 兼容已执行早期版本迁移的数据库，只增补渠道状态列。
SET @channel_status_ddl = IF(
 (SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='erp_logistics' AND table_name='t_logistics_channel' AND column_name='status')=0,
 'ALTER TABLE erp_logistics.t_logistics_channel ADD COLUMN status TINYINT NOT NULL DEFAULT 1',
 'SELECT 1'
);
PREPARE channel_status_stmt FROM @channel_status_ddl;
EXECUTE channel_status_stmt;
DEALLOCATE PREPARE channel_status_stmt;
CREATE TABLE IF NOT EXISTS erp_logistics.t_logistics_rate (
 id BIGINT NOT NULL PRIMARY KEY,
 channel_code VARCHAR(60) NOT NULL,
 shipping_method VARCHAR(50) NOT NULL DEFAULT '',
 from_country VARCHAR(2) NOT NULL,
 to_country VARCHAR(2) NOT NULL,
 weight_range_min DECIMAL(12,3) NOT NULL,
 weight_range_max DECIMAL(12,3) NOT NULL,
 base_price DECIMAL(18,2) NOT NULL,
 price_per_kg DECIMAL(18,2) NOT NULL,
 volumetric_divisor DECIMAL(12,2) NULL,
 estimated_days INT NOT NULL,
 currency VARCHAR(3) NOT NULL,
 is_active TINYINT NOT NULL DEFAULT 1,
 create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 KEY idx_logistics_route (from_country,to_country,is_active),
 CONSTRAINT fk_logistics_rate_channel FOREIGN KEY (channel_code) REFERENCES erp_logistics.t_logistics_channel(code)
) ENGINE=InnoDB;
