-- ==========================================
-- ICT371 QUESTION 4: Clinic Appointment Scheduling
-- ==========================================

-- Clean up existing tables
DROP TABLE IF EXISTS clinic_summary, appointments, patients, doctors CASCADE;

-- ---------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ---------------------------------------------------------
CREATE TABLE patients (
  patient_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
  doctor_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
  appointment_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  patient_id      INT NOT NULL REFERENCES patients(patient_id),
  doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
  appointment_day DATE NOT NULL,
  slot_time       TIME NOT NULL,
  status          VARCHAR(10) NOT NULL CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);

CREATE TABLE clinic_summary (
  summary_date    DATE PRIMARY KEY,
  booked_count    INT NOT NULL DEFAULT 0,
  attended_count  INT NOT NULL DEFAULT 0,
  cancelled_count INT NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------
-- (b) Function [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE v_count INT;
BEGIN
  -- Reject unknown doctor
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor %', p_doctor_id; END IF;
  
  -- Count non-cancelled appointments
  SELECT COUNT(*) INTO v_count 
  FROM appointments
  WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED';
  
  RETURN v_count;
END $$;

-- ---------------------------------------------------------
-- (c) Procedure [8 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
  -- Reject past date or unsupported slot
  IF p_day < CURRENT_DATE THEN RAISE EXCEPTION 'Past date not allowed'; END IF;
  IF p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN RAISE EXCEPTION 'Unsupported slot time'; END IF;
  
  -- Validate IDs
  PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient'; END IF;
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor'; END IF;
  
  -- Insert (Trigger will check for clashes)
  INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status)
  VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END $$;

-- ---------------------------------------------------------
-- (d) Trigger [8 marks]
-- ---------------------------------------------------------
-- BEFORE INSERT OR UPDATE row trigger to reject clashes
CREATE OR REPLACE FUNCTION trg_appt_clash() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM appointments
    WHERE doctor_id = NEW.doctor_id
      AND appointment_day = NEW.appointment_day
      AND slot_time = NEW.slot_time
      AND status <> 'CANCELLED'
      -- Exclude the row being updated from the clash search
      AND appointment_id <> COALESCE(NEW.appointment_id, -1)
  ) THEN
    RAISE EXCEPTION 'Slot % on % already booked', NEW.slot_time, NEW.appointment_day;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_appointments_clash 
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appt_clash();

-- ---------------------------------------------------------
-- (e) View [5 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p USING (patient_id)
JOIN doctors d USING (doctor_id)
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';

-- ---------------------------------------------------------
-- (f) Index [5 marks]
-- ---------------------------------------------------------
CREATE INDEX idx_appt_day_doctor ON appointments(appointment_day, doctor_id);
-- EXPLAIN SELECT * FROM appointments WHERE appointment_day='2025-01-01' AND doctor_id=1;

-- ---------------------------------------------------------
-- (g) Scheduled job [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE) LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO clinic_summary(summary_date, booked_count, attended_count, cancelled_count)
  SELECT p_day,
         COUNT(*) FILTER (WHERE status='BOOKED'),
         COUNT(*) FILTER (WHERE status='ATTENDED'),
         COUNT(*) FILTER (WHERE status='CANCELLED')
  FROM appointments WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE
    SET booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END $$;

-- SELECT cron.schedule('clinic-daily','0 1 * * *',$$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

-- ==========================================
-- SEED DATA & TESTING
-- ==========================================

-- 1. Insert patients and doctors
INSERT INTO patients(full_name) VALUES ('John Doe'), ('Jane Smith'), ('Mike Ross');
INSERT INTO doctors(full_name) VALUES ('Dr. House'), ('Dr. Wilson'), ('Dr. Cuddy');

-- 2. Book 6 appointments via procedure
CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE, '10:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE, '09:00');
CALL pr_book_appointment(1, 2, CURRENT_DATE, '11:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE, '12:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE, '10:00');

-- 3. Test the trigger (This SHOULD fail because Dr. House has 09:00 booked)
-- Uncomment the line below to test:
-- CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00'); 

-- 4. Mark one appointment as attended and one as cancelled for testing
UPDATE appointments SET status = 'ATTENDED' WHERE appointment_id = 1;
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 3;

-- 5. Check view (Should NOT show the cancelled appointment)
SELECT * FROM v_today_appointments;

-- 6. Run daily summary
CALL pr_refresh_clinic_summary(CURRENT_DATE);
SELECT * FROM clinic_summary;
