-- 仅创建 AI 语言功能业务表；不添加示例知识或业务数据。
CREATE TABLE IF NOT EXISTS erp_inventory.t_ai_knowledge (
  id BIGINT NOT NULL PRIMARY KEY,
  title VARCHAR(200) NOT NULL,
  content MEDIUMTEXT NOT NULL,
  created_by BIGINT NOT NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS erp_inventory.t_ai_session (
  session_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
  user_id BIGINT NOT NULL,
  title VARCHAR(100) NOT NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  KEY idx_ai_session_user (user_id,updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS erp_inventory.t_ai_message (
  id BIGINT NOT NULL PRIMARY KEY,
  sequence_id BIGINT NOT NULL AUTO_INCREMENT,
  UNIQUE KEY uk_ai_message_sequence (sequence_id),
  session_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  user_id BIGINT NOT NULL,
  role VARCHAR(16) NOT NULL,
  content MEDIUMTEXT NOT NULL,
  sources_json MEDIUMTEXT NOT NULL,
  mode VARCHAR(16) DEFAULT NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  KEY idx_ai_message_session (session_id,user_id,sequence_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- PENDING 在进程异常结束后也不自动重发，避免不确定的收费请求被重复执行。
CREATE TABLE IF NOT EXISTS erp_inventory.t_ai_request (
  id BIGINT NOT NULL PRIMARY KEY,
  user_id BIGINT NOT NULL,
  operation VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  request_id VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  payload_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  state VARCHAR(16) NOT NULL,
  response_json MEDIUMTEXT DEFAULT NULL,
  error_status INT DEFAULT NULL,
  error_message VARCHAR(500) DEFAULT NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  UNIQUE KEY uk_ai_request (user_id,operation,request_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS erp_inventory.t_ai_description (
  id BIGINT NOT NULL PRIMARY KEY,
  user_id BIGINT NOT NULL,
  product_id BIGINT NOT NULL,
  sku VARCHAR(100) NOT NULL,
  language VARCHAR(8) NOT NULL,
  description MEDIUMTEXT NOT NULL,
  model VARCHAR(200) NOT NULL,
  original_description MEDIUMTEXT DEFAULT NULL,
  saved TINYINT NOT NULL DEFAULT 0,
  product_updated TINYINT NOT NULL DEFAULT 0,
  saved_at DATETIME(3) DEFAULT NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  KEY idx_ai_description_user (user_id,created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
