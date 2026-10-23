"""Independent CSV reconciliation of the supplied fixture; Python standard library only."""
import csv
from pathlib import Path
from collections import defaultdict, Counter
from decimal import Decimal
root = Path(__file__).resolve().parents[1]
def read(name):
    with (root/'data/raw'/name).open(newline='') as f:
        return list(csv.DictReader(f))
users = {int(r['user_id']): r for r in read('users.csv')}
events = read('discovery_events.csv')
tx = read('transactions.csv')
groups = defaultdict(list)
for r in tx: groups[r['transaction_id']].append(r)
clean=[]; issues=Counter(); rejected=0
for group in groups.values():
    conflict = len({tuple(r.values()) for r in group}) > 1
    for i,r in enumerate(group):
        reasons=[]
        if conflict: reasons.append('CONFLICTING_DUPLICATE_ID')
        if i: reasons.append('DUPLICATE_EXTRA_ROW')
        uid=int(Decimal(r['user_id'])) if r['user_id'] else None
        if uid is None: reasons.append('NULL_USER_ID')
        elif uid not in users: reasons.append('UNKNOWN_USER_ID')
        if Decimal(r['investment_amount'])<0: reasons.append('NEGATIVE_AMOUNT')
        if uid in users and r['transaction_timestamp'][:10] < users[uid]['signup_date']:
            reasons.append('BEFORE_SIGNUP')
        if reasons: rejected+=1; issues.update(reasons)
        else: clean.append(r)
first={}
for e in events:
    key=(int(e['user_id']), 'No filter' if e['search_filter_used']=='None' else e['search_filter_used'])
    first[key]=min(first.get(key,e['event_timestamp']),e['event_timestamp'])
success=defaultdict(list)
for r in clean:
    if r['transaction_status']=='Success': success[int(Decimal(r['user_id']))].append(r['transaction_timestamp'])
summary=defaultdict(lambda:[0,0])
for (uid,f),ts in first.items():
    summary[f][0]+=1
    summary[f][1]+=int(any(t>ts for t in success[uid]))
assert len(tx)==len(clean)+rejected
print('Raw:',len(tx),'Clean:',len(clean),'Rejected:',rejected)
print('Overlapping issue counts:',dict(issues))
with (root/'data/processed/expected_filter_conversion.csv').open('w',newline='') as f:
    w=csv.writer(f);w.writerow(['search_filter_used','searching_users','converted_users','conversion_rate_pct'])
    for k,(n,c) in sorted(summary.items()):
        row=[k,n,c,round(100*c/n,2)];w.writerow(row);print(row)
print('Clean successful transactions:',sum(r['transaction_status']=='Success' for r in clean))
