"""Independent reconciliation for the same-portfolio attribution views.

Companion to validate_data.py, which covers the loose conversion table. This
reproduces the identical clean-transaction rules, then computes what
analytics.filter_conversion_attributed and analytics.kyc_control_exceptions
should return, so those views can be checked without a running server.

    python scripts/validate_attribution.py
"""
from collections import defaultdict
from decimal import Decimal
from pathlib import Path
import csv

root = Path(__file__).resolve().parents[1]


def read(name):
    with (root / "data/raw" / name).open(newline="") as f:
        return list(csv.DictReader(f))


users = {int(r["user_id"]): r for r in read("users.csv")}
events = read("discovery_events.csv")
tx = read("transactions.csv")

# --- clean transactions: same rules as validate_data.py / 02_data_cleaning.sql
groups = defaultdict(list)
for r in tx:
    groups[r["transaction_id"]].append(r)

clean = []
for group in groups.values():
    conflict = len({tuple(r.values()) for r in group}) > 1
    for i, r in enumerate(group):
        reject = conflict or i > 0
        uid = int(Decimal(r["user_id"])) if r["user_id"] else None
        if uid is None or uid not in users:
            reject = True
        elif r["transaction_timestamp"][:10] < users[uid]["signup_date"]:
            reject = True
        if Decimal(r["investment_amount"]) <= 0:
            reject = True
        if r["transaction_status"] not in ("Success", "Failed", "Pending"):
            reject = True
        if not reject:
            clean.append(r)

succ = [r for r in clean if r["transaction_status"] == "Success"]
print(f"Clean rows: {len(clean)}  Clean Success: {len(succ)}")
assert len(clean) == 3651 and len(succ) == 2925, "clean set drifted from validate_data.py"


def norm(v):
    return "No filter" if v is None or v.strip().lower() in ("", "none") else v.strip()


# --- same-portfolio attribution --------------------------------------------
# A purchase is attributed to a filter only when the filter's result surfaced
# that exact portfolio and the purchase happened strictly after that event.
by_user = defaultdict(list)
for t in succ:
    by_user[int(Decimal(t["user_id"]))].append(
        (t["portfolio_id"], t["transaction_timestamp"], t["transaction_id"],
         Decimal(t["investment_amount"])))

users_per_filter = defaultdict(set)
pairs_per_filter = defaultdict(set)
searchers = defaultdict(set)

for e in events:
    f = norm(e["search_filter_used"])
    uid = int(Decimal(e["user_id"]))
    searchers[f].add(uid)
    ets, pv = e["event_timestamp"], e["portfolio_viewed"]
    for p, ts, tid, amt in by_user.get(uid, ()):
        if p == pv and ts > ets:
            users_per_filter[f].add(uid)
            pairs_per_filter[f].add((tid, amt))

# The DISTINCT set above is the whole point: one purchase reached by five
# identical searches still counts as one attributed transaction.
print("\nsearch_filter_used,searching_users,attributed_users,attributed_rate_pct,"
      "attributed_transactions,attributed_amount")
rows = []
for f in sorted(searchers):
    n, a = len(searchers[f]), len(users_per_filter[f])
    txns = len(pairs_per_filter[f])
    amt = sum(v for _, v in pairs_per_filter[f])
    pct = round(100 * a / n, 2)
    rows.append([f, n, a, pct, txns, f"{amt:.2f}"])
    print(",".join(str(x) for x in rows[-1]))

out = root / "data/processed" / "expected_filter_attribution.csv"
with out.open("w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["search_filter_used", "searching_users", "attributed_users",
                "attributed_rate_pct", "attributed_transactions", "attributed_amount"])
    w.writerows(rows)
print(f"\nWrote {out.relative_to(root)}")

# --- KYC exception listing --------------------------------------------------
kyc = defaultdict(lambda: [set(), 0, Decimal(0)])
for t in succ:
    uid = int(Decimal(t["user_id"]))
    st = users[uid]["kyc_status"]
    kyc[st][0].add(uid)
    kyc[st][1] += 1
    kyc[st][2] += Decimal(t["investment_amount"])

print("\nkyc_status,accounts,transactions,invested_amount")
for st in ("Failed", "Pending", "Verified"):
    acc, n, amt = kyc[st]
    print(f"{st},{len(acc)},{n},{amt:.2f}")
print("\nAccounts are not mutually comparable to transactions: one account invests repeatedly.")
print("kyc_status is the current value; no point-in-time history exists in the source,")
print("so Failed/Pending rows are a review queue, not proof of a control breach.")
