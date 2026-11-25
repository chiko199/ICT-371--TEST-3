-- ICT371 Question 5: Hostel Room Allocation
-- Name: CHRISTABEL CHIKOMONA   Student number: 201901101

DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- (a) Tables
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT chk_status CHECK (status IN ('ACTIVE', 'ENDED')),
    -- ACTIVE requires released_on NULL; ENDED requires a release date
    CONSTRAINT chk_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on))
);

-- Extra safety net: the database itself refuses a second ACTIVE row per student
CREATE UNIQUE INDEX uq_one_active_per_student
    ON allocations (student_id) WHERE status = 'ACTIVE';

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds     INTEGER NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('S001', 'Alice Mwansa'),
    ('S002', 'Brian Phiri'),
    ('S003', 'Chanda Zulu'),
    ('S004', 'Dalitso Banda'),
    ('S005', 'Esther Tembo'),
    ('S006', 'Faith Lungu');

INSERT INTO rooms (room_number, capacity) VALUES
    ('R101', 2),    -- will be full
    ('R102', 3),    -- will be partly occupied
    ('R103', 2);    -- will be empty

-- (b) Function: capacity minus ACTIVE allocations (ENDED ones do not count)
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM   allocations
    WHERE  room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;

-- (d) Trigger: enforces capacity and one ACTIVE allocation per student,
-- even for direct SQL. The row being inserted/updated is excluded from
-- every count (matched on allocation_id), so an UPDATE never counts itself.
CREATE OR REPLACE FUNCTION trg_fn_check_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_others   INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- lock the room row so two sessions cannot take the last bed together
        SELECT capacity INTO v_capacity
        FROM   rooms WHERE room_id = NEW.room_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        IF EXISTS (
            SELECT 1 FROM allocations a
            WHERE  a.student_id = NEW.student_id
              AND  a.status = 'ACTIVE'
              AND  a.allocation_id IS DISTINCT FROM NEW.allocation_id
        ) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        SELECT COUNT(*) INTO v_others
        FROM   allocations a
        WHERE  a.room_id = NEW.room_id
          AND  a.status = 'ACTIVE'
          AND  a.allocation_id IS DISTINCT FROM NEW.allocation_id;

        IF v_others >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_allocation
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_allocation();

-- (c) Procedure: validate, check availability, create one ACTIVE allocation
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM rooms WHERE room_id = p_room_id) THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date must not be NULL';
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    -- lock the room, then check availability
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (a, continued) Seed allocations
-- ENDED history (does not occupy beds). Inserted directly: the trigger
-- only checks ACTIVE rows.
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (4, 1, DATE '2026-01-10', DATE '2026-06-30', 'ENDED'),
    (5, 3, DATE '2026-01-10', DATE '2026-06-30', 'ENDED');

-- ACTIVE allocations through the procedure
CALL pr_allocate_room(1, 1, DATE '2026-11-01');   -- R101 now 1 of 2
CALL pr_allocate_room(2, 1, DATE '2026-11-01');   -- R101 now 2 of 2 (FULL)
CALL pr_allocate_room(3, 2, DATE '2026-11-05');   -- R102 now 1 of 3 (PARTLY)
-- R103 stays EMPTY (only ended history)

-- Tests (remove the -- to run one at a time; each should be rejected
-- except the last one, which must succeed)
-- SELECT fn_free_beds(1);                          -- 0
-- SELECT fn_free_beds(2);                          -- 2
-- SELECT fn_free_beds(3);                          -- 2 (ended rows do not count)
-- SELECT fn_free_beds(99);                         -- unknown room
-- CALL pr_allocate_room(1, 2, CURRENT_DATE);       -- student already ACTIVE
-- CALL pr_allocate_room(6, 1, CURRENT_DATE);       -- room full
-- CALL pr_allocate_room(99, 2, CURRENT_DATE);      -- unknown student
-- INSERT INTO allocations (student_id, room_id, allocated_on, status)
--     VALUES (6, 1, CURRENT_DATE, 'ACTIVE');       -- direct SQL: trigger rejects (full)
-- UPDATE allocations SET status = 'ACTIVE', released_on = NULL
--     WHERE student_id = 4;                        -- re-activating into a full room: rejected
-- UPDATE allocations SET allocated_on = allocated_on + 1
--     WHERE student_id = 1;                        -- allowed: the row is not counted against itself

-- (e) View: every room, including rooms with no allocations
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM   rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity
ORDER BY r.room_id;

-- SELECT * FROM v_room_occupancy;   -- R101 2/0, R102 1/2, R103 0/2

-- (f) Partial index: only ACTIVE rows are indexed, by room
CREATE INDEX idx_alloc_room_active ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

-- Plan for the matching query (seqscan off only because the table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT allocation_id, student_id, allocated_on
FROM   allocations
WHERE  room_id = 1
  AND  status = 'ACTIVE';
RESET enable_seqscan;

-- Justification: capacity checks, fn_free_beds and the view all ask for
-- "the ACTIVE allocations of one room". A partial index on (room_id)
-- WHERE status = 'ACTIVE' holds only current allocations, so it stays small
-- while ENDED history grows, and the planner can use it because the query
-- repeats the same status = 'ACTIVE' condition.

-- (g) Occupancy snapshot: one row per date and room, replaced on rerun
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
    FROM   rooms r
    LEFT JOIN allocations a
           ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
       SET occupied_beds = EXCLUDED.occupied_beds,
           free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();   -- rerun: values replaced, no duplicate rows

-- Schedule daily at 23:55 (needs pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('refresh-occupancy', '55 23 * * *',
--     $$CALL pr_refresh_occupancy()$$);
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time
-- FROM cron.job_run_details ORDER BY start_time DESC;

-- Final check
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;