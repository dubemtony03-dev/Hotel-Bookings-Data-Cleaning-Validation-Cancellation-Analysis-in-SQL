-- =====================================================================
-- 04_eda.sql  |  Exploratory analysis on the cleaned data
-- Cancellation analysis uses bookings_unique (exact duplicates removed).
-- Rate / revenue analysis uses stays_valid (unique bookings with a trustworthy rate, guests and nights).
-- =====================================================================

-- name: eda_kpis
SELECT (SELECT COUNT(*) FROM bookings_clean)                                              AS rows_in_file,
       (SELECT SUM(is_duplicate) FROM bookings_clean)                                     AS exact_duplicates,
       (SELECT COUNT(*) FROM bookings_unique)                                             AS unique_bookings,
       (SELECT COUNT(*) FROM stays_valid)                                                 AS valid_stays,
       (SELECT ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) FROM bookings_clean)         AS cancel_pct_all_rows,
       (SELECT ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) FROM bookings_unique)        AS cancel_pct_unique,
       (SELECT COUNT(DISTINCT country) FROM bookings_unique WHERE country <> 'Unknown')   AS countries,
       (SELECT MIN(arrival_date) FROM bookings_clean)                                     AS first_arrival,
       (SELECT MAX(arrival_date) FROM bookings_clean)                                     AS last_arrival;

-- name: eda_duplicates_effect
-- Exact duplicates are not random: they are far more likely to be cancelled.
SELECT CASE is_duplicate WHEN 0 THEN 'First occurrence' ELSE 'Repeat of an identical row' END AS row_type,
       COUNT(*) AS bookings,
       ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) AS cancel_pct,
       ROUND(100.0 * SUM(CASE WHEN deposit_type = 'Non Refund' THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_non_refund,
       ROUND(100.0 * SUM(CASE WHEN hotel = 'City Hotel' THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_city_hotel
FROM bookings_clean GROUP BY is_duplicate;

-- name: eda_cancel_by_hotel
SELECT hotel, COUNT(*) AS bookings, ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) AS cancel_pct,
       ROUND(100.0 * SUM(CASE WHEN reservation_status = 'No-Show' THEN 1 ELSE 0 END) / COUNT(*), 2) AS no_show_pct
FROM bookings_unique GROUP BY hotel ORDER BY cancel_pct DESC;

-- name: eda_cancel_by_lead_time
SELECT lead_time_bucket, COUNT(*) AS bookings, ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) AS cancel_pct
FROM bookings_unique GROUP BY lead_time_bucket ORDER BY lead_time_bucket;

-- name: eda_cancel_by_deposit
SELECT deposit_type, COUNT(*) AS bookings, ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) AS cancel_pct
FROM bookings_unique GROUP BY deposit_type ORDER BY bookings DESC;

-- name: eda_cancel_by_segment
SELECT market_segment, COUNT(*) AS bookings, ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM bookings_unique), 1) AS share_pct,
       ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) AS cancel_pct
FROM bookings_unique GROUP BY market_segment HAVING COUNT(*) >= 200 ORDER BY bookings DESC;

-- name: eda_cancel_by_customer_type
SELECT customer_type, COUNT(*) AS bookings, ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) AS cancel_pct
FROM bookings_unique GROUP BY customer_type ORDER BY bookings DESC;

-- name: eda_cancel_by_special_requests
SELECT MIN(special_requests, 3) AS special_requests_capped_at_3, COUNT(*) AS bookings,
       ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) AS cancel_pct
FROM bookings_unique GROUP BY 1 ORDER BY 1;

-- name: eda_cancel_by_parking_and_changes
SELECT 'Car parking space requested' AS grouping, CASE WHEN parking_spaces > 0 THEN 'Yes' ELSE 'No' END AS value,
       COUNT(*) AS bookings, ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) AS cancel_pct FROM bookings_unique GROUP BY 2
UNION ALL SELECT 'Booking was changed', CASE WHEN booking_changes > 0 THEN 'Yes' ELSE 'No' END,
       COUNT(*), ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) FROM bookings_unique GROUP BY 2
UNION ALL SELECT 'Room type changed at check-in', CASE WHEN room_changed = 1 THEN 'Yes' ELSE 'No' END,
       COUNT(*), ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) FROM bookings_unique GROUP BY 2
UNION ALL SELECT 'Has previous cancellation', CASE WHEN previous_cancellations > 0 THEN 'Yes' ELSE 'No' END,
       COUNT(*), ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) FROM bookings_unique GROUP BY 2;

-- name: eda_cancel_by_country
SELECT country, COUNT(*) AS bookings, ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM bookings_unique), 1) AS share_pct,
       ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) AS cancel_pct
FROM bookings_unique WHERE country <> 'Unknown'
GROUP BY country HAVING COUNT(*) >= 1500 ORDER BY bookings DESC;

-- name: eda_monthly_trend
-- Bookings by arrival month with the cancellation rate and a year-on-year comparison.
WITH m AS (
  SELECT arrival_year AS yr, arrival_month AS mo, STRFTIME('%Y-%m', arrival_date) AS ym,
         COUNT(*) AS bookings, ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) AS cancel_pct
  FROM bookings_unique GROUP BY 1, 2, 3)
SELECT a.ym, a.bookings, a.cancel_pct, b.bookings AS bookings_same_month_prior_year,
       ROUND(100.0 * (a.bookings - b.bookings) / b.bookings, 1) AS yoy_change_pct
FROM m a LEFT JOIN m b ON b.mo = a.mo AND b.yr = a.yr - 1
ORDER BY a.ym;

-- name: eda_seasonality_adr
-- Median nightly rate by arrival month and hotel (valid stays that were not cancelled).
WITH s AS (
  SELECT hotel, arrival_month AS month, adr,
         ROW_NUMBER() OVER (PARTITION BY hotel, arrival_month ORDER BY adr) AS rn,
         COUNT(*)     OVER (PARTITION BY hotel, arrival_month) AS n
  FROM stays_valid WHERE is_canceled = 0)
SELECT hotel, month, MAX(n) AS stays, ROUND(AVG(adr), 1) AS median_adr
FROM s WHERE rn IN ((n + 1) / 2, (n + 2) / 2) GROUP BY hotel, month ORDER BY hotel, month;

-- name: eda_seasonality_volume
SELECT arrival_month AS month, hotel, COUNT(*) AS bookings
FROM bookings_unique WHERE arrival_year = 2016 GROUP BY arrival_month, hotel ORDER BY hotel, arrival_month;

-- name: eda_revenue_lost_to_cancellation
-- Booking value = quoted nightly rate x nights, on valid stays. "Lost" = value of cancelled and no-show bookings.
SELECT hotel,
       ROUND(SUM(CASE WHEN is_canceled = 0 THEN booking_value END)) AS realised_value,
       ROUND(SUM(CASE WHEN is_canceled = 1 THEN booking_value END)) AS lost_value,
       ROUND(100.0 * SUM(CASE WHEN is_canceled = 1 THEN booking_value END) / SUM(booking_value), 1) AS lost_pct_of_booked_value
FROM stays_valid GROUP BY hotel;

-- name: eda_revenue_lost_by_segment
SELECT market_segment,
       ROUND(SUM(CASE WHEN is_canceled = 0 THEN booking_value END)) AS realised_value,
       ROUND(SUM(CASE WHEN is_canceled = 1 THEN booking_value END)) AS lost_value,
       ROUND(100.0 * SUM(CASE WHEN is_canceled = 1 THEN booking_value END) / SUM(booking_value), 1) AS lost_pct
FROM stays_valid GROUP BY market_segment HAVING COUNT(*) >= 500 ORDER BY realised_value DESC;

-- name: eda_adr_by_segment
WITH s AS (
  SELECT market_segment, adr,
         ROW_NUMBER() OVER (PARTITION BY market_segment ORDER BY adr) AS rn,
         COUNT(*)     OVER (PARTITION BY market_segment) AS n
  FROM stays_valid WHERE is_canceled = 0)
SELECT market_segment, MAX(n) AS stays, ROUND(AVG(adr), 1) AS median_adr
FROM s WHERE rn IN ((n + 1) / 2, (n + 2) / 2) GROUP BY market_segment HAVING MAX(n) >= 200 ORDER BY median_adr DESC;

-- name: eda_adr_by_party_type
WITH s AS (
  SELECT party_type, adr,
         ROW_NUMBER() OVER (PARTITION BY party_type ORDER BY adr) AS rn,
         COUNT(*)     OVER (PARTITION BY party_type) AS n
  FROM stays_valid WHERE is_canceled = 0)
SELECT party_type, MAX(n) AS stays, ROUND(AVG(adr), 1) AS median_adr
FROM s WHERE rn IN ((n + 1) / 2, (n + 2) / 2) GROUP BY party_type ORDER BY stays DESC;

-- name: eda_stay_length
SELECT hotel,
       ROUND(AVG(total_nights), 2) AS avg_nights,
       ROUND(AVG(CASE WHEN total_nights BETWEEN 1 AND 30 THEN total_nights END), 2) AS avg_nights_excl_outliers,
       ROUND(100.0 * SUM(CASE WHEN weekend_nights = 0 AND week_nights > 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_weekdays_only,
       ROUND(100.0 * SUM(CASE WHEN total_nights >= 7 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_week_or_longer
FROM stays_valid WHERE is_canceled = 0 GROUP BY hotel;

-- name: eda_party_mix
SELECT party_type, COUNT(*) AS bookings, ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM bookings_unique), 1) AS share_pct
FROM bookings_unique GROUP BY party_type ORDER BY bookings DESC;

-- name: eda_lead_time_by_segment
SELECT market_segment, COUNT(*) AS bookings,
       ROUND(AVG(lead_time)) AS avg_lead_days, ROUND(AVG(CASE WHEN is_canceled = 1 THEN lead_time END)) AS avg_lead_cancelled,
       ROUND(AVG(CASE WHEN is_canceled = 0 THEN lead_time END)) AS avg_lead_kept
FROM bookings_unique GROUP BY market_segment HAVING COUNT(*) >= 500 ORDER BY bookings DESC;

-- name: eda_meal_mix
SELECT meal_plan, COUNT(*) AS bookings, ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM bookings_unique), 1) AS share_pct
FROM bookings_unique GROUP BY meal_plan ORDER BY bookings DESC;

-- name: eda_agent_concentration
-- How dependent is the business on a handful of travel agents?
WITH a AS (
  SELECT agent_id, COUNT(*) AS bookings FROM bookings_unique WHERE has_agent = 1 GROUP BY agent_id),
r AS (
  SELECT agent_id, bookings, ROW_NUMBER() OVER (ORDER BY bookings DESC) AS rnk,
         SUM(bookings) OVER (ORDER BY bookings DESC, agent_id ROWS UNBOUNDED PRECEDING) AS running
  FROM a)
SELECT rnk AS top_n_agents, bookings AS bookings_of_nth_agent,
       ROUND(100.0 * running / (SELECT COUNT(*) FROM bookings_unique WHERE has_agent = 1), 1) AS cumulative_pct_of_agent_bookings
FROM r WHERE rnk IN (1, 3, 5, 10, 20, 50);

-- name: eda_arrival_weekday
SELECT CASE arrival_weekday WHEN 0 THEN 'Sun' WHEN 1 THEN 'Mon' WHEN 2 THEN 'Tue' WHEN 3 THEN 'Wed'
                            WHEN 4 THEN 'Thu' WHEN 5 THEN 'Fri' ELSE 'Sat' END AS weekday,
       arrival_weekday AS weekday_num, COUNT(*) AS bookings
FROM bookings_unique GROUP BY arrival_weekday ORDER BY arrival_weekday;

-- name: eda_repeat_guests
SELECT CASE WHEN is_repeated_guest = 1 THEN 'Repeat guest' ELSE 'New guest' END AS guest_type,
       COUNT(*) AS bookings, ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM bookings_unique), 1) AS share_pct,
       ROUND(100.0 * SUM(is_canceled) / COUNT(*), 1) AS cancel_pct
FROM bookings_unique GROUP BY is_repeated_guest;

-- name: eda_field_quality
-- What share of the raw rows is affected by each data-quality problem?
SELECT 'Exact duplicate rows' AS problem, ROUND(100.0 * SUM(is_duplicate) / COUNT(*), 1) AS pct_of_rows FROM bookings_clean
UNION ALL SELECT 'Repeat-guest field contradicts history', ROUND(100.0 * SUM(flag_repeat_guest_inconsistent) / COUNT(*), 1) FROM bookings_clean
UNION ALL SELECT 'Rate is zero or negative',               ROUND(100.0 * SUM(flag_adr_nonpositive) / COUNT(*), 1) FROM bookings_clean
UNION ALL SELECT 'Zero nights recorded',                   ROUND(100.0 * SUM(flag_zero_nights) / COUNT(*), 1) FROM bookings_clean
UNION ALL SELECT 'Country missing',                        ROUND(100.0 * SUM(country_missing) / COUNT(*), 1) FROM bookings_clean
UNION ALL SELECT 'Zero guests recorded',                   ROUND(100.0 * SUM(flag_zero_guests) / COUNT(*), 1) FROM bookings_clean
UNION ALL SELECT 'Check-out date does not match stay',     ROUND(100.0 * SUM(flag_checkout_date_mismatch) / COUNT(*), 1) FROM bookings_clean
ORDER BY pct_of_rows DESC;
