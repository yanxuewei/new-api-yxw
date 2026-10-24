-- 仅新增AI业务审计与人工确认表，不修改既有商品、订单或库存表结构。
CREATE TABLE IF NOT EXISTS erp_inventory.t_ai_price_history (
    id BIGINT NOT NULL AUTO_INCREMENT,
    sku_id BIGINT NOT NULL,
    sku_code VARCHAR(100) NOT NULL,
    previous_price DECIMAL(18,2) NULL,
    new_price DECIMAL(18,2) NOT NULL,
    operator_id BIGINT NOT NULL,
    basis VARCHAR(1000) NOT NULL,
    create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_ai_price_sku_id (sku_code,id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS erp_inventory.t_ai_recommend_adoption (
    sku_id BIGINT NOT NULL,
    sku_code VARCHAR(100) NOT NULL,
    operator_id BIGINT NOT NULL,
    create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    update_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (sku_id),
    UNIQUE KEY uk_ai_adoption_sku (sku_code),
    KEY idx_ai_adoption_updated (update_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS erp_inventory.t_ai_order_anomaly (
    order_id BIGINT NOT NULL,
    rule_key VARCHAR(512) NOT NULL DEFAULT '',
    risk_score INT NOT NULL DEFAULT 0,
    confirmation_status VARCHAR(16) NOT NULL DEFAULT 'PENDING',
    confirmed_by BIGINT NULL,
    confirmed_at DATETIME NULL,
    detected_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (order_id),
    KEY idx_ai_anomaly_status (confirmation_status,risk_score)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
