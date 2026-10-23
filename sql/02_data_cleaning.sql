-- Full snapshot refresh. Re-running replaces derived data, never raw source rows.
-- Run in a single session; do not load raw tables concurrently.
BEGIN;
LOCK TABLE raw.users, raw.discovery_events, raw.transactions IN SHARE MODE;
-- These source dimensions were profiled as valid. Fail rather than silently multiply joins.
DO $$
BEGIN
 IF EXISTS (SELECT 1 FROM raw.users WHERE user_id IS NULL OR signup_date IS NULL)
 OR EXISTS (SELECT 1 FROM raw.users GROUP BY user_id HAVING count(*) > 1)
 THEN RAISE EXCEPTION 'Invalid/duplicate user keys or missing signup dates'; END IF;
 IF EXISTS (SELECT 1 FROM raw.discovery_events e LEFT JOIN raw.users u USING(user_id)
            WHERE e.event_id IS NULL OR u.user_id IS NULL OR e.event_timestamp IS NULL
               OR e.event_timestamp < u.signup_date::timestamp)
 OR EXISTS (SELECT 1 FROM raw.discovery_events GROUP BY event_id HAVING count(*) > 1)
 THEN RAISE EXCEPTION 'Invalid/duplicate event keys, orphan users or invalid chronology'; END IF;
END $$;
CREATE OR REPLACE VIEW clean.users AS
SELECT user_id, signup_date, btrim(kyc_status) AS kyc_status,
       btrim(declared_risk_appetite) AS declared_risk_appetite FROM raw.users;
CREATE OR REPLACE VIEW clean.discovery_events AS
SELECT event_id, user_id, event_timestamp,
 CASE WHEN lower(btrim(search_filter_used)) = 'none' THEN 'No filter'
      ELSE coalesce(nullif(btrim(search_filter_used), ''), 'Unknown') END AS search_filter_used,
 portfolio_viewed FROM raw.discovery_events;

-- Compare the complete source payload. If one ID has different payloads, reject ALL versions:
-- the source has no update timestamp that can establish which version is authoritative.
CREATE TEMP TABLE classified_transactions ON COMMIT DROP AS
WITH variants AS (
 SELECT transaction_id,
 count(DISTINCT jsonb_build_array(user_id, portfolio_id, investment_amount,
                                 transaction_status, transaction_timestamp)) AS payload_count
 FROM raw.transactions GROUP BY transaction_id
), ranked AS (
 SELECT t.*, row_number() OVER (PARTITION BY transaction_id ORDER BY raw_row_id) AS duplicate_rank,
        v.payload_count
 FROM raw.transactions t JOIN variants v ON t.transaction_id IS NOT DISTINCT FROM v.transaction_id
)
SELECT r.*, array_remove(ARRAY[
 CASE WHEN nullif(btrim(r.transaction_id),'') IS NULL THEN 'MISSING_TRANSACTION_ID' END,
 CASE WHEN r.payload_count > 1 THEN 'CONFLICTING_DUPLICATE_ID' END,
 CASE WHEN r.duplicate_rank > 1 THEN 'DUPLICATE_EXTRA_ROW' END,
 CASE WHEN r.user_id IS NULL THEN 'NULL_USER_ID' END,
 CASE WHEN r.user_id IS NOT NULL AND (r.user_id <> trunc(r.user_id)
       OR r.user_id < 1 OR r.user_id > 9223372036854775807::numeric) THEN 'INVALID_USER_ID' END,
 CASE WHEN r.user_id IS NOT NULL AND u.user_id IS NULL THEN 'UNKNOWN_USER_ID' END,
 CASE WHEN r.investment_amount IS NULL THEN 'MISSING_AMOUNT'
      WHEN r.investment_amount < 0 THEN 'NEGATIVE_AMOUNT'
      WHEN r.investment_amount = 0 THEN 'ZERO_AMOUNT'
      WHEN r.investment_amount::text IN ('NaN','Infinity','-Infinity') THEN 'NONFINITE_AMOUNT' END,
 CASE WHEN nullif(btrim(r.portfolio_id),'') IS NULL THEN 'MISSING_PORTFOLIO_ID' END,
 CASE WHEN r.transaction_status IS NULL OR lower(btrim(r.transaction_status))
      NOT IN ('success','failed','pending') THEN 'INVALID_STATUS' END,
 CASE WHEN r.transaction_timestamp IS NULL THEN 'MISSING_TIMESTAMP' END,
 CASE WHEN r.transaction_timestamp < u.signup_date::timestamp THEN 'BEFORE_SIGNUP' END
]::text[], NULL) AS error_reasons
FROM ranked r LEFT JOIN clean.users u ON r.user_id = u.user_id::numeric;

CREATE TABLE IF NOT EXISTS audit.transaction_errors (
 raw_row_id bigint PRIMARY KEY, transaction_id text, user_id numeric, portfolio_id text,
 investment_amount numeric, transaction_status text, transaction_timestamp timestamp,
 duplicate_rank bigint, payload_count bigint, error_reasons text[] NOT NULL,
 detected_at timestamptz NOT NULL DEFAULT current_timestamp
);
CREATE TABLE IF NOT EXISTS clean.transactions (
 transaction_id text PRIMARY KEY, raw_row_id bigint UNIQUE NOT NULL,
 user_id bigint NOT NULL, portfolio_id text NOT NULL,
 investment_amount numeric NOT NULL CHECK (investment_amount > 0),
 transaction_status text NOT NULL CHECK (transaction_status IN ('Success','Failed','Pending')),
 transaction_timestamp timestamp NOT NULL
);
TRUNCATE audit.transaction_errors, clean.transactions;
INSERT INTO audit.transaction_errors
 (raw_row_id,transaction_id,user_id,portfolio_id,investment_amount,transaction_status,
 transaction_timestamp,duplicate_rank,payload_count,error_reasons)
SELECT raw_row_id,transaction_id,user_id,portfolio_id,investment_amount,transaction_status,
 transaction_timestamp,duplicate_rank,payload_count,error_reasons
FROM classified_transactions WHERE cardinality(error_reasons) > 0;
INSERT INTO clean.transactions
SELECT transaction_id,raw_row_id,user_id::bigint,portfolio_id,investment_amount,
 initcap(lower(btrim(transaction_status))),transaction_timestamp
FROM classified_transactions WHERE cardinality(error_reasons) = 0;
CREATE INDEX IF NOT EXISTS ix_success_user_time ON clean.transactions(user_id, transaction_timestamp)
 WHERE transaction_status = 'Success';
CREATE INDEX IF NOT EXISTS ix_events_user_filter_time ON raw.discovery_events(user_id,search_filter_used,event_timestamp);
CREATE OR REPLACE VIEW audit.null_user_errors AS
 SELECT * FROM audit.transaction_errors WHERE 'NULL_USER_ID' = ANY(error_reasons);
CREATE OR REPLACE VIEW audit.quality_summary AS
 SELECT reason, count(*) AS affected_raw_rows
 FROM audit.transaction_errors CROSS JOIN LATERAL unnest(error_reasons) AS x(reason)
 GROUP BY reason;
-- One raw row must be in exactly one output. Issue counts themselves can overlap.
DO $$ BEGIN
 IF (SELECT count(*) FROM raw.transactions) <>
    (SELECT count(*) FROM clean.transactions) + (SELECT count(*) FROM audit.transaction_errors)
 THEN RAISE EXCEPTION 'Raw/clean/error reconciliation failed'; END IF;
END $$;
COMMIT;
