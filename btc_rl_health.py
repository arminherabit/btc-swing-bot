"""
BTC RL Health Check
===================
Runs weekly (Monday 08:00 UTC) via GitHub Actions (rl-health.yml).

Reads btc_rl_stats.json (written by nightly retrain), compares against
previous rl_health_report.json, flags drift, writes updated report.

Exit 0 always — failures are surfaced in the GitHub Actions summary.
"""

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT        = Path(__file__).parent
STATS_PATH  = ROOT / "btc_rl_stats.json"
REPORT_PATH = ROOT / "rl_health_report.json"

# Thresholds for flagging
MIN_WIN_RATE    = 40.0   # % — below this = model struggling
MIN_ALPHA       = -5.0   # % — below this = underperforming buy-and-hold badly
MIN_TRADES      = 3      # fewer trades in validation = undertrained / overfit to HOLD
MAX_HOLD_RATE   = 0.90   # if model HOLDs >90% of steps, it's stuck


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def main():
    now = datetime.now(timezone.utc).isoformat()
    print("=" * 60)
    print(f"  BTC RL Health Check  --  {now[:19]} UTC")
    print("=" * 60)

    stats   = load_json(STATS_PATH)
    prev    = load_json(REPORT_PATH)

    if not stats:
        print("  [warn] btc_rl_stats.json not found or empty — no retrain data yet.")
        print("         Run btc_rl_train.py first.")
        return

    # ── Extract stats ──────────────────────────────────────────────────────
    win_rate      = float(stats.get("win_rate",         0.0))
    alpha         = float(stats.get("alpha_pct",        0.0))
    n_trades      = int(  stats.get("n_trades",         0))
    total_ret     = float(stats.get("total_return_pct", 0.0))
    bah_ret       = float(stats.get("bah_return_pct",   0.0))
    trained_at    = stats.get("trained_at", "unknown")
    timesteps     = int(stats.get("timesteps", 0))
    val_candles   = int(stats.get("val_candles", 0))

    print(f"\n  Last retrain   : {trained_at[:19]}")
    print(f"  Timesteps      : {timesteps:,}")
    print(f"  Val candles    : {val_candles:,}")
    print(f"  Win rate       : {win_rate:.1f}%   (threshold >= {MIN_WIN_RATE}%)")
    print(f"  Total return   : {total_ret:+.2f}%")
    print(f"  Buy-and-hold   : {bah_ret:+.2f}%")
    print(f"  Alpha          : {alpha:+.2f}%   (threshold >= {MIN_ALPHA}%)")
    print(f"  N trades       : {n_trades}     (threshold >= {MIN_TRADES})")

    # ── Flags ──────────────────────────────────────────────────────────────
    flags = []
    if win_rate < MIN_WIN_RATE:
        flags.append(f"LOW_WIN_RATE: {win_rate:.1f}% < {MIN_WIN_RATE}%")
    if alpha < MIN_ALPHA:
        flags.append(f"NEGATIVE_ALPHA: {alpha:+.2f}% < {MIN_ALPHA}%")
    if n_trades < MIN_TRADES:
        flags.append(f"TOO_FEW_TRADES: {n_trades} < {MIN_TRADES} in validation")

    # Compare vs previous report
    prev_win  = float(prev.get("win_rate",  win_rate))
    prev_alph = float(prev.get("alpha_pct", alpha))
    win_delta  = win_rate - prev_win
    alph_delta = alpha    - prev_alph
    if prev.get("win_rate"):
        print(f"\n  vs last week   : win_rate {win_delta:+.1f}pp   alpha {alph_delta:+.2f}pp")
        if win_delta < -10.0:
            flags.append(f"WIN_RATE_REGRESSION: dropped {win_delta:.1f}pp vs last week")
        if alph_delta < -5.0:
            flags.append(f"ALPHA_REGRESSION: dropped {alph_delta:.2f}pp vs last week")

    # ── Summary ────────────────────────────────────────────────────────────
    status = "HEALTHY" if not flags else "DEGRADED"
    print(f"\n  Status: {status}")
    if flags:
        print("  Flags:")
        for f in flags:
            print(f"    * {f}")
        print("\n  Recommended action: trigger a fresh retrain via workflow_dispatch")
        print("  on rl-retrain.yml, or check trade_log.jsonl for data quality.")
    else:
        print("  All metrics within healthy ranges.")

    # ── Write report ───────────────────────────────────────────────────────
    report = {
        "checked_at":    now,
        "status":        status,
        "flags":         flags,
        "win_rate":      win_rate,
        "alpha_pct":     alpha,
        "n_trades":      n_trades,
        "total_return":  total_ret,
        "bah_return":    bah_ret,
        "trained_at":    trained_at,
        "timesteps":     timesteps,
        "win_rate_delta":  round(win_delta,  2) if prev.get("win_rate")  else None,
        "alpha_delta":     round(alph_delta, 2) if prev.get("alpha_pct") else None,
    }
    REPORT_PATH.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"\n  Report written → {REPORT_PATH.name}")
    print("=" * 60)


if __name__ == "__main__":
    main()
