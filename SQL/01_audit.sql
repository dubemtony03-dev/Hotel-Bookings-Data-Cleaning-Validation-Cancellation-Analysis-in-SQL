-- =====================================================================
-- 01_audit.sql  |  Profile the RAW data before touching it
-- Dialect: SQLite. Every column is loaded as TEXT, exactly as it appears in the file.
-- Read-only: nothing in this file changes any table.
-- =====================================================================

-- name: audit_row_counts
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT row_id) AS distinct_row_id FROM raw_bookings;

-- name: audit_missing_tokens
-- Missing values are stored as the text tokens 'NULL' and 'NA', not as empty cells.
SELECT 'company'  AS column_name, SUM(company  = 'NULL') AS missing, COUNT(*) AS total FROM raw_bookings
UNION ALL SELECT 'agent',    SUM(agent    = 'NULL'), COUNT(*) FROM raw_bookings
UNION ALL SELECT 'country',  SUM(country  = 'NULL'), COUNT(*) FROM raw_bookings
UNION ALL SELECT 'children', SUM(children = 'NA'),   COUNT(*) FROM raw_bookings
ORDER BY missing DESC;

-- name: audit_undefined_codes
SELECT 'meal = Undefined'                  AS issue, SUM(meal = 'Undefined')                  AS rows FROM raw_bookings
UNION ALL SELECT 'market_segment = Undefined',        SUM(market_segment = 'Undefined')        FROM raw_bookings
UNION ALL SELECT 'distribution_channel = Undefined',  SUM(distribution_channel = 'Undefined')  FROM raw_bookings
UNION ALL SELECT 'country code not 3 letters (e.g. CN)', SUM(country <> 'NULL' AND LENGTH(country) <> 3) FROM raw_bookings;

-- name: audit_impossible_values
SELECT 'bookings with zero guests'      AS issue, SUM(CAST(adults AS INT) + COALESCE(CAST(NULLIF(children,'NA') AS INT),0) + CAST(babies AS INT) = 0) AS rows FROM raw_bookings
UNION ALL SELECT 'bookings with zero nights',          SUM(CAST(stays_in_weekend_nights AS INT) + CAST(stays_in_week_nights AS INT) = 0) FROM raw_bookings
UNION ALL SELECT 'adr = 0 (free stay)',                SUM(CAST(adr AS REAL) = 0)  FROM raw_bookings
UNION ALL SELECT 'adr < 0 (negative rate)',            SUM(CAST(adr AS REAL) < 0)  FROM raw_bookings
UNION ALL SELECT 'adr > 1,000',                        SUM(CAST(adr AS REAL) > 1000) FROM raw_bookings
UNION ALL SELECT 'more than 10 adults',                SUM(CAST(adults AS INT) > 10) FROM raw_bookings
UNION ALL SELECT 'stays over 30 nights',               SUM(CAST(stays_in_weekend_nights AS INT) + CAST(stays_in_week_nights AS INT) > 30) FROM raw_bookings;

-- name: audit_status_vs_cancelled
SELECT reservation_status, is_canceled, COUNT(*) AS rows FROM raw_bookings GROUP BY 1, 2 ORDER BY rows DESC;

-- name: audit_repeat_guest_consistency
SELECT SUM(is_repeated_guest = '0' AND CAST(previous_cancellations AS INT) + CAST(previous_bookings_not_canceled AS INT) > 0) AS flagged_new_but_has_history,
       SUM(is_repeated_guest = '1' AND CAST(previous_cancellations AS INT) + CAST(previous_bookings_not_canceled AS INT) = 0) AS flagged_repeat_but_no_history
FROM raw_bookings;

-- name: audit_exact_duplicates
-- There is no booking ID, so rows identical in all 32 columns are the only duplicates that can be detected.
SELECT (SELECT COUNT(*) FROM raw_bookings) - COUNT(*) AS exact_duplicate_rows
FROM (SELECT DISTINCT hotel, is_canceled, lead_time, arrival_date_year, arrival_date_month, arrival_date_week_number,
             arrival_date_day_of_month, stays_in_weekend_nights, stays_in_week_nights, adults, children, babies, meal, country,
             market_segment, distribution_channel, is_repeated_guest, previous_cancellations, previous_bookings_not_canceled,
             reserved_room_type, assigned_room_type, booking_changes, deposit_type, agent, company, days_in_waiting_list,
             customer_type, adr, required_car_parking_spaces, total_of_special_requests, reservation_status, reservation_status_date
      FROM raw_bookings);

-- name: audit_cancellation_rate_raw
SELECT ROUND(100.0 * SUM(is_canceled = '1') / COUNT(*), 1) AS pct_cancelled_all_rows FROM raw_bookings;

-- name: audit_date_text
SELECT MIN(arrival_date_year) AS first_year, MAX(arrival_date_year) AS last_year,
       COUNT(DISTINCT arrival_date_month) AS distinct_month_names,
       MIN(reservation_status_date) AS earliest_status_date, MAX(reservation_status_date) AS latest_status_date
FROM raw_bookings;
