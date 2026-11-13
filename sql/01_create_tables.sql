-- Create database
CREATE DATABASE IF NOT EXISTS ecommerce_repurchase;
USE ecommerce_repurchase;
SELECT DATABASE();

-- Create raw transaction table
CREATE TABLE IF NOT EXISTS transactions_raw (
    row_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    invoice VARCHAR(20),
    stock_code VARCHAR(32),
    description VARCHAR(255),
    quantity INT,
    invoice_date DATETIME,
    price DECIMAL(18,6),
    customer_id INT NULL,
    country VARCHAR(64),
    source_year VARCHAR(16)
);


DESCRIBE transactions_raw;
 










