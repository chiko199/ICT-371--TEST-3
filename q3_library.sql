-- ICT371 Question 3: Library Returns and Overdue Fines
-- Name: CHRISTABEL CHIKOMONA   Student number: 201901101

DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Tables
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER       NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrowed CHECK (due_on >= borrowed_on),
    CONSTRAINT chk_return_after_borrowed
        CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER   NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE,
    new_returned_on  DATE,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER       NOT NULL CHECK (overdue_count >= 0),
    total_fine    NUMERIC(12,2) NOT NULL CHECK (total_fine >= 0)
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Clean Code');

-- (b) Function: K2 per day after the due date, minimum zero
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    c_rate CONSTANT NUMERIC := 2;     -- K2 per overdue day
    v_due  DATE;
    v_ret  DATE;
    v_end  DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_ret
    FROM loans WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- a returned loan stops accumulating fines at its return date
    IF v_ret IS NOT NULL THEN
        v_end := LEAST(p_as_of, v_ret);
    ELSE
        v_end := p_as_of;
    END IF;

    RETURN c_rate * GREATEST(v_end - v_due, 0);
END;
$$;

-- (c) Procedure: return a loan and store the final fine with the return date
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    -- return date and final fine are stored together in ONE update
    UPDATE loans
       SET returned_on = p_returned_on,
           fine_amount = v_fine
     WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger: log changes to returned_on only
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- (a, continued) Six loans. All start open; the returned ones are closed
-- through the procedure so the fine and audit rows are created properly.
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Alice Mwansa',  DATE '2026-10-20', DATE '2026-11-03'),  -- 1 open, overdue
    (2, 'Brian Phiri',   DATE '2026-11-15', DATE '2026-12-15'),  -- 2 open, on time
    (3, 'Chanda Zulu',   DATE '2026-10-01', DATE '2026-10-15'),  -- 3 returned early
    (1, 'Dalitso Banda', DATE '2026-10-05', DATE '2026-10-19'),  -- 4 returned late
    (2, 'Esther Tembo',  DATE '2026-10-25', DATE '2026-11-08'),  -- 5 open, overdue
    (3, 'Faith Lungu',   DATE '2026-11-10', DATE '2026-11-24');  -- 6 returned on due date

CALL pr_return_loan(3, DATE '2026-10-12');   -- early: fine 0
CALL pr_return_loan(4, DATE '2026-10-24');   -- 5 days late: fine 10
CALL pr_return_loan(6, DATE '2026-11-24');   -- on the due date: fine 0

-- Tests (remove the -- to run one at a time; each should be rejected)
-- SELECT fn_loan_fine(1, DATE '2026-11-24');   -- 42
-- SELECT fn_loan_fine(99, CURRENT_DATE);       -- unknown loan
-- CALL pr_return_loan(3, CURRENT_DATE);        -- already returned
-- CALL pr_return_loan(2, DATE '2026-11-01');   -- before borrowed_on
-- CALL pr_return_loan(99, CURRENT_DATE);       -- unknown loan

-- (e) View: unreturned loans due before today, with the fine as of today
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM   loans l
JOIN   books b ON b.book_id = l.book_id
WHERE  l.returned_on IS NULL
  AND  l.due_on < CURRENT_DATE;

-- SELECT * FROM v_overdue_loans;   -- Alice's and Esther's loans

-- (f) Partial index: only unreturned loans are indexed, by book
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

-- Plan for the matching query (seqscan off only because the table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM   loans
WHERE  book_id = 1
  AND  returned_on IS NULL;
RESET enable_seqscan;

-- Justification: the search is always "unreturned loans of one book". A
-- partial index (book_id) WHERE returned_on IS NULL stores only the open
-- loans, so it stays small as returned loans pile up, and the planner can
-- use it because the query repeats the same returned_on IS NULL condition.

-- (g) Snapshot procedure. A loan counts as overdue on p_as_of when it had
-- been borrowed, was still unreturned on that date (never returned, or
-- returned later) and its due date was before that date. Each run
-- recalculates and overwrites the row, so a rerun never double counts.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM   loans
    WHERE  borrowed_on <= p_as_of
      AND  due_on < p_as_of
      AND  (returned_on IS NULL OR returned_on > p_as_of)
    ON CONFLICT (snapshot_date) DO UPDATE
       SET overdue_count = EXCLUDED.overdue_count,
           total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(DATE '2026-11-24');
CALL pr_refresh_overdue(DATE '2026-11-24');   -- rerun: replaced, not doubled
CALL pr_refresh_overdue(CURRENT_DATE);

-- Schedule daily at 00:10 for CURRENT_DATE (needs pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('refresh-overdue', '10 0 * * *',
--     $$CALL pr_refresh_overdue(CURRENT_DATE)$$);
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time
-- FROM cron.job_run_details ORDER BY start_time DESC;

-- Final check
SELECT * FROM overdue_summary ORDER BY snapshot_date;