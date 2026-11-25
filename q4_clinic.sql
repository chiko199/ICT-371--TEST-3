-- ICT371 Question 4: Clinic Appointment Scheduling
-- Name: CHRISTABEL CHIKOMONA   Student number: 201901101

DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- (a) Tables
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT chk_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED')),
    CONSTRAINT chk_slot CHECK (slot_time IN
        (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL CHECK (booked_count >= 0),
    attended_count  INTEGER NOT NULL CHECK (attended_count >= 0),
    cancelled_count INTEGER NOT NULL CHECK (cancelled_count >= 0)
);

INSERT INTO patients (full_name) VALUES
    ('Alice Mwansa'), ('Brian Phiri'), ('Chanda Zulu');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Mulenga'), ('Dr. Banda'), ('Dr. Tembo');

-- (b) Function: number of a doctor's non-cancelled appointments on a day
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM   appointments
    WHERE  doctor_id = p_doctor_id
      AND  appointment_day = p_day
      AND  status <> 'CANCELLED';

    RETURN v_count;      -- COUNT gives 0 when the day has no bookings
END;
$$;

-- (d) Trigger: reject a clash with another non-cancelled appointment.
-- It excludes the row being changed (matching on appointment_id), so an
-- UPDATE never clashes with itself. The advisory lock makes two sessions
-- that try the same slot at the same moment wait for each other.
CREATE OR REPLACE FUNCTION trg_fn_check_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        PERFORM pg_advisory_xact_lock(
            hashtext(NEW.doctor_id::text || '|' ||
                     NEW.appointment_day::text || '|' ||
                     NEW.slot_time::text));

        IF EXISTS (
            SELECT 1
            FROM   appointments a
            WHERE  a.doctor_id       = NEW.doctor_id
              AND  a.appointment_day = NEW.appointment_day
              AND  a.slot_time       = NEW.slot_time
              AND  a.status         <> 'CANCELLED'
              AND  a.appointment_id IS DISTINCT FROM NEW.appointment_id
        ) THEN
            RAISE EXCEPTION 'Clash: doctor % already has an appointment on % at %',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_clash();

-- (c) Procedure: validate, then insert a BOOKED appointment
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is NULL or in the past', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN
        (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    -- a clash is rejected by trg_check_clash
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- (a, continued) Six appointments, booked through the procedure
CALL pr_book_appointment(1, 1, CURRENT_DATE,     '09:00');   -- 1
CALL pr_book_appointment(2, 1, CURRENT_DATE,     '10:00');   -- 2
CALL pr_book_appointment(3, 2, CURRENT_DATE,     '09:00');   -- 3
CALL pr_book_appointment(1, 2, CURRENT_DATE + 1, '11:00');   -- 4
CALL pr_book_appointment(2, 3, CURRENT_DATE + 1, '12:00');   -- 5
CALL pr_book_appointment(3, 1, CURRENT_DATE + 1, '09:00');   -- 6

-- Give the statuses some variety (these updates also pass through the trigger)
UPDATE appointments SET status = 'ATTENDED'  WHERE appointment_id = 2;
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 5;

-- Tests (remove the -- to run one at a time; each should be rejected
-- except the last, which works because appointment 5 is cancelled)
-- CALL pr_book_appointment(3, 1, CURRENT_DATE, '09:00');       -- clash with 1
-- CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');   -- past date
-- CALL pr_book_appointment(1, 1, CURRENT_DATE + 2, '13:00');   -- bad slot
-- CALL pr_book_appointment(99, 1, CURRENT_DATE + 2, '09:00');  -- unknown patient
-- UPDATE appointments SET slot_time = '09:00' WHERE appointment_id = 2;  -- clash on update
-- SELECT fn_daily_load(1, CURRENT_DATE);                       -- 2
-- SELECT fn_daily_load(3, CURRENT_DATE + 5);                   -- 0
-- CALL pr_book_appointment(1, 3, CURRENT_DATE + 1, '12:00');   -- allowed

-- (e) View: today's BOOKED appointments, names and slot only
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id,
       p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM   appointments a
JOIN   patients p ON p.patient_id = a.patient_id
JOIN   doctors  d ON d.doctor_id  = a.doctor_id
WHERE  a.appointment_day = CURRENT_DATE
  AND  a.status = 'BOOKED'
ORDER BY a.slot_time;

-- SELECT * FROM v_today_appointments;   -- appointments 1 and 3

-- (f) Non-unique index for searches by day and doctor
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

-- Plan for the matching query (seqscan off only because the table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT appointment_id, patient_id, slot_time, status
FROM   appointments
WHERE  appointment_day = CURRENT_DATE
  AND  doctor_id = 1;
RESET enable_seqscan;

-- Justification: the query filters on both columns, so one index lookup
-- goes straight to that doctor's appointments on that day. The index is
-- non-unique because the same day and doctor legitimately appear many times
-- (four slots, and cancelled rows). Putting appointment_day first also lets
-- it serve "everything on this day" queries, such as the daily summary
-- and v_today_appointments.

-- (g) Summary refresh: recalculated and overwritten, so reruns never double count
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM   appointments
    WHERE  appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
       SET booked_count    = EXCLUDED.booked_count,
           attended_count  = EXCLUDED.attended_count,
           cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE);
CALL pr_refresh_clinic_summary(CURRENT_DATE + 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE + 1);   -- rerun: replaced, not doubled

-- Schedule daily at 01:00 for the previous day (needs pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('refresh-clinic-summary', '0 1 * * *',
--     $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time
-- FROM cron.job_run_details ORDER BY start_time DESC;

-- Final check
SELECT * FROM clinic_summary ORDER BY summary_date;