#!/usr/bin/env python3
"""Classify MT5 historical audit events. Read-only; never sends orders."""
from __future__ import annotations
import argparse
import csv
import json
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

REQUIRED = {'server_time', 'engine', 'event', 'reason', 'details'}

def category(row: dict[str, str]) -> str:
    engine = (row.get('engine') or '').upper()
    event = (row.get('event') or '').upper()
    reason = (row.get('reason') or '').upper()
    detail = (row.get('details') or '').upper()
    text = ' '.join([reason, detail])
    if event == 'EXECUTED':
        return 'EXECUTION_LOGGED_NOT_BROKER_VERIFIED'
    if event == 'BROKER_HISTORY':
        return 'BROKER_HISTORY'
    if engine not in ('R1', 'R2'):
        return 'OTHER_TELEMETRY'
    if 'WORKER_PENDING_ONLY_PROTOCOL_MISSING' in text or 'V2_5_PENDING_ONLY_WORKER_REQUIRED' in text:
        return 'LEGACY_R2_PENDING_PROTOCOL'
    if 'OFF | SESSION' in text or 'SESSION CLOSED' in text or 'ENTRY_SESSION_CLOSED' in text:
        return 'SESSION_GUARD'
    if 'WORKER MODEL/AGE' in text or 'FEED STALE' in text or 'STALE_OR_MISSING_AGE' in text or reason == 'STALE':
        return 'WORKER_MODEL_OR_STALE_FEED'
    if 'BLOCK | NEWS' in text or reason == 'BLOCK' and 'NEWS' in detail:
        return 'NEWS_GUARD'
    if 'RISK' in text or 'SL CAP' in text:
        return 'RISK_GUARD_OR_RISK_LOG'
    if 'POSITION ACTIVE' in text or 'ACTIVE_R2_POSITION' in text or 'ENGINE POSITION/ORDER' in text:
        return 'EXISTING_EXPOSURE'
    if 'NO ICT CONFIRMATION' in text or 'SETUP NOT ALLOWED' in text or 'NO R2 PENDING' in text or 'WAIT FOR ' in text or 'PENDING_ONLY_WAIT' in text or 'R2_SETUP_NOT_ALLOWED' in text:
        return 'UNQUALIFIED_SIGNAL'
    if event == 'STATE':
        return 'OTHER_STRATEGY_STATE'
    return 'OTHER_EVENT'

def summarize(path: Path) -> dict:
    by_day: dict[str, Counter] = defaultdict(Counter)
    by_day_engine: dict[str, Counter] = defaultdict(Counter)
    engine_event = Counter()
    rows = 0
    date_min: str | None = None
    date_max: str | None = None
    with path.open(encoding='utf-8-sig', newline='') as handle:
        for x in csv.DictReader(handle):
            missing = REQUIRED - set(x)
            if missing: raise ValueError(f'Missing columns: {sorted(missing)}')
            raw_ts = (x['server_time'] or '').strip()
            try:
                dt = datetime.strptime(raw_ts, '%Y.%m.%d %H:%M:%S')
            except ValueError as exc:
                raise ValueError(f'Invalid server_time row {rows + 2}: {raw_ts!r}') from exc
            iso=dt.isoformat(sep=' ')
            date_min = iso if date_min is None else min(date_min, iso)
            date_max = iso if date_max is None else max(date_max, iso)
            day = dt.date().isoformat()
            e = (x.get('engine') or '').upper()
            event = (x.get('event') or '').upper()
            c=category(x)
            by_day[day][c]+=1
            by_day_engine[f'{day}/{e}'][c]+=1
            engine_event[f'{e}/{event}']+=1
            rows+=1
    if not rows: raise ValueError('Empty audit file')
    return {'scope': 'HISTORICAL_AUDIT_COUNTS_NOT_DISTINCT_OPPORTUNITIES',
        'rows':rows, 'first_server_time':date_min, 'last_server_time':date_max,
        'by_day':{k:dict(sorted(v.items())) for k,v in sorted(by_day.items())},
        'by_day_engine':{k:dict(sorted(v.items())) for k,v in sorted(by_day_engine.items())},
        'engine_event_counts':dict(sorted(engine_event.items()))}

def main() -> int:
    p=argparse.ArgumentParser()
    p.add_argument('--audit',required=True,type=Path)
    p.add_argument('--output',required=True,type=Path)
    a=p.parse_args()
    report=summarize(a.audit)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    print(f"CLASSIFIED rows={report['rows']} days={len(report['by_day'])} output={a.output}")
    return 0

if __name__=='__main__':
    raise SystemExit(main())
