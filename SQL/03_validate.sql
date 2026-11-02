-- =====================================================================
-- 03_validate.sql  |  Prove the cleaned table is correct
-- Each check compares an expected value with an actual one; violation counts must be 0.
-- The runner stops with an error if any check fails.
-- =====================================================================

DROP TABLE IF EXISTS validation_checks;
CREATE TABLE validation_checks (check_name TEXT, expected INTEGER, actual INTEGER, status TEXT);

INSERT INTO validation_checks (check_name, expected, actual) VALUES
 ('rows_preserved (raw = clean)',
    (SELECT COUNT(*) FROM raw_bookings), (SELECT COUNT(*) FROM bookings_clean)),
 ('row_id_is_unique',
    (SELECT COUNT(*) FROM bookings_clean), (SELECT COUNT(DISTINCT row_id) FROM bookings_clean)),
 ('every_raw_row_present_in_clean',
    0, (SELECT COUNT(*) FROM raw_bookings r WHERE NOT EXISTS (SELECT 1 FROM bookings_clean c WHERE c.row_id = r.row_id))),
 ('no_null_in_key_columns',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE hotel IS NULL OR is_canceled IS NULL OR arrival_date IS NULL
                                                OR lead_time IS NULL OR adr IS NULL OR reservation_status IS NULL)),
 ('hotel_in_allowed_set',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE hotel NOT IN ('City Hotel','Resort Hotel'))),
 ('is_canceled_is_0_or_1',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE is_canceled NOT IN (0,1))),
 ('status_agrees_with_is_canceled',
    0, (SELECT COUNT(*) FROM bookings_clean
        WHERE (is_canceled = 0 AND reservation_status <> 'Check-Out')
           OR (is_canceled = 1 AND reservation_status NOT IN ('Canceled','No-Show')))),
 ('arrival_dates_are_valid_iso',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE arrival_date IS NULL OR DATE(arrival_date) <> arrival_date)),
 ('arrival_dates_within_expected_window (Jul 2015 - Aug 2017)',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE arrival_date NOT BETWEEN '2015-07-01' AND '2017-08-31')),
 ('booking_date_not_after_arrival',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE booking_date > arrival_date)),
 ('cancellation_date_not_after_arrival',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE reservation_status = 'Canceled' AND reservation_status_date > arrival_date)),
 ('total_nights = weekend + week nights',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE total_nights <> weekend_nights + week_nights)),
 ('total_guests = adults + children + babies',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE total_guests <> adults + children + babies)),
 ('country_is_iso3_or_unknown',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE country <> 'Unknown' AND LENGTH(country) <> 3)),
 ('missing_countries_match_raw',
    (SELECT COUNT(*) FROM raw_bookings WHERE country = 'NULL'), (SELECT COUNT(*) FROM bookings_clean WHERE country = 'Unknown')),
 ('meal_plan_in_allowed_set',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE meal_plan NOT IN ('Bed & Breakfast','Half board','Full board','No meal package'))),
 ('market_segment_has_no_undefined',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE market_segment = 'Undefined' OR distribution_channel = 'Undefined')),
 ('deposit_type_in_allowed_set',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE deposit_type NOT IN ('No Deposit','Non Refund','Refundable'))),
 ('customer_type_in_allowed_set',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE customer_type NOT IN ('Transient','Transient-Party','Contract','Group'))),
 ('missing_agents_match_raw',
    (SELECT COUNT(*) FROM raw_bookings WHERE agent = 'NULL'), (SELECT COUNT(*) FROM bookings_clean WHERE has_agent = 0)),
 ('imputed_children_match_raw',
    (SELECT COUNT(*) FROM raw_bookings WHERE children = 'NA'), (SELECT SUM(children_imputed) FROM bookings_clean)),
 ('zero_guest_flag_matches_independent_count',
    (SELECT COUNT(*) FROM raw_bookings WHERE CAST(adults AS INT) + COALESCE(CAST(NULLIF(children,'NA') AS INT),0) + CAST(babies AS INT) = 0),
    (SELECT SUM(flag_zero_guests) FROM bookings_clean)),
 ('valid_stays_have_positive_rate_guests_nights',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE is_valid_stay = 1 AND (adr <= 0 OR total_guests = 0 OR total_nights = 0))),
 ('booking_value = adr x nights for valid stays',
    0, (SELECT COUNT(*) FROM bookings_clean WHERE is_valid_stay = 1 AND ABS(booking_value - adr * total_nights) > 0.01)),
 ('duplicate_flags_match_independent_count',
    (SELECT COUNT(*) FROM raw_bookings) - (SELECT COUNT(*) FROM (SELECT DISTINCT hotel, is_canceled, lead_time, arrival_date_year, arrival_date_month,
        arrival_date_week_number, arrival_date_day_of_month, stays_in_weekend_nights, stays_in_week_nights, adults, children, babies, meal, country,
        market_segment, distribution_channel, is_repeated_guest, previous_cancellations, previous_bookings_not_canceled, reserved_room_type,
        assigned_room_type, booking_changes, deposit_type, agent, company, days_in_waiting_list, customer_type, adr, required_car_parking_spaces,
        total_of_special_requests, reservation_status, reservation_status_date FROM raw_bookings)),
    (SELECT SUM(is_duplicate) FROM bookings_clean)),
 ('unique_view_row_count',
    (SELECT COUNT(*) - SUM(is_duplicate) FROM bookings_clean), (SELECT COUNT(*) FROM bookings_unique));

UPDATE validation_checks SET status = CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END;

-- name: validation_results
SELECT check_name, expected, actual, status FROM validation_checks;

-- name: cleaning_summary
SELECT 'columns cast from text to integer / real / dates' AS step, 32 AS rows_affected
UNION ALL SELECT 'missing agent tokens (NULL = no agent)',       (SELECT COUNT(*) FROM bookings_clean WHERE has_agent = 0)
UNION ALL SELECT 'missing company tokens (NULL = no company)',   (SELECT COUNT(*) FROM bookings_clean WHERE has_company = 0)
UNION ALL SELECT 'missing countries set to Unknown',             (SELECT SUM(country_missing) FROM bookings_clean)
UNION ALL SELECT 'missing children set to 0 (flagged)',          (SELECT SUM(children_imputed) FROM bookings_clean)
UNION ALL SELECT 'country code CN standardised to CHN',          (SELECT COUNT(*) FROM raw_bookings WHERE country = 'CN')
UNION ALL SELECT 'meal Undefined merged into No meal package',   (SELECT COUNT(*) FROM raw_bookings WHERE meal = 'Undefined')
UNION ALL SELECT 'Undefined market segment / channel relabelled',(SELECT COUNT(*) FROM raw_bookings WHERE market_segment = 'Undefined' OR distribution_channel = 'Undefined')
UNION ALL SELECT 'flag: zero guests',                            (SELECT SUM(flag_zero_guests) FROM bookings_clean)
UNION ALL SELECT 'flag: zero nights',                            (SELECT SUM(flag_zero_nights) FROM bookings_clean)
UNION ALL SELECT 'flag: adr zero or negative',                   (SELECT SUM(flag_adr_nonpositive) FROM bookings_clean)
UNION ALL SELECT 'flag: adr above 1,000',                        (SELECT SUM(flag_adr_outlier) FROM bookings_clean)
UNION ALL SELECT 'flag: extreme party size',                     (SELECT SUM(flag_extreme_party) FROM bookings_clean)
UNION ALL SELECT 'flag: repeat-guest field contradicts history', (SELECT SUM(flag_repeat_guest_inconsistent) FROM bookings_clean)
UNION ALL SELECT 'flag: check-out date does not match stay',     (SELECT SUM(flag_checkout_date_mismatch) FROM bookings_clean)
UNION ALL SELECT 'rows that are not valid stays (any flag)',     (SELECT COUNT(*) - SUM(is_valid_stay) FROM bookings_clean)
UNION ALL SELECT 'exact duplicate rows flagged',                 (SELECT SUM(is_duplicate) FROM bookings_clean);
