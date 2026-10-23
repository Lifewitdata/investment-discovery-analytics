# Investment Discovery & Data Reliability Pipeline

PostgreSQL SQL deliverables for the three supplied synthetic CSV datasets, with an Excel Power Query dashboard guide. This package includes the actual input CSVs; it does not claim to contain their original generation script or a completed connected Excel workbook.

## Run order

Create a local database named `investment_discovery`. From this project directory:

```sh
psql -U postgres -d investment_discovery -v ON_ERROR_STOP=1 -f sql/01_table_schemas.sql
psql -U postgres -d investment_discovery -v ON_ERROR_STOP=1 -f scripts/load_data.psql
psql -U postgres -d investment_discovery -v ON_ERROR_STOP=1 -f sql/02_data_cleaning.sql
psql -U postgres -d investment_discovery -v ON_ERROR_STOP=1 -f sql/03_aggregations.sql
```

Use your own database username. The first script is deliberately create-once: it fails on existing raw tables rather than wiping them. Import once. To refresh the same fixture, explicitly truncate all three raw tables with RESTART IDENTITY before reimporting; then run cleaning and aggregations. Do not append repeat imports accidentally. Cleaning refreshes the current audit snapshot, so retain exports if you need historical audit runs.

The load file uses psql client-side `\copy`; pgAdmin users should instead use Import/Export Data and select only the original CSV columns, excluding `raw_row_id`. Ordinary SQL `COPY` reads paths on the database server, whereas `\copy` reads paths on your client. CSV headers are skipped, and blank unquoted fields import as SQL NULL.

## Data contracts and important choices

- Raw row identity is separate from transaction identity: source transaction IDs cannot be unique because intentional duplicates must load successfully.
- Transaction user IDs are numeric in raw because the file includes values such as `183.0`; clean IDs are bigint after validating membership and integral values.
- Raw types accommodate the supplied files and their stated dirty business values. Malformed dates or nonnumeric text will fail the import; this is not a universal untyped ingestion framework.
- Exact duplicate payloads retain the first source row. Different payloads sharing one transaction ID are all quarantined: there is no update timestamp to select a reliable winner. File order breaks ties only between identical payloads.
- Error records preserve source fields, row identity, duplicate rank and all applicable reasons. NULL-user records are available through `audit.null_user_errors`. Error counts overlap; never sum them to estimate rejected rows.
- Negative amounts are quarantined, never converted with ABS(). The source contains no refund/reversal indicator, so a negative amount cannot safely be treated as an investment. Confirm upstream semantics before correcting it.
- Transactions before signup are also quarantined. Events already pass this check. Signup is date-only, so transactions on the signup date are accepted; more precise same-day sequencing is unavailable.
- Timestamps carry no timezone. The model assumes both timestamp columns use one consistent timezone and preserves their values. Do not label them UTC without confirmation.
- Failed and Pending transactions remain in clean data when otherwise valid, but only Success qualifies for conversion. KYC status is a segmentation field, not a conversion eligibility restriction: the source does not provide historical KYC status at transaction time.
- Dimension checks stop the run on missing/duplicate user IDs, duplicate event IDs, missing event times, orphan events, or events before signup. These tables passed the supplied fixture checks.

## Profile and reconciliation

Input: 10,000 users; 25,000 discovery events; 8,200 transaction rows representing 8,000 transaction IDs. No conflicting transaction-ID payloads were found.

| Raw-row issue | Count |
|---|---:|
| Additional duplicate rows | 200 |
| NULL user IDs | 410 |
| Negative investment amounts | 405 |
| Transaction before signup | 3,862 |

These overlap. Removing duplicates, NULL users and negative amounts alone yields 7,224 rows; 3,573 of those still predate signup. The stricter pipeline therefore yields **3,651 clean rows + 4,549 rejected rows = 8,200 raw rows**. Of the clean rows, 2,925 have Success status. This large chronology defect limits any interpretation as realistic investment behaviour.

## Conversion definition

For each filter:

`100 × distinct users with a valid Success transaction after first use of the filter / distinct users who used the filter`

One row per user/filter is constructed before checking transactions. An EXISTS check prevents a user with multiple searches and multiple transactions from generating a many-to-many join explosion. Users without transactions stay in the denominator.

Any portfolio qualifies; no fixed conversion window is imposed. A transaction before first search does not qualify. Literal `None` is reported as `No filter`, a useful baseline; missing filter values would be `Unknown`. Exclude `No filter` in Excel if only explicit filters are desired.

A user may qualify for several filters. These are overlapping association groups, not mutually exclusive attribution channels. Do not add filter user counts to report total unique people, sum conversion percentages, or claim that a filter caused investment. More recent searchers have less follow-up time. For a comparable 30-day cohort metric, add an explicit reliable data-cutoff parameter, limit searches to at least 30 days before it, and qualify transactions within that user's 30-day window. The maximum observed timestamp is not proof of complete data coverage.

| Filter | Searching users | Converted users | Conversion % |
|---|---:|---:|---:|
| Dividend Yield | 3,385 | 442 | 13.06 |
| ESG | 3,300 | 449 | 13.61 |
| High Return | 3,435 | 490 | 14.26 |
| Low Volatility | 3,423 | 484 | 14.14 |
| No filter | 3,438 | 484 | 14.08 |
| Tech Sector | 3,460 | 503 | 14.54 |

These expected results were independently calculated from the supplied CSVs with Python (`python scripts/validate_data.py`), not obtained from a running PostgreSQL server. See Verification below for exactly what has and has not been executed.

## Second definition: same-portfolio attribution

`analytics.filter_conversion` asks whether a user who searched with a filter later invested **anything**. `analytics.filter_conversion_attributed` asks the narrower question: did they buy **the portfolio that search surfaced**, strictly after that search?

| Filter | Searching users | Converted (any portfolio) | Rate % | Attributed users | Attributed rate % | Attributed amount |
|---|---:|---:|---:|---:|---:|---:|
| Dividend Yield | 3,385 | 442 | 13.06 | 34 | 1.00 | 888,175.08 |
| Low Volatility | 3,423 | 484 | 14.14 | 34 | 0.99 | 807,975.29 |
| No filter | 3,438 | 484 | 14.08 | 34 | 0.99 | 842,504.76 |
| Tech Sector | 3,460 | 503 | 14.54 | 30 | 0.87 | 755,101.67 |
| High Return | 3,435 | 490 | 14.26 | 27 | 0.79 | 666,377.41 |
| ESG | 3,300 | 449 | 13.61 | 23 | 0.70 | 438,952.15 |

The two rates differ by roughly 14x, and that gap is the finding, not a defect: in this feed, which filter a user searched has almost no bearing on what they bought. Reported per filter, the attributed rate spans 0.70%-1.00% against a 13.06%-14.54% loose rate — a range narrow enough that no filter is distinguishable from another on either measure.

This is what an independently generated synthetic fixture looks like: `discovery_events` and `transactions` share only the user key, so no funnel signal exists to recover. Treat the pipeline as the deliverable and these numbers as its test output, not as evidence about investor behaviour. A real feed with correlated browsing and purchasing would separate the columns.

`unattributed_converted_users` is the difference between the two and is included so the gap is visible in the pivot rather than implicit.

`attributed_amount` overlaps across filters for the same reason `searching_users` does. It does not sum to total AUM and must not be totalled in a PivotTable grand total.

## KYC exception listing

`analytics.kyc_control_exceptions` lists accounts recorded as Failed or Pending KYC that hold successful investments. On this fixture: 260 Failed-KYC accounts across 313 transactions worth 7,658,860.95, and 468 Pending-KYC accounts worth 13,846,812.31.

Read this as a review queue, not a breach. `kyc_status` is the value recorded now and the source carries no history of KYC state at transaction time, so an account that passed KYC, invested, then failed verification is indistinguishable here from one that never passed. The same absence is why KYC remains a segmentation field in the conversion views rather than an eligibility filter.

## Verification

No PostgreSQL server was available for this work, so the deliverable was checked three ways instead:

- **Syntax:** every statement in all three scripts parsed with `sqlglot` under `dialect=postgres`. `LOCK TABLE`, `CREATE TEMP TABLE ... ON COMMIT DROP` and the `DO $$ ... $$` blocks fall back to opaque command nodes and are **not** grammar-checked; they are the remaining risk and need a real server.
- **Logic:** the `clean.*` layer was rebuilt in DuckDB from the supplied CSVs using the same rules `02_data_cleaning.sql` encodes, reproducing 3,651 clean rows and 2,925 successes. The loose view then returned all six golden rows exactly, and both new views matched an independent Python oracle.
- **Oracle:** `scripts/validate_data.py` is standard-library Python and regenerates `data/processed/expected_filter_conversion.csv` from the raw CSVs, so the headline table is checkable without any database. `scripts/validate_attribution.py` does the same for the two new views and writes `data/processed/expected_filter_attribution.csv`.

Run the scripts on PostgreSQL before quoting figures externally; the timing guards and partial indexes in particular have only been reviewed, not executed.

## Connect Excel: three steps

- **Connect:** In supported Excel for Windows, select Data > Get Data > From Database > From PostgreSQL Database. Enter server `localhost:5432`, database `investment_discovery`, and your database credentials. Connector availability depends on your Excel edition. If prompted for a provider, follow Microsoft's connector prerequisites and match your Excel architecture; if the native connector is unavailable, use a configured PostgreSQL ODBC connection through From ODBC.
- **Load:** Select `analytics.user_filter_conversion` in Navigator, choose Transform Data, verify converted_user is numeric and first_search_at is Date/Time, then Close & Load To a table or Data Model. Optionally load `analytics.filter_conversion` and `analytics.filter_conversion_attributed` for ready-made summaries, and `audit.quality_summary` for quality monitoring. A Power Query source can be `PostgreSQL.Database("localhost:5432", "investment_discovery", [Query="SELECT * FROM analytics.user_filter_conversion"])`.
- **Build and refresh:** Create a PivotTable with search_filter_used in Rows; Count of user_id, Sum of converted_user and Average of converted_user in Values. Format the average as Percentage: the flag is 0/1 and each user/filter occurs once. Add KYC and risk-appetite slicers and a conversion PivotChart. Disable grand totals across filters because they describe user/filter pairs rather than unique people. Refresh Power Query after the SQL cleaning pipeline runs, then refresh the PivotTable. If loading the summary view instead, divide conversion_rate_pct by 100 before applying Excel Percentage formatting (14.54 would otherwise display as 1454%).

## References

- PostgreSQL COPY: https://www.postgresql.org/docs/current/sql-copy.html
- Microsoft PostgreSQL connector: https://learn.microsoft.com/en-us/power-query/connectors/postgresql
- Excel connector availability: https://support.microsoft.com/en-us/office/power-query-data-sources-in-excel-versions-e9332067-8e49-46fc-97ff-f2e1bfa0cb16
