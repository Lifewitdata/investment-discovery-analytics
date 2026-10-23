-- Run once in a new database. Raw tables preserve duplicates and invalid business values.
BEGIN;
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS clean;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE TABLE raw.users (
    raw_row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint,
    signup_date date,
    kyc_status text,
    declared_risk_appetite text
);
CREATE TABLE raw.discovery_events (
    raw_row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id text,
    user_id bigint,
    event_timestamp timestamp without time zone,
    search_filter_used text,
    portfolio_viewed text
);
CREATE TABLE raw.transactions (
    raw_row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id text,
    user_id numeric, -- CSV contains 183.0: validate integer-valued IDs before casting.
    portfolio_id text,
    investment_amount numeric, -- no premature rounding of source values
    transaction_status text,
    transaction_timestamp timestamp without time zone
);
COMMIT;
-- Import ONLY source columns, excluding the generated raw_row_id.
-- psql commands (not SQL / not pgAdmin Query Tool commands):
-- \copy raw.users(user_id,signup_date,kyc_status,declared_risk_appetite) FROM 'data/raw/users.csv' WITH (FORMAT csv, HEADER true)
-- \copy raw.discovery_events(event_id,user_id,event_timestamp,search_filter_used,portfolio_viewed) FROM 'data/raw/discovery_events.csv' WITH (FORMAT csv, HEADER true)
-- \copy raw.transactions(transaction_id,user_id,portfolio_id,investment_amount,transaction_status,transaction_timestamp) FROM 'data/raw/transactions.csv' WITH (FORMAT csv, HEADER true)
