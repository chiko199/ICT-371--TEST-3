-- ICT371 Question 10: Scholarship Application Assessment
-- Name: CHRISTABEL CHIKOMONA   Student number: 201901101

DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Tables
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT chk_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('S001', 'Alice Mwansa'),
    ('S002', 'Brian Phiri'),
    ('S003', 'Chanda Zulu'),
    ('S004', 'Dalitso Banda');

-- (b) Function: all three eligibility rules
-- age 18 to 25 inclusive, income at most K3,000, average mark at least 70
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$;

-- (c) Procedure: assess ONE pending application
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status VARCHAR(10);
    v_age    INTEGER;
    v_income NUMERIC(12,2);
    v_mark   NUMERIC(5,2);
BEGIN
    -- lock the row so two sessions cannot assess it at the same time
    SELECT status, age_at_application, monthly_income, average_mark
      INTO v_status, v_age, v_income, v_mark
      FROM applications
     WHERE application_id = p_application_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status: %)',
            p_application_id, v_status;
    END IF;

    UPDATE applications
       SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                         THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger: record actual status changes only
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- (a, continued) Six PENDING applications across four students,
-- covering qualifying, non-qualifying and boundary cases
INSERT INTO applications
    (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 18, 3000.00, 70.00, DATE '2026-11-02', 'PENDING'),   -- 1 boundary: all at the limit -> qualifies
    (2, 25, 2500.00, 85.50, DATE '2026-11-05', 'PENDING'),   -- 2 oldest allowed age -> qualifies
    (3, 17, 1000.00, 90.00, DATE '2026-11-08', 'PENDING'),   -- 3 one year too young -> rejected
    (2, 26, 1500.00, 80.00, DATE '2026-11-12', 'PENDING'),   -- 4 one year too old -> rejected
    (3, 22, 3000.01, 75.00, DATE '2026-11-15', 'PENDING'),   -- 5 income just over -> rejected
    (4, 20, 2000.00, 69.99, DATE '2026-11-18', 'PENDING');   -- 6 mark just under -> rejected

-- Tests (remove the -- to run one at a time)
-- SELECT fn_scholarship_eligible(18, 3000, 70);      -- true  (all boundaries)
-- SELECT fn_scholarship_eligible(25, 3000, 70);      -- true
-- SELECT fn_scholarship_eligible(17, 1000, 90);      -- false
-- SELECT fn_scholarship_eligible(NULL, 1000, 90);    -- rejected: NULL
-- SELECT fn_scholarship_eligible(20, -5, 90);        -- rejected: negative income
-- SELECT fn_scholarship_eligible(0, 1000, 90);       -- rejected: non-positive age
-- SELECT fn_scholarship_eligible(20, 1000, 101);     -- rejected: mark above 100
-- CALL pr_assess_application(99);                    -- unknown application
-- (calling it again on an assessed application is rejected; see below)

-- Assess one application directly
CALL pr_assess_application(1);                        -- becomes APPROVED, one audit row
-- CALL pr_assess_application(1);                     -- rejected: already assessed

-- (e) View: APPROVED applicants only, income omitted
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM   applications a
JOIN   students s ON s.student_id = a.student_id
WHERE  a.status = 'APPROVED';

-- SELECT * FROM v_approved_applicants;

-- (f) Composite index: status (equality) then submitted_on (range)
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

-- Plan for the matching query (seqscan off only because the table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM   applications
WHERE  status = 'PENDING'
  AND  submitted_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';
RESET enable_seqscan;

-- Justification: the search has an equality on status and a range on
-- submitted_on. With (status, submitted_on) one index lookup goes straight
-- to the applications with that status and reads the date range in order,
-- instead of scanning every application.

-- (g) Batch assessment: query FOR loop over PENDING applications only.
-- Each one goes through pr_assess_application. FOR UPDATE SKIP LOCKED
-- avoids waiting on or clashing with rows another session is assessing.
-- Completed applications are never selected, so a rerun does nothing and
-- cannot create duplicate audit entries.
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT application_id
        FROM   applications
        WHERE  status = 'PENDING'
        ORDER BY application_id
        FOR UPDATE SKIP LOCKED
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();   -- assesses the five remaining applications
CALL pr_assess_pending();   -- rerun: nothing is PENDING, so nothing changes

-- Schedule every Monday at 08:00 (needs pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('assess-pending-applications', '0 8 * * 1',
--     $$CALL pr_assess_pending()$$);
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time
-- FROM cron.job_run_details ORDER BY start_time DESC;

-- Final checks
-- SELECT * FROM applications ORDER BY application_id;
-- SELECT * FROM v_approved_applicants;
SELECT * FROM decision_audit ORDER BY audit_id;