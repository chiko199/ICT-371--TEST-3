-- ICT371 Question 8: Transport Fleet Maintenance
-- Name: CHRISTABEL CHIKOMONA   Student number: 201901101

DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Tables
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE    NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL CHECK (km_since_service >= 0),
    flagged_on       DATE    NOT NULL DEFAULT CURRENT_DATE
);

-- Three vehicles with different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ZM-101-A', 12000, 10000),   -- 2000 km since service (not due)
    ('ZM-202-B', 30000, 24000),   -- 6000 km since service (due)
    ('ZM-303-C',  7500,  3000);   -- 4500 km since service (close to the limit)

-- (b) Function: TRUE when at least 5,000 km since the last service
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    c_threshold CONSTANT INTEGER := 5000;
    v_current   INTEGER;
    v_service   INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer
      INTO v_current, v_service
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_service) >= c_threshold;
END;
$$;

-- (d) Trigger: BEFORE INSERT on trips. It rejects invalid mileage, checks
-- that the trip starts at the vehicle's current odometer, and moves the
-- odometer to the trip end. A BEFORE INSERT row trigger fires once per
-- inserted row, so the odometer is updated exactly once per trip. If the
-- insert later fails, the whole statement is rolled back, odometer included.
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL THEN
        RAISE EXCEPTION 'Start and end odometer must not be NULL';
    END IF;
    IF NEW.start_odometer < 0 THEN
        RAISE EXCEPTION 'Start odometer must not be negative (got %)', NEW.start_odometer;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%)',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    -- lock the vehicle row so two trips cannot start from the same reading
    SELECT current_odometer INTO v_current
    FROM   vehicles
    WHERE  vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer % (got %)',
            v_current, NEW.start_odometer;
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- (c) Procedure: validate, then insert the trip. It does NOT touch the
-- vehicle odometer; the trigger does that.
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      INTEGER,
    p_end        INTEGER)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date must not be NULL';
    END IF;
    IF p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Start and end odometer must not be NULL';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%)',
            p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (a, continued) Six trips, added through the procedure AFTER the trigger exists
CALL pr_record_trip(1, DATE '2026-11-20', 12000, 12500);
CALL pr_record_trip(1, DATE '2026-11-22', 12500, 13200);
CALL pr_record_trip(2, DATE '2026-11-21', 30000, 30400);
CALL pr_record_trip(2, DATE '2026-11-23', 30400, 31000);
CALL pr_record_trip(3, DATE '2026-11-22',  7500,  7800);
CALL pr_record_trip(3, DATE '2026-11-24',  7800,  8200);
-- Vehicle 1 ends at 13200 (3200 km since service, not due)
-- Vehicle 2 ends at 31000 (7000 km since service, due)
-- Vehicle 3 ends at  8200 (5200 km since service, now due)

-- Tests (remove the -- to run one at a time; each should be rejected)
-- SELECT fn_service_due(2);                                  -- true
-- SELECT fn_service_due(1);                                  -- false
-- SELECT fn_service_due(99);                                 -- unknown vehicle
-- CALL pr_record_trip(1, CURRENT_DATE, 99999, 100500);       -- start does not match odometer
-- CALL pr_record_trip(1, CURRENT_DATE, 13200, 13200);        -- end not greater than start
-- CALL pr_record_trip(99, CURRENT_DATE, 100, 200);           -- unknown vehicle
-- INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
--     VALUES (1, CURRENT_DATE, 5, 50);                       -- direct SQL: trigger rejects
-- SELECT vehicle_id, current_odometer FROM vehicles;         -- unchanged after rejections

-- (e) View: vehicles that currently meet the 5,000 km threshold
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM   vehicles
WHERE  current_odometer - last_service_odometer >= 5000;

-- SELECT * FROM v_service_due;   -- ZM-202-B (7000) and ZM-303-C (5200)

-- (f) Composite index: one vehicle's trips within a trip_on date range
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);
ANALYZE trips;

-- Plan for the matching query (seqscan off only because the table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM   trips
WHERE  vehicle_id = 1
  AND  trip_on BETWEEN DATE '2026-11-20' AND DATE '2026-11-24';
RESET enable_seqscan;

-- Justification: the query has an equality on vehicle_id and a range on
-- trip_on. With (vehicle_id, trip_on) one index lookup finds the vehicle and
-- then reads its date range as a contiguous, already-ordered slice, so
-- other vehicles' trips are never scanned. An index on trip_on alone would
-- return every vehicle's trips for those dates and need a filter.

-- (g) Alert refresh: one alert per due vehicle, removed once no longer due.
-- Inserts or updates alerts for due vehicles, then deletes alerts for
-- vehicles that are not due. Reruns give the same result (no duplicates).
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id,
           current_odometer - last_service_odometer,
           CURRENT_DATE
    FROM   vehicles
    WHERE  fn_service_due(vehicle_id)
    ON CONFLICT (vehicle_id) DO UPDATE
       SET km_since_service = EXCLUDED.km_since_service;   -- keeps the original flagged_on

    DELETE FROM service_alerts sa
    WHERE  NOT fn_service_due(sa.vehicle_id);
END;
$$;

CALL pr_refresh_service_alerts();   -- alerts for vehicles 2 and 3
CALL pr_refresh_service_alerts();   -- rerun: no duplicates

-- Vehicle 2 is serviced: last service becomes its current odometer
UPDATE vehicles
   SET last_service_odometer = current_odometer
 WHERE vehicle_id = 2;

CALL pr_refresh_service_alerts();   -- vehicle 2's alert is removed

-- Schedule every Monday at 06:00 (needs pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('refresh-service-alerts', '0 6 * * 1',
--     $$CALL pr_refresh_service_alerts()$$);
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time
-- FROM cron.job_run_details ORDER BY start_time DESC;

-- Final check
SELECT * FROM service_alerts ORDER BY vehicle_id;