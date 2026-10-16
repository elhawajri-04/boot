#!/usr/bin/env python3
"""Score NET results of completed independent R1/R2 logical baskets.
Input CSV is explicitly normalized from broker history, not an audit-events file.
Usage: python XAU_Forward_Basket_Score_v1.py baskets.csv
"""
import csv
import math
import statistics
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

FIELDS={"closed_at","engine","basket_id","setup",
        "net_pnl_usd","initial_risk_usd","balance_at_entry_usd"}

def parse_time(value):
    return datetime.fromisoformat(value.strip().replace("Z","+00:00"))

def report(label,rows):
    if not rows:
        print("\n"+label+": NO COMPLETED TRADES, NO CONCLUSION")
        return
    rows=sorted(rows,key=lambda x:x["closed"])
    pnls=[r["pnl"] for r in rows]
    rs=[r["pnl"]/r["risk"] for r in rows]
    wins=[p for p in pnls if p>0]
    losses=[-p for p in pnls if p<0]
    pf=sum(wins)/sum(losses) if losses else math.inf
    balance=rows[0]["balance"]
    peak=balance
    dd=0.0
    for r in rows:
        balance+=r["pnl"]
        peak=max(peak,balance)
        dd=max(dd,100*(peak-balance)/peak if peak>0 else 100)
    days=(rows[-1]["closed"]-rows[0]["closed"]).total_seconds()/86400
    print("\n"+label)
    print("  closed independent baskets:",len(rows), "  elapsed days:",round(days,1))
    print("  net PnL USD:",round(sum(pnls),2),
          " win rate %:",round(100*len(wins)/len(rows),1))
    print("  Profit Factor NET:",round(pf,3) if math.isfinite(pf) else "infinite/undefined")
    print("  Mean R:",round(statistics.mean(rs),3),
          " median R:",round(statistics.median(rs),3))
    print("  Maximum CLOSED-BALANCE drawdown %:",round(dd,2),
          "(not intratrade equity drawdown)")
    if len(rows)<100 or days<56:
        print("  VERDICT: INSUFFICIENT SAMPLE (target >=100 baskets and >=56 days)")
    elif pf>1.2 and statistics.mean(rs)>0 and dd<=15:
        print("  VERDICT: PRELIMINARY gates met, needs equity-DD, costs, safety and uncertainty review")
    else:
        print("  VERDICT: PRELIMINARY gates not met")
    groups=defaultdict(int)
    for r in rows:groups[r["setup"]]+=1
    print("  setup breakdown:",", ".join(k+"="+str(v) for k,v in sorted(groups.items())))

def main(p):
    with p.open("r",encoding="utf-8-sig",newline="") as file:
        reader=csv.DictReader(file)
        if not reader.fieldnames or not FIELDS.issubset(reader.fieldnames):
            raise ValueError("Missing CSV fields: "+str(sorted(FIELDS-set(reader.fieldnames or []))))
        source=list(reader)
    data=[]
    seen=set()
    for i,r in enumerate(source,2):
        try:
            engine=r["engine"].strip().upper()
            if engine not in ("R1","R2"):raise ValueError("engine must be R1 or R2")
            basket=r["basket_id"].strip()
            if not basket:raise ValueError("empty basket_id")
            key=(engine,basket)
            if key in seen:raise ValueError("basket duplicate, aggregate partial closes first")
            seen.add(key)
            pnl=float(r["net_pnl_usd"])
            risk=float(r["initial_risk_usd"])
            balance=float(r["balance_at_entry_usd"])
            if not all(math.isfinite(x) for x in (pnl,risk,balance)):
                raise ValueError("invalid nonfinite value")
            if risk<=0 or balance<=0:raise ValueError("risk and balance must be positive")
            if 100*risk/balance>5.01:
                print("WARNING line",i,": individual engine SL risk above 5% nominal ceiling")
            data.append({"engine":engine,"basket":basket,"closed":parse_time(r["closed_at"]),
                         "pnl":pnl,"risk":risk,"balance":balance,
                         "setup":r["setup"].strip() or "UNKNOWN"})
        except Exception as exc:
            raise ValueError("Bad CSV line "+str(i)+": "+str(exc)) from exc
    print("Input assumes one fully closed logical basket per row and NET PnL includes fees.")
    print("Results cannot establish intraday equity DD, open+pending overlap or live broker reliability.")
    report("R1", [r for r in data if r["engine"]=="R1"])
    report("R2", [r for r in data if r["engine"]=="R2"])
    report("R1 + R2 (closed-balance approximation)",data)

if __name__=="__main__":
    if len(sys.argv)!=2:
        print("Usage: python XAU_Forward_Basket_Score_v1.py baskets.csv")
        raise SystemExit(2)
    main(Path(sys.argv[1]))
