BEGIN;
-- Grain: one user per filter. Repeated searches cannot inflate the denominator.
-- Definition: at least one successful, positive, valid transaction STRICTLY AFTER
-- the first observed use of that filter, within the supplied dataset.
-- Any portfolio qualifies: this is user conversion, not same-portfolio attribution.
CREATE OR REPLACE VIEW analytics.user_filter_conversion AS
WITH first_search AS (
 SELECT user_id, search_filter_used, min(event_timestamp) AS first_search_at
 FROM clean.discovery_events GROUP BY user_id, search_filter_used
)
SELECT f.user_id, f.search_filter_used, f.first_search_at,
       u.kyc_status, u.declared_risk_appetite,
       CASE WHEN EXISTS (
         SELECT 1 FROM clean.transactions t
         WHERE t.user_id = f.user_id AND t.transaction_status = 'Success'
           AND t.transaction_timestamp > f.first_search_at
       ) THEN 1 ELSE 0 END AS converted_user
FROM first_search f JOIN clean.users u USING(user_id);
CREATE OR REPLACE VIEW analytics.filter_conversion AS
SELECT search_filter_used, count(*) AS searching_users,
       sum(converted_user) AS converted_users,
       round(100.0 * sum(converted_user) / nullif(count(*),0),2) AS conversion_rate_pct
FROM analytics.user_filter_conversion GROUP BY search_filter_used;
COMMENT ON VIEW analytics.filter_conversion IS
 'Observed post-search user conversion; multi-filter users count in each filter; rates are not causal or additive.';

-- -----------------------------------------------------------------------------
-- Same-portfolio attribution. analytics.filter_conversion answers "did a user
-- who searched with this filter later invest anything?". This answers the
-- narrower question "did they buy the portfolio this search surfaced?".
--
-- Both are reported because they differ by roughly 14x, and a single column
-- called "conversion rate" hides which one is being claimed. Use this one for
-- any statement about a filter's quality; the loose one only says the searcher
-- was active.
--
-- The DISTINCT in pairs matters: one purchase can follow several identical
-- searches by the same user, and summing across that fan-out would invent AUM.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.filter_conversion_attributed AS
WITH pairs AS (
 SELECT DISTINCT e.search_filter_used, t.user_id, t.transaction_id, t.investment_amount
 FROM clean.discovery_events e
 JOIN clean.transactions t
   ON t.user_id = e.user_id
  AND t.portfolio_id = e.portfolio_viewed
  AND t.transaction_status = 'Success'
  AND t.transaction_timestamp > e.event_timestamp
),
agg AS (
 SELECT search_filter_used,
        count(DISTINCT user_id) AS attributed_users,
        count(*) AS attributed_transactions,
        sum(investment_amount) AS attributed_amount
 FROM pairs GROUP BY search_filter_used
)
SELECT c.search_filter_used, c.searching_users,
       c.converted_users, c.conversion_rate_pct,
       coalesce(a.attributed_users, 0) AS attributed_users,
       round(100.0 * coalesce(a.attributed_users, 0)
             / nullif(c.searching_users, 0), 2) AS attributed_rate_pct,
       coalesce(a.attributed_transactions, 0) AS attributed_transactions,
       coalesce(a.attributed_amount, 0) AS attributed_amount,
       c.converted_users - coalesce(a.attributed_users, 0) AS unattributed_converted_users
FROM analytics.filter_conversion c
LEFT JOIN agg a USING (search_filter_used);
COMMENT ON VIEW analytics.filter_conversion_attributed IS
 'attributed_* counts only a Success transaction in the exact portfolio a filter surfaced, strictly after that search. Overlapping across filters, so attributed_amount does not sum to total AUM.';

-- -----------------------------------------------------------------------------
-- Exception listing for review, not a proven violation.
-- kyc_status is the value recorded now; the source has no history of KYC state
-- at transaction time. A user who passed KYC in March and failed in June looks
-- identical here to one who never passed. So this ranks accounts worth a human
-- checking, and is not a compliance finding on its own.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.kyc_control_exceptions AS
SELECT u.user_id, u.kyc_status, u.signup_date,
       count(*) AS successful_transactions,
       sum(t.investment_amount) AS invested_amount,
       min(t.transaction_timestamp) AS first_success_at,
       max(t.transaction_timestamp) AS latest_success_at
FROM clean.users u
JOIN clean.transactions t ON t.user_id = u.user_id AND t.transaction_status = 'Success'
WHERE u.kyc_status IN ('Failed', 'Pending')
GROUP BY u.user_id, u.kyc_status, u.signup_date;
COMMENT ON VIEW analytics.kyc_control_exceptions IS
 'Accounts recorded as Failed or Pending KYC that hold successful investments. Cannot be read as a breach: no point-in-time KYC history in the source.';

-- Reconciliation of the attribution view against the loose view. Attribution can
-- never exceed observed conversion; if it does, the pair join is wrong.
DO $$ BEGIN
 IF EXISTS (
   SELECT 1 FROM analytics.filter_conversion_attributed
   WHERE attributed_users > converted_users
 ) THEN RAISE EXCEPTION 'Attributed conversions exceed observed conversions - uncontrolled join fan-out'; END IF;
END $$;
COMMIT;
SELECT * FROM analytics.filter_conversion ORDER BY conversion_rate_pct DESC;
SELECT * FROM analytics.filter_conversion_attributed ORDER BY attributed_rate_pct DESC;
SELECT kyc_status, count(*) AS accounts, sum(successful_transactions) AS txns,
       round(sum(invested_amount), 2) AS invested
FROM analytics.kyc_control_exceptions GROUP BY kyc_status ORDER BY invested DESC;
SELECT * FROM audit.quality_summary ORDER BY affected_raw_rows DESC;
SELECT (SELECT count(*) FROM raw.transactions) AS raw_rows,
       (SELECT count(*) FROM clean.transactions) AS clean_rows,
       (SELECT count(*) FROM audit.transaction_errors) AS rejected_rows;
