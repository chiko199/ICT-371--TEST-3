-- ICT371 Question 7: Water Meter Readings and Billing
-- Name: CHRISTABEL CHIKOMONA   Student number: 201901101

DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- (a) Tables
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    -- reading_month must be the first day of a month
    CONSTRAINT chk_reading_month_start CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    -- amount_paid must stay between zero and the charge
    CONSTRAINT chk_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12,2) NOT NULL CHECK (total_due >= 0)
);

INSERT INTO customers (full_name) VALUES
    ('Alice Mwansa'), ('Brian Phiri'), ('Chanda Zulu');

-- (b) Function: first 10 units at K5, units above 10 at K8, exact 2 decimals
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    c_band1_limit CONSTANT NUMERIC := 10;
    c_band1_rate  CONSTANT NUMERIC := 5;    -- K5 per unit for the first 10 units
    c_band2_rate  CONSTANT NUMERIC := 8;    -- K8 per unit above 10
    v_charge NUMERIC;
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Consumption must not be NULL';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must not be negative (got %)', p_units;
    END IF;

    IF p_units <= c_band1_limit THEN
        v_charge := p_units * c_band1_rate;                 -- zero units cost zero
    ELSE
        v_charge := c_band1_limit * c_band1_rate
                  + (p_units - c_band1_limit) * c_band2_rate;
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$;

-- (d) Trigger: reject current_reading below previous_reading, for any
-- INSERT or UPDATE, including direct SQL imports. The exception aborts the
-- statement, so a rejected reading is never stored.
CREATE OR REPLACE FUNCTION trg_fn_check_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_reading();

-- (c) Procedure: derive consumption, call the function, insert the bill
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC(10,2);
    v_curr   NUMERIC(10,2);
    v_units  NUMERIC;
    v_charge NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date must not be NULL';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM   readings
    WHERE  reading_id = p_reading_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_units  := v_curr - v_prev;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- (a, continued) Six readings, loaded after the trigger is installed
-- Covers zero, exactly 10 and above 10 units
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100, 100),   -- 1:  0 units  -> K0
    (1, DATE '2026-10-01', 100, 110),   -- 2: 10 units  -> K50
    (2, DATE '2026-09-01', 200, 215),   -- 3: 15 units  -> K90  (50 + 5 x 8)
    (2, DATE '2026-10-01', 215, 225),   -- 4: 10 units  -> K50
    (3, DATE '2026-09-01',  50,  62),   -- 5: 12 units  -> K66  (50 + 2 x 8)
    (3, DATE '2026-10-01',  62,  80);   -- 6: 18 units  -> K114 (50 + 8 x 8)

-- Bills through the procedure (September bills are past due, October not yet)
CALL pr_generate_bill(1, DATE '2026-10-15');
CALL pr_generate_bill(2, CURRENT_DATE + 14);
CALL pr_generate_bill(3, DATE '2026-10-15');
CALL pr_generate_bill(4, CURRENT_DATE + 14);
CALL pr_generate_bill(5, DATE '2026-10-15');
CALL pr_generate_bill(6, CURRENT_DATE + 14);

-- Record some payments
UPDATE bills SET amount_paid = 50 WHERE bill_id = 2;   -- fully paid
UPDATE bills SET amount_paid = 40 WHERE bill_id = 3;   -- partly paid (50 outstanding)

-- Tests (remove the -- to run one at a time; each should be rejected)
-- SELECT fn_water_charge(0);      -- 0.00
-- SELECT fn_water_charge(10);     -- 50.00
-- SELECT fn_water_charge(15);     -- 90.00
-- SELECT fn_water_charge(NULL);   -- rejected
-- SELECT fn_water_charge(-1);     -- rejected
-- CALL pr_generate_bill(99, CURRENT_DATE);   -- unknown reading
-- CALL pr_generate_bill(1, CURRENT_DATE);    -- reading already billed
-- INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
--     VALUES (1, DATE '2026-11-01', 110, 100);   -- trigger rejects; nothing stored
-- UPDATE readings SET current_reading = 5 WHERE reading_id = 2;   -- trigger rejects the update
-- UPDATE bills SET amount_paid = 999 WHERE bill_id = 3;           -- CHECK rejects overpayment

-- (e) View: bills past due and not fully paid
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM   bills b
JOIN   readings r ON r.reading_id  = b.reading_id
JOIN   customers c ON c.customer_id = r.customer_id
WHERE  b.due_on < CURRENT_DATE
  AND  b.amount_paid < b.charge;

-- SELECT * FROM v_overdue_bills;   -- Brian (50) and Chanda (66)

-- (f) Partial index on due_on, covering only bills that are not fully paid
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

-- Plan for the matching unpaid-bill query (seqscan off only because the table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM   bills
WHERE  due_on < CURRENT_DATE
  AND  amount_paid < charge;
RESET enable_seqscan;

-- Justification: overdue searches are date-based (due_on before today) and
-- only ever concern bills that are not fully paid. The partial index
-- stores only those bills, so it stays small as paid bills accumulate, and
-- it is ordered by due_on so the date condition is answered by one range
-- scan. The planner can use it because the query repeats the same
-- amount_paid < charge condition.

-- (g) Receivables snapshot: today's total of unpaid balances, replaced on rerun
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE,
           COALESCE(SUM(charge - amount_paid), 0)
    FROM   bills
    WHERE  amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
       SET total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();   -- rerun: replaced, not doubled

-- Schedule daily at 00:30 (needs pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('refresh-receivables', '30 0 * * *',
--     $$CALL pr_refresh_receivables()$$);
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time
-- FROM cron.job_run_details ORDER BY start_time DESC;

-- Final check
SELECT * FROM receivable_snapshot ORDER BY snapshot_date;