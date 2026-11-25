-- ICT371 Question 9: Farmer Cooperative Maize Deliveries
-- Name: CHRISTABEL CHIKOMONA   Student number: 201901101

DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a) Tables
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL,
    weight_kg    NUMERIC(10,2) NOT NULL,
    unit_rate    NUMERIC(8,2)  NOT NULL,     -- always set by the trigger
    total_value  NUMERIC(12,2) NOT NULL,     -- always set by the trigger
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE,
    CONSTRAINT chk_grade  CHECK (grade IN ('A', 'B', 'C')),
    CONSTRAINT chk_weight CHECK (weight_kg > 0)
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL CHECK (total_weight >= 0),
    total_value   NUMERIC(14,2) NOT NULL CHECK (total_value >= 0)
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Alice Mwansa'),
    ('F002', 'Brian Phiri'),
    ('F003', 'Chanda Zulu');

-- (b) Function: K5 per kg for grade A, K4 for B, K3 for C
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;

    RETURN CASE p_grade
        WHEN 'A' THEN 5
        WHEN 'B' THEN 4
        WHEN 'C' THEN 3
        ELSE NULL
    END
    ;
END;
$$;

-- Reject unsupported grades (a CASE cannot raise, so we wrap the function)
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;

    v_rate := CASE p_grade
                  WHEN 'A' THEN 5
                  WHEN 'B' THEN 4
                  WHEN 'C' THEN 3
              END;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;

    RETURN v_rate;
END;
$$;

-- (d) Trigger: one pricing rule for ALL inserts and updates, including direct
-- SQL. Whatever unit_rate or total_value the caller supplies is overwritten.
CREATE OR REPLACE FUNCTION trg_fn_price_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_price_delivery();

-- (c) Procedure: validate, then insert only the basic fields with
-- is_paid false. The trigger supplies unit_rate and total_value.
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     TEXT,
    p_weight    NUMERIC,
    p_date      DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date must not be NULL';
    END IF;
    PERFORM fn_maize_rate(p_grade);     -- raises for NULL or unsupported grade

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- (a, continued) Six deliveries, loaded AFTER the trigger is installed.
-- Four are direct SQL (no rate or value given); two use the procedure.
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'A', 100.00, DATE '2026-11-20', TRUE),    -- 500.00
    (2, 'C',  80.00, DATE '2026-11-21', TRUE),    -- 240.00
    (3, 'B',  60.00, DATE '2026-11-22', TRUE),    -- 240.00
    (3, 'C',  30.00, DATE '2026-11-23', TRUE);    --  90.00

CALL pr_receive_delivery(1, 'B', 50, DATE '2026-11-21');   -- 200.00, unpaid
CALL pr_receive_delivery(2, 'A', 40, DATE '2026-11-22');   -- 200.00, unpaid

-- Tests (remove the -- to run one at a time)
-- SELECT fn_maize_rate('A');                          -- 5
-- SELECT fn_maize_rate('D');                          -- rejected: unsupported
-- SELECT fn_maize_rate(NULL);                         -- rejected: NULL
-- CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);   -- unknown farmer
-- CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);    -- invalid weight
-- CALL pr_receive_delivery(1, 'Z', 10, CURRENT_DATE);    -- unsupported grade
-- Direct SQL cannot bypass the pricing rule (the wrong rate and value are overwritten):
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
--     VALUES (1, 'C', 10, 99, 9999, CURRENT_DATE);       -- stored as rate 3, value 30.00
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
--     VALUES (1, 'A', 0, CURRENT_DATE);                  -- rejected: non-positive weight
-- UPDATE deliveries SET weight_kg = 10 WHERE delivery_id = 1;   -- total_value recalculated to 50.00
-- SELECT * FROM deliveries ORDER BY delivery_id;

-- (e) View: each farmer's unpaid total, zero when nothing is unpaid
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0) AS amount_due
FROM   farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name
ORDER BY f.farmer_number;

-- SELECT * FROM v_farmer_amount_due;   -- F001 200.00, F002 200.00, F003 0.00

-- (f) Composite index: one farmer's deliveries between two dates
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

-- Plan for the matching query (seqscan off only because the table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
FROM   deliveries
WHERE  farmer_id = 1
  AND  delivered_on BETWEEN DATE '2026-11-20' AND DATE '2026-11-23';
RESET enable_seqscan;

-- Justification: the query has an equality on farmer_id and a range on
-- delivered_on. With (farmer_id, delivered_on) one index lookup finds the
-- farmer and then reads that farmer's date range as an ordered slice,
-- without scanning other farmers' deliveries. The same index also
-- supports the farmer foreign key and the join in v_farmer_amount_due.

-- (g) Purchases refresh: recalculated and overwritten, so reruns never add twice
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM   deliveries
    WHERE  delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
       SET total_weight = EXCLUDED.total_weight,
           total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(DATE '2026-11-20');
CALL pr_refresh_purchases(DATE '2026-11-21');
CALL pr_refresh_purchases(DATE '2026-11-22');
CALL pr_refresh_purchases(DATE '2026-11-23');
CALL pr_refresh_purchases(DATE '2026-11-22');   -- rerun: replaced, not added again

-- Schedule daily at 01:30 for the previous day (needs pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('refresh-purchases', '30 1 * * *',
--     $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time
-- FROM cron.job_run_details ORDER BY start_time DESC;

-- Final check
SELECT * FROM daily_purchases ORDER BY purchase_date;