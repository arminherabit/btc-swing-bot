"""
Trade-log review: summarizes outcomes from trade_log.jsonl
Run before nightly retrain to log realized stats and flag drift.
"""
import json
import os
import sys
from collections import defaultdict
from statistics import mean

LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "trade_log.jsonl")

def load():
    if not os.path.exists(LOG_PATH):
        return []
    rows = []
    with open(LOG_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows

def summarize(rows):
    exits = [r for r in rows if r.get("kind", "").endswith("EXIT") or r.get("kind") == "PARTIAL_PROFIT"]
    entries = [r for r in rows if r.get("kind") in ("MAIN_ENTRY",) or r.get("kind", "").endswith("BUY")]

    if not exits:
        print("No completed trades yet.")
        return

    pnl_pcts = [float(r.get("pnl_pct", 0)) for r in exits if "pnl_pct" in r]
    wins = [p for p in pnl_pcts if p > 0]
    losses = [p for p in pnl_pcts if p <= 0]

    print(f"Total entries: {len(entries)}")
    print(f"Total exits:   {len(exits)}")
    print(f"Win rate:      {len(wins)/len(pnl_pcts)*100:.1f}%" if pnl_pcts else "Win rate: n/a")
    print(f"Avg PnL %:     {mean(pnl_pcts):.2f}%" if pnl_pcts else "")
    print(f"Avg win:       {mean(wins):.2f}%" if wins else "")
    print(f"Avg loss:      {mean(losses):.2f}%" if losses else "")

    by_kind = defaultdict(list)
    for r in exits:
        by_kind[r.get("kind", "?")].append(float(r.get("pnl_pct", 0)))
    print("\nBy exit kind:")
    for k, v in by_kind.items():
        wr = sum(1 for p in v if p > 0) / len(v) * 100
        print(f"  {k:16s} n={len(v):3d}  avg={mean(v):+.2f}%  win={wr:.0f}%")

    by_mode = defaultdict(list)
    for r in exits:
        by_mode[r.get("mode", "?")].append(float(r.get("pnl_pct", 0)))
    print("\nBy mode:")
    for k, v in by_mode.items():
        wr = sum(1 for p in v if p > 0) / len(v) * 100
        print(f"  {k:10s} n={len(v):3d}  avg={mean(v):+.2f}%  win={wr:.0f}%")

if __name__ == "__main__":
    rows = load()
    print(f"Loaded {len(rows)} log rows from trade_log.jsonl\n")
    summarize(rows)
