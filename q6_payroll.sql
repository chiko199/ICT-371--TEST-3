-- ICT371 Question 6: Monthly Payroll Processing
-- Name: CHRISTABEL CHIKOMONA   Student number: 201901101

DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- (a) Tables
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    -- pay_month must be the first day of a month
    CONSTRAINT chk_pay_month_start CHECK (EXTRACT(DAY FROM pay_month) = 1),
    -- one payroll row per employee per month
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

-- Seed employees: four active, one inactive from the start
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Alice Mwansa',  5000.00,  800.00, 600.00, TRUE),
    ('Brian Phiri',   4000.00,  500.00, 400.00, TRUE),
    ('Chanda Zulu',   6000.00, 1000.00, 900.00, TRUE),
    ('Dalitso Banda', 3500.00,  400.00, 300.00, TRUE),    -- becomes inactive later
    ('Esther Tembo',  3000.00,  300.00, 250.00, FALSE);   -- inactive, never paid

-- (b) Function: net pay = basic + allowance - deduction
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_basic NUMERIC(12,2);
    v_allow NUMERIC(12,2);
    v_ded   NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
      INTO v_basic, v_allow, v_ded
      FROM employees
     WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := v_basic + v_allow - v_ded;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- (c) Procedure: process a month with a query FOR loop over active employees.
-- An existing row is left unchanged. If any employee's calculation is
-- invalid, fn_net_pay raises an exception, so the WHOLE call is rolled back
-- and no payroll rows are saved for that month.
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    r     RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;

    FOR r IN
        SELECT employee_id, basic_salary, allowance
        FROM   employees
        WHERE  active
        ORDER BY employee_id
    LOOP
        -- already processed: leave the existing record unchanged
        CONTINUE WHEN EXISTS (SELECT 1 FROM payroll
                              WHERE employee_id = r.employee_id
                                AND pay_month   = p_month);

        v_net := fn_net_pay(r.employee_id);   -- raises on an invalid calculation

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- (d) Trigger: log an actual basic_salary change only
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- (a, continued) Payroll for two months, then changes over time
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

UPDATE employees SET active = FALSE WHERE employee_id = 4;     -- Dalitso leaves
UPDATE employees SET basic_salary = 4500.00 WHERE employee_id = 2;   -- Brian's raise (audited)

CALL pr_process_payroll(DATE '2026-10-01');   -- rerun: existing rows unchanged
CALL pr_process_payroll(DATE '2026-11-01');   -- Dalitso skipped; Brian paid at new salary

-- Tests (remove the -- to run one at a time)
-- SELECT fn_net_pay(1);                          -- 5200.00
-- SELECT fn_net_pay(99);                         -- unknown employee
-- CALL pr_process_payroll(DATE '2026-11-15');    -- not a month start: rejected
-- CALL pr_process_payroll(NULL);                 -- rejected
-- UPDATE employees SET basic_salary = basic_salary WHERE employee_id = 1;  -- same value: no audit row
-- SELECT * FROM salary_audit;                    -- only Brian's raise
-- Whole-call failure: make one employee's net negative, process, then restore
-- UPDATE employees SET deduction = 99999 WHERE employee_id = 3;
-- CALL pr_process_payroll(DATE '2026-12-01');    -- ERROR; no December rows are saved
-- UPDATE employees SET deduction = 900 WHERE employee_id = 3;

-- (e) View: includes history of employees who later became inactive
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM   payroll p
JOIN   employees e ON e.employee_id = p.employee_id;

-- (f) Index for a report filtered by pay_month across all employees
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

-- Plan for the matching query (seqscan off only because the table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM   payroll
WHERE  pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- Justification: the existing unique index is (employee_id, pay_month). It
-- starts with employee_id, so it cannot be searched efficiently by
-- pay_month alone. A report for one month across all employees needs
-- pay_month as the leading column. This index does not duplicate the
-- unique one: it has a different leading column and serves a different query.

-- (g) Scheduled job: 02:00 on the 1st of each month, previous month's first date
-- (needs pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('process-monthly-payroll', '0 2 1 * *',
--     $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- Inspect its run history
-- SELECT jobid, status, return_message, start_time, end_time
-- FROM cron.job_run_details ORDER BY start_time DESC;
-- Remove the job
-- SELECT cron.unschedule('process-monthly-payroll');

-- Final check
SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;