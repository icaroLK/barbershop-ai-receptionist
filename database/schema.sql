-- Barbershop receptionist demo: schema, seed data and the functions the AI agent calls.
--
-- Setup, as a superuser:
--   CREATE USER barbershop WITH PASSWORD '...';
--   CREATE DATABASE barbershop OWNER barbershop;
--   ALTER DATABASE barbershop SET timezone TO 'America/Sao_Paulo';
--   \c barbershop
--   CREATE EXTENSION btree_gist;   -- needed by the no_double_booking constraint
-- Then run this file as the barbershop user inside the barbershop database.

SET timezone = 'America/Sao_Paulo';

CREATE TABLE barbers (
  id   int PRIMARY KEY,
  name text NOT NULL
);

CREATE TABLE services (
  id           int PRIMARY KEY,
  name         text NOT NULL,
  duration_min int  NOT NULL,
  price_brl    numeric(8,2) NOT NULL
);

-- dow: 0 = Sunday ... 6 = Saturday. Days without a row are closed.
CREATE TABLE business_hours (
  dow        int PRIMARY KEY CHECK (dow BETWEEN 0 AND 6),
  opens_at   time NOT NULL,
  closes_at  time NOT NULL
);

CREATE TABLE appointments (
  id               serial PRIMARY KEY,
  customer_name    text NOT NULL,
  customer_contact text NOT NULL,
  channel          text NOT NULL,
  service_id       int  NOT NULL REFERENCES services(id),
  barber_id        int  NOT NULL REFERENCES barbers(id),
  starts_at        timestamptz NOT NULL,
  ends_at          timestamptz NOT NULL,
  status           text NOT NULL DEFAULT 'booked' CHECK (status IN ('booked', 'cancelled')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  -- A barber can never have two overlapping booked appointments.
  CONSTRAINT no_double_booking EXCLUDE USING gist (
    barber_id WITH =,
    tstzrange(starts_at, ends_at) WITH &&
  ) WHERE (status = 'booked')
);

CREATE INDEX appointments_contact_idx ON appointments (customer_contact, starts_at);

INSERT INTO barbers VALUES (1, 'Rafael'), (2, 'Diego'), (3, 'Thiago');

INSERT INTO services VALUES
  (1, 'Corte de cabelo',             30, 45.00),
  (2, 'Barba',                       30, 35.00),
  (3, 'Corte + barba',               60, 70.00),
  (4, 'Pezinho / acabamento',        15, 20.00),
  (5, 'Sobrancelha',                 15, 15.00);

INSERT INTO business_hours VALUES
  (2, '09:00', '19:00'),
  (3, '09:00', '19:00'),
  (4, '09:00', '19:00'),
  (5, '09:00', '20:00'),
  (6, '08:00', '17:00');

-- Free start times for a service on a date, every 15 minutes, per barber.
CREATE FUNCTION available_slots(p_date date, p_service_id int, p_barber_id int DEFAULT NULL)
RETURNS TABLE (barber_id int, barber text, start_time text)
LANGUAGE sql STABLE AS $$
  WITH svc AS (SELECT duration_min FROM services WHERE id = p_service_id),
  hrs AS (SELECT opens_at, closes_at FROM business_hours WHERE dow = extract(dow FROM p_date)),
  candidates AS (
    SELECT b.id AS barber_id, b.name AS barber, s AS slot_start,
           s + make_interval(mins => (SELECT duration_min FROM svc)) AS slot_end
    FROM barbers b
    CROSS JOIN hrs
    CROSS JOIN generate_series(
      (p_date + hrs.opens_at)::timestamptz,
      (p_date + hrs.closes_at)::timestamptz - make_interval(mins => (SELECT duration_min FROM svc)),
      interval '15 minutes') AS s
    WHERE p_barber_id IS NULL OR b.id = p_barber_id
  )
  SELECT c.barber_id, c.barber, to_char(c.slot_start, 'HH24:MI')
  FROM candidates c
  WHERE c.slot_start > now()
    AND NOT EXISTS (
      SELECT 1 FROM appointments a
      WHERE a.barber_id = c.barber_id AND a.status = 'booked'
        AND tstzrange(a.starts_at, a.ends_at) && tstzrange(c.slot_start, c.slot_end))
  ORDER BY c.slot_start, c.barber_id;
$$;

-- Books a slot. If p_barber_id is NULL, any free barber is picked. Never raises: returns {ok, ...}.
CREATE FUNCTION book_appointment(p_contact text, p_channel text, p_customer_name text,
                                 p_service_id int, p_barber_id int, p_starts_at timestamp)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_start  timestamptz := p_starts_at::timestamptz;
  v_dur    int;
  v_end    timestamptz;
  v_hours  business_hours%ROWTYPE;
  v_barber int;
  v_id     int;
BEGIN
  SELECT duration_min INTO v_dur FROM services WHERE id = p_service_id;
  IF v_dur IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unknown service_id');
  END IF;
  v_end := v_start + make_interval(mins => v_dur);

  IF v_start <= now() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'that time is in the past');
  END IF;

  SELECT * INTO v_hours FROM business_hours WHERE dow = extract(dow FROM p_starts_at);
  IF NOT FOUND OR p_starts_at::time < v_hours.opens_at
     OR (p_starts_at + make_interval(mins => v_dur))::time > v_hours.closes_at THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'outside business hours');
  END IF;

  SELECT b.id INTO v_barber FROM barbers b
  WHERE (p_barber_id IS NULL OR b.id = p_barber_id)
    AND NOT EXISTS (
      SELECT 1 FROM appointments a
      WHERE a.barber_id = b.id AND a.status = 'booked'
        AND tstzrange(a.starts_at, a.ends_at) && tstzrange(v_start, v_end))
  ORDER BY b.id LIMIT 1;

  IF v_barber IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'slot already taken, check availability again');
  END IF;

  INSERT INTO appointments (customer_name, customer_contact, channel, service_id, barber_id, starts_at, ends_at)
  VALUES (p_customer_name, p_contact, p_channel, p_service_id, v_barber, v_start, v_end)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true, 'appointment_id', v_id,
    'barber', (SELECT name FROM barbers WHERE id = v_barber),
    'service', (SELECT name FROM services WHERE id = p_service_id),
    'starts_at', to_char(v_start, 'YYYY-MM-DD HH24:MI'));
EXCEPTION WHEN exclusion_violation THEN
  RETURN jsonb_build_object('ok', false, 'reason', 'slot already taken, check availability again');
END;
$$;

-- Upcoming booked appointments for one customer.
CREATE FUNCTION my_appointments(p_contact text)
RETURNS TABLE (appointment_id int, service text, barber text, starts_at text, price_brl numeric)
LANGUAGE sql STABLE AS $$
  SELECT a.id, s.name, b.name, to_char(a.starts_at, 'YYYY-MM-DD HH24:MI (Dy)'), s.price_brl
  FROM appointments a
  JOIN services s ON s.id = a.service_id
  JOIN barbers b ON b.id = a.barber_id
  WHERE a.customer_contact = p_contact AND a.status = 'booked' AND a.starts_at > now()
  ORDER BY a.starts_at;
$$;

-- Cancels one of the customer's own appointments.
CREATE FUNCTION cancel_appointment(p_contact text, p_appointment_id int)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE appointments SET status = 'cancelled'
  WHERE id = p_appointment_id AND customer_contact = p_contact AND status = 'booked';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no booked appointment with that id for this customer');
  END IF;
  RETURN jsonb_build_object('ok', true, 'cancelled_appointment_id', p_appointment_id);
END;
$$;
