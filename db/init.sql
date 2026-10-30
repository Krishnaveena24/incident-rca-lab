-- =====================================================================
-- Incident RCA Lab - database schema + seed data
-- Runs automatically ONCE, the first time the MySQL container starts.
-- =====================================================================
USE shopdb;

CREATE TABLE products (
  id         INT PRIMARY KEY AUTO_INCREMENT,
  name       VARCHAR(100)  NOT NULL,
  price      DECIMAL(10,2) NOT NULL,
  stock      INT           NOT NULL DEFAULT 0,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

INSERT INTO products (name, price, stock) VALUES
 ('Laptop', 899.99, 100000), ('Phone', 499.00, 100000), ('Headphones', 79.50, 100000),
 ('Keyboard', 49.99, 100000), ('Mouse', 19.99, 100000), ('Monitor', 229.00, 100000),
 ('Webcam', 59.90, 100000), ('USB Hub', 24.99, 100000), ('SSD 1TB', 89.00, 100000),
 ('Charger', 29.99, 100000);

CREATE TABLE orders (
  id             BIGINT PRIMARY KEY AUTO_INCREMENT,
  customer_email VARCHAR(120)  NOT NULL,
  product_id     INT           NOT NULL,
  quantity       INT           NOT NULL,
  total_amount   DECIMAL(12,2) NOT NULL,
  status         VARCHAR(20)   NOT NULL DEFAULT 'CREATED',
  created_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_orders_product (product_id),
  KEY idx_orders_customer_created (customer_email, created_at),
  CONSTRAINT fk_orders_product FOREIGN KEY (product_id) REFERENCES products(id)
) ENGINE=InnoDB;

-- 500,000 orders for 50,000 customers (big enough that a full table scan hurts)
SET SESSION cte_max_recursion_depth = 1000000;
INSERT INTO orders (customer_email, product_id, quantity, total_amount, status, created_at)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 500000)
SELECT CONCAT('user', n % 50000, '@example.com'),
       (n % 10) + 1,
       (n % 3) + 1,
       ((n % 3) + 1) * 49.99,
       ELT((n % 4) + 1, 'CREATED', 'PAID', 'SHIPPED', 'CANCELLED'),
       NOW() - INTERVAL (n % 525600) MINUTE
FROM seq;

ANALYZE TABLE orders, products;
