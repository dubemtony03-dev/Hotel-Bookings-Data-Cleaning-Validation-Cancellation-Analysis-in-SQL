-- =====================================================================
-- 02_clean.sql  |  Typed stage -> duplicate stage -> bookings_clean
-- Dialect: SQLite. raw_bookings is never modified. No row is ever deleted:
-- problems are fixed where it is safe and FLAGGED where it is not.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Reference tables
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ref_months;
CREATE TABLE ref_months (month_name TEXT PRIMARY KEY, month_num INTEGER NOT NULL);
INSERT INTO ref_months VALUES
 ('January',1),('February',2),('March',3),('April',4),('May',5),('June',6),
 ('July',7),('August',8),('September',9),('October',10),('November',11),('December',12);

-- "CN" is the only 2-letter country code; every other value is ISO 3166 alpha-3.
DROP TABLE IF EXISTS ref_country_alias;
CREATE TABLE ref_country_alias (raw_code TEXT PRIMARY KEY, iso3 TEXT NOT NULL);
INSERT INTO ref_country_alias VALUES ('CN','CHN');

-- Meal plans. The dataset documents "Undefined" and "SC" as the same thing: no meal package.
DROP TABLE IF EXISTS ref_meal;
CREATE TABLE ref_meal (raw_code TEXT PRIMARY KEY, meal_plan TEXT NOT NULL);
INSERT INTO ref_meal VALUES
 ('BB','Bed & Breakfast'),('HB','Half board'),('FB','Full board'),
 ('SC','No meal package'),('Undefined','No meal package');

-- ---------------------------------------------------------------------
-- Stage 1: cast every column to its real type and turn the 'NULL' / 'NA' tokens into real NULLs
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_typed;
CREATE TABLE stg_typed AS
SELECT r.row_id,
       TRIM(r.hotel)                                   AS hotel,
       CAST(r.is_canceled AS INTEGER)                  AS is_canceled,
       CAST(r.lead_time AS INTEGER)                    AS lead_time,
       CAST(r.arrival_date_year AS INTEGER)            AS arrival_year,
       m.month_num                                     AS arrival_month,
       CAST(r.arrival_date_day_of_month AS INTEGER)    AS arrival_day,
       CAST(r.stays_in_weekend_nights AS INTEGER)      AS weekend_nights,
       CAST(r.stays_in_week_nights AS INTEGER)         AS week_nights,
       CAST(r.adults AS INTEGER)                       AS adults,
       CAST(NULLIF(r.children, 'NA') AS INTEGER)       AS children,
       CAST(r.babies AS INTEGER)                       AS babies,
       r.meal, 
       NULLIF(r.country, 'NULL')                       AS country,
       r.market_segment, r.distribution_channel,
       CAST(r.is_repeated_guest AS INTEGER)            AS is_repeated_guest,
       CAST(r.previous_cancellations AS INTEGER)       AS previous_cancellations,
       CAST(r.previous_bookings_not_canceled AS INTEGER) AS previous_bookings_not_canceled,
       r.reserved_room_type, r.assigned_room_type,
       CAST(r.booking_changes AS INTEGER)              AS booking_changes,
       r.deposit_type,
       CAST(NULLIF(r.agent, 'NULL')   AS INTEGER)      AS agent_id,
       CAST(NULLIF(r.company, 'NULL') AS INTEGER)      AS company_id,
       CAST(r.days_in_waiting_list AS INTEGER)         AS days_in_waiting_list,
       r.customer_type,
       CAST(r.adr AS REAL)                             AS adr,
       CAST(r.required_car_parking_spaces AS INTEGER)  AS parking_spaces,
       CAST(r.total_of_special_requests AS INTEGER)    AS special_requests,
       r.reservation_status,
       r.reservation_status_date                       AS status_date_raw,
       PRINTF('%04d-%02d-%02d', CAST(r.arrival_date_year AS INTEGER), m.month_num,
              CAST(r.arrival_date_day_of_month AS INTEGER)) AS arrival_date_raw
FROM raw_bookings r
LEFT JOIN ref_months m ON m.month_name = TRIM(r.arrival_date_month);
CREATE UNIQUE INDEX ix_stg_typed ON stg_typed(row_id);

-- ---------------------------------------------------------------------
-- Stage 2: exact-duplicate flag (identical in all 32 original columns)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_dup;
CREATE TABLE stg_dup AS
SELECT row_id,
       CASE WHEN ROW_NUMBER() OVER (
              PARTITION BY hotel, is_canceled, lead_time, arrival_date_year, arrival_date_month, arrival_date_week_number,
                           arrival_date_day_of_month, stays_in_weekend_nights, stays_in_week_nights, adults, children, babies,
                           meal, country, market_segment, distribution_channel, is_repeated_guest, previous_cancellations,
                           previous_bookings_not_canceled, reserved_room_type, assigned_room_type, booking_changes, deposit_type,
                           agent, company, days_in_waiting_list, customer_type, adr, required_car_parking_spaces,
                           total_of_special_requests, reservation_status, reservation_status_date
              ORDER BY row_id) > 1 THEN 1 ELSE 0 END AS is_duplicate
FROM raw_bookings;
CREATE UNIQUE INDEX ix_stg_dup ON stg_dup(row_id);

-- ---------------------------------------------------------------------
-- Stage 3: final table. Validated dates, standardised codes, derived measures and quality flags.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS bookings_clean;
CREATE TABLE bookings_clean AS
WITH t AS (
  SELECT s.*,
         CASE WHEN DATE(arrival_date_raw) = arrival_date_raw THEN arrival_date_raw END AS arrival_date,
         CASE WHEN DATE(status_date_raw)  = status_date_raw  THEN status_date_raw  END AS reservation_status_date,
         weekend_nights + week_nights                                        AS total_nights,
         adults + COALESCE(children, 0) + babies                             AS total_guests
  FROM stg_typed s),
f AS (
  SELECT t.*,
         CASE WHEN total_guests = 0 THEN 1 ELSE 0 END                        AS flag_zero_guests,
         CASE WHEN total_nights = 0 THEN 1 ELSE 0 END                        AS flag_zero_nights,
         CASE WHEN adr <= 0 THEN 1 ELSE 0 END                                AS flag_adr_nonpositive,
         CASE WHEN adr > 1000 THEN 1 ELSE 0 END                              AS flag_adr_outlier,
         CASE WHEN adults > 10 OR COALESCE(children,0) > 5 OR babies > 3 THEN 1 ELSE 0 END AS flag_extreme_party
  FROM t)
SELECT f.row_id,
       f.hotel,
       f.is_canceled,
       f.reservation_status,
       f.reservation_status_date,
       f.arrival_date,
       f.arrival_year,
       f.arrival_month,
       CAST(STRFTIME('%w', f.arrival_date) AS INTEGER)                       AS arrival_weekday,   -- 0 = Sunday
       DATE(f.arrival_date, '-' || f.lead_time || ' days')                   AS booking_date,
       f.lead_time,
       CASE WHEN f.lead_time <= 7   THEN '1. 0-7 days'
            WHEN f.lead_time <= 30  THEN '2. 8-30 days'
            WHEN f.lead_time <= 90  THEN '3. 31-90 days'
            WHEN f.lead_time <= 180 THEN '4. 91-180 days'
            WHEN f.lead_time <= 365 THEN '5. 181-365 days'
            ELSE '6. 366+ days' END                                          AS lead_time_bucket,
       f.weekend_nights, f.week_nights, f.total_nights,
       f.adults, COALESCE(f.children, 0) AS children, f.babies, f.total_guests,
       CASE WHEN f.children IS NULL THEN 1 ELSE 0 END                        AS children_imputed,
       CASE WHEN f.total_guests = 0 THEN 'No guests recorded'
            WHEN COALESCE(f.children,0) + f.babies > 0 THEN 'Family'
            WHEN f.adults = 1 THEN 'Solo'
            WHEN f.adults = 2 THEN 'Couple'
            ELSE 'Group (3+ adults)' END                                     AS party_type,
       COALESCE(ml.meal_plan, 'Not specified')                               AS meal_plan,
       COALESCE(ca.iso3, f.country, 'Unknown')                               AS country,
       CASE WHEN f.country IS NULL THEN 1 ELSE 0 END                         AS country_missing,
       CASE WHEN f.market_segment = 'Undefined' THEN 'Not specified' ELSE f.market_segment END AS market_segment,
       CASE WHEN f.distribution_channel = 'Undefined' THEN 'Not specified' ELSE f.distribution_channel END AS distribution_channel,
       f.is_repeated_guest, f.previous_cancellations, f.previous_bookings_not_canceled,
       CASE WHEN (f.is_repeated_guest = 0 AND f.previous_cancellations + f.previous_bookings_not_canceled > 0)
              OR (f.is_repeated_guest = 1 AND f.previous_cancellations + f.previous_bookings_not_canceled = 0)
            THEN 1 ELSE 0 END                                                AS flag_repeat_guest_inconsistent,
       f.reserved_room_type, f.assigned_room_type,
       CASE WHEN f.reserved_room_type <> f.assigned_room_type THEN 1 ELSE 0 END AS room_changed,
       f.booking_changes, f.deposit_type,
       f.agent_id,   CASE WHEN f.agent_id   IS NULL THEN 0 ELSE 1 END        AS has_agent,
       f.company_id, CASE WHEN f.company_id IS NULL THEN 0 ELSE 1 END        AS has_company,
       f.days_in_waiting_list, f.customer_type, f.adr,
       f.parking_spaces, f.special_requests,
       f.flag_zero_guests, f.flag_zero_nights, f.flag_adr_nonpositive, f.flag_adr_outlier, f.flag_extreme_party,
       CASE WHEN f.reservation_status = 'Check-Out'
             AND f.reservation_status_date IS NOT DATE(f.arrival_date, '+' || f.total_nights || ' days')
            THEN 1 ELSE 0 END                                                AS flag_checkout_date_mismatch,
       CASE WHEN f.flag_zero_guests = 0 AND f.flag_zero_nights = 0 AND f.flag_adr_nonpositive = 0
             AND f.flag_adr_outlier = 0 AND f.flag_extreme_party = 0 THEN 1 ELSE 0 END AS is_valid_stay,
       CASE WHEN f.flag_zero_guests = 0 AND f.flag_zero_nights = 0 AND f.flag_adr_nonpositive = 0
             AND f.flag_adr_outlier = 0 AND f.flag_extreme_party = 0
            THEN ROUND(f.adr * f.total_nights, 2) END                        AS booking_value,     -- adr x nights
       d.is_duplicate
FROM f
JOIN stg_dup d ON d.row_id = f.row_id
LEFT JOIN ref_meal ml          ON ml.raw_code = f.meal
LEFT JOIN ref_country_alias ca ON ca.raw_code = f.country;
CREATE UNIQUE INDEX ix_bookings_clean ON bookings_clean(row_id);

-- Analysis views
DROP VIEW IF EXISTS bookings_unique;
CREATE VIEW bookings_unique AS SELECT * FROM bookings_clean WHERE is_duplicate = 0;

DROP VIEW IF EXISTS stays_valid;     -- distinct bookings with trustworthy guests, nights and rate
CREATE VIEW stays_valid AS SELECT * FROM bookings_clean WHERE is_duplicate = 0 AND is_valid_stay = 1;
