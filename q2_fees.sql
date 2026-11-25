-- ICT371 Question 2: University Fee Payments
-- Name: CHRISTABEL CHIKOMONA   Student number: 201901101

DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- (a) Tables and constraints
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER       NOT NULL CHECK (payment_count >= 0),
    total_amount    NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0)
);

-- Seed students (three different fee balances)
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('S001', 'Alice Mwansa',  5000.00),
    ('S002', 'Brian Phiri',   3000.00),
    ('S003', 'Chanda Zulu',   4000.00);   -- will have no payments

-- (b) Function
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee
    FROM students WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;      -- full fee when there are no payments
END;
$$;

-- (c) Procedure (does NOT insert the audit row; the trigger does that)
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC,
    p_paid_on    DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid payment amount: % (must be greater than zero)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date must not be NULL';
    END IF;

    -- lock the student row so two payments cannot overpay at the same time
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
    -- fee_due is never changed
END;
$$;

-- (d) Trigger: automatically audit every new payment
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- (a, continued) Six payments loaded through the procedure
-- Alice pays 3000 of 5000 (balance 2000); Brian pays all 3000 (settled);
-- Chanda has no payments.
CALL pr_receive_payment(1, 1000, DATE '2026-11-22');
CALL pr_receive_payment(2, 1000, DATE '2026-11-22');
CALL pr_receive_payment(1, 1500, DATE '2026-11-23');
CALL pr_receive_payment(2, 1000, DATE '2026-11-23');
CALL pr_receive_payment(1,  500, DATE '2026-11-24');
CALL pr_receive_payment(2, 1000, DATE '2026-11-24');

-- Tests of the function and invalid payments (each is rejected and changes nothing)
-- SELECT fn_fee_balance(1);   -- 2000
-- SELECT fn_fee_balance(3);   -- 4000 (no payments)
-- CALL pr_receive_payment(1, 0, CURRENT_DATE);        -- rejected: zero
-- CALL pr_receive_payment(1, NULL, CURRENT_DATE);     -- rejected: NULL
-- CALL pr_receive_payment(3, 9999, CURRENT_DATE);     -- rejected: above balance
-- CALL pr_receive_payment(99, 100, CURRENT_DATE);     -- rejected: unknown student

-- (e) View: only students who still owe fees (Brian is settled so is excluded)
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM   students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

-- SELECT * FROM v_fee_balances;   -- Alice 2000, Chanda 4000

-- (f) Composite index: equality column first, range column second
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;

-- Plan for the matching query (seqscan off only because the table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT payment_id, amount, paid_on
FROM   payments
WHERE  student_id = 1
  AND  paid_on BETWEEN DATE '2026-11-22' AND DATE '2026-11-24';
RESET enable_seqscan;

-- Justification: the query filters student_id by equality and paid_on by
-- range. With (student_id, paid_on) one index lookup finds the student and
-- reads that student's date range in order, so no full scan of payments is
-- needed. PostgreSQL does not automatically index foreign keys, so this
-- index also helps the student_id foreign key and the balance calculation.

-- (g) Collections refresh: recalculated from payments and overwritten,
-- so reruns never double count
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM   payments
    WHERE  paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
       SET payment_count = EXCLUDED.payment_count,
           total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(DATE '2026-11-22');
CALL pr_refresh_collections(DATE '2026-11-23');
CALL pr_refresh_collections(DATE '2026-11-24');
CALL pr_refresh_collections(DATE '2026-11-24');   -- rerun: replaces, no double count

-- Schedule daily at 01:00 for the previous day (needs pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('refresh-collections', '0 1 * * *',
--     $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time
-- FROM cron.job_run_details ORDER BY start_time DESC;

-- Final check
SELECT * FROM daily_collections ORDER BY collection_date;