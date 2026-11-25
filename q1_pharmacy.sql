-- ICT371 Question 1: Pharmacy Stock and Daily Sales
-- Name: (your name)   Student number: (your number)

DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

-- (a) Tables
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER   NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER   NOT NULL,
    new_qty     INTEGER   NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER       NOT NULL CHECK (total_qty >= 0),
    total_amount NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0)
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  40),
    ('Ibuprofen 400mg',   4.00,  25),
    ('ORS Sachet',        1.50,  12);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date must not be NULL';
    END IF;

    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock: requested %, available %',
                        p_quantity, v_stock;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
       SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

-- (a, continued) Six valid sales loaded through the procedure
CALL pr_record_sale(1, 20, DATE '2026-11-23');
CALL pr_record_sale(2, 10, DATE '2026-11-23');
CALL pr_record_sale(3, 20, DATE '2026-11-23');
CALL pr_record_sale(4,  5, DATE '2026-11-24');
CALL pr_record_sale(1, 10, DATE '2026-11-24');
CALL pr_record_sale(2, 15, DATE '2026-11-24');

-- (e) View
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM   medicines
WHERE  stock_qty < 10;

-- Another sale, then query the view
CALL pr_record_sale(2, 7, CURRENT_DATE);

-- (f) Index
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;

-- Show the plan for a matching query (seqscan off only because the table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM   sales
WHERE  medicine_id = 1
  AND  sold_on BETWEEN DATE '2026-11-23' AND DATE '2026-11-24';
RESET enable_seqscan;

-- Justification: the query has an equality on medicine_id and a range on
-- sold_on. A composite index (medicine_id, sold_on) lets one index lookup
-- find the medicine and read its date range in order, instead of scanning
-- every sale.

-- (g) Refresh procedure
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM   sales
    WHERE  sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
       SET total_qty    = EXCLUDED.total_qty,
           total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_sales(DATE '2026-11-23');
CALL pr_refresh_sales(DATE '2026-11-24');
CALL pr_refresh_sales(DATE '2026-11-24');   -- rerun: no double counting

-- Scheduled job at 00:15 daily for the previous day (needs pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('refresh-daily-sales', '15 0 * * *',
--     $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time
-- FROM cron.job_run_details ORDER BY start_time DESC;

-- Final check
SELECT * FROM daily_sales ORDER BY sales_date;