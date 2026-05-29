"""
BTC Bot Logic Audit
===================
Runs daily via GitHub Actions (logic-audit.yml).

Checks for known bug patterns across bot source files and auto-patches
any it can fix safely. Prints a full report. Exit 0 always (fixes are
committed by the workflow, not this script).

Checks performed
----------------
1.  btc_rl_inference.py  — RSI window: wilder_rsi must use full closes array,
    not a short slice (closes[-N:] with N < 100 is wrong).

2.  btc_bot.ps1          — Trade-log qty field: MAIN_ENTRY must log $qty,
    not $tQty or any other undefined variable.

3.  btc_bot.ps1          — RL BUY tranche cap: override must compare against
    $maxTranchesEff, not $cfg.max_tranches.

4.  btc_rl_inference.py  — n_samples for confidence: must be >= 20.

5.  btc_rl_train.py      — F&G must NOT be synthesised from RSI (rsi * 1.1).
    Real fetch_fng_history() call must be present and wired into engineer_features.

6.  btc_bot.ps1          — last_action_time stamp pattern must cover all
    trade actions (BUY_T, SELL, PARTIAL_SELL, RL_BUY, RL_SELL, RL_PARTIAL, SCALP_).

7.  btc_rl_train.py      — TOTAL_TIMESTEPS must be >= 1_000_000.

8.  btc_bot.ps1          — Get-Klines call for RSI must request >= 100 candles.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).parent
FIXES_APPLIED = []
ISSUES_FOUND  = []
CHECKS_PASSED = []


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def write(path: Path, content: str):
    path.write_text(content, encoding="utf-8")


def check(name: str, ok: bool, detail: str = ""):
    if ok:
        CHECKS_PASSED.append(f"  PASS  {name}" + (f"  ({detail})" if detail else ""))
    else:
        ISSUES_FOUND.append(f"  FAIL  {name}" + (f"  ({detail})" if detail else ""))


# ── 1. RSI window in inference ────────────────────────────────────────────────

def audit_rsi_window():
    path = ROOT / "btc_rl_inference.py"
    if not path.exists():
        check("rsi_window_inference", False, "btc_rl_inference.py not found")
        return
    src = read(path)
    # Look for wilder_rsi(closes[-N:]) where N < 100
    m = re.search(r"wilder_rsi\(closes\[-(\d+):\]\)", src)
    if m and int(m.group(1)) < 100:
        bad  = m.group(0)
        good = "wilder_rsi(closes)  # use all candles — Wilder smoothing needs long history"
        new_src = src.replace(bad, good, 1)
        write(path, new_src)
        FIXES_APPLIED.append(f"btc_rl_inference.py: replaced {bad} with wilder_rsi(closes)")
        check("rsi_window_inference", True, f"auto-fixed {bad} → wilder_rsi(closes)")
    elif "wilder_rsi(closes)" in src and "closes[-" not in src.split("wilder_rsi")[1].split(")")[0]:
        check("rsi_window_inference", True, "uses full closes array")
    else:
        check("rsi_window_inference", True, "no short-slice pattern found")


# ── 2. Trade-log qty field ────────────────────────────────────────────────────

def audit_trade_log_qty():
    path = ROOT / "btc_bot.ps1"
    if not path.exists():
        check("trade_log_qty", False, "btc_bot.ps1 not found")
        return
    src = read(path)
    if "$tQty" in src:
        new_src = src.replace("$tQty", "$qty")
        write(path, new_src)
        FIXES_APPLIED.append("btc_bot.ps1: replaced $tQty → $qty in MAIN_ENTRY trade log")
        check("trade_log_qty", True, "auto-fixed $tQty → $qty")
    elif re.search(r"kind = .MAIN_ENTRY.*qty = \$qty", src, re.DOTALL):
        check("trade_log_qty", True, "MAIN_ENTRY logs $qty correctly")
    else:
        check("trade_log_qty", True, "MAIN_ENTRY qty field looks correct")


# ── 3. RL BUY tranche cap ─────────────────────────────────────────────────────

def audit_rl_tranche_cap():
    path = ROOT / "btc_bot.ps1"
    if not path.exists():
        return
    src = read(path)
    # The RL BUY override block — should use $maxTranchesEff not $cfg.max_tranches
    pattern = r"(\$rlAction -eq .BUY_TRANCHE[^}]+?)-and \[int\]\$state\.tranche_count -lt \[int\]\$cfg\.max_tranches"
    m = re.search(pattern, src, re.DOTALL)
    if m:
        old = "-and [int]$state.tranche_count -lt [int]$cfg.max_tranches"
        new = "-and [int]$state.tranche_count -lt $maxTranchesEff"
        new_src = src.replace(old, new, 1)
        write(path, new_src)
        FIXES_APPLIED.append("btc_bot.ps1: RL BUY now respects $maxTranchesEff (BEAR=2 cap)")
        check("rl_tranche_cap", True, "auto-fixed: now uses $maxTranchesEff")
    else:
        if "$maxTranchesEff" in src:
            check("rl_tranche_cap", True, "uses $maxTranchesEff correctly")
        else:
            check("rl_tranche_cap", False, "cannot locate RL BUY block — manual review needed")


# ── 4. n_samples >= 20 ───────────────────────────────────────────────────────

def audit_n_samples():
    path = ROOT / "btc_rl_inference.py"
    if not path.exists():
        return
    src = read(path)
    m = re.search(r"n_samples\s*=\s*(\d+)", src)
    if m:
        n = int(m.group(1))
        check("n_samples", n >= 20, f"n_samples={n}")
    else:
        check("n_samples", False, "n_samples not found")


# ── 5. Real F&G in training ──────────────────────────────────────────────────

def audit_fng_training():
    path = ROOT / "btc_rl_train.py"
    if not path.exists():
        check("fng_training", False, "btc_rl_train.py not found")
        return
    src = read(path)
    synthetic = bool(re.search(r'df\["fng"\]\s*=\s*np\.clip\(df\["rsi"\]', src))
    has_fetch  = "fetch_fng_history" in src
    wired      = "fng_df" in src
    if synthetic:
        check("fng_training", False, "F&G still synthetic (rsi*1.1) — retrain needed")
    elif has_fetch and wired:
        check("fng_training", True, "fetch_fng_history wired into engineer_features")
    else:
        check("fng_training", False, "fetch_fng_history missing or not wired")


# ── 6. last_action_time stamp pattern ────────────────────────────────────────

REQUIRED_ACTIONS = ["BUY_T", "SELL", "PARTIAL_SELL", "RL_BUY", "RL_SELL", "RL_PARTIAL", "SCALP_"]

def audit_action_stamp():
    path = ROOT / "btc_bot.ps1"
    if not path.exists():
        return
    src = read(path)
    m = re.search(r"last_action_time.*?-match\s+['\"]([^'\"]+)['\"]", src, re.DOTALL)
    if not m:
        check("action_stamp_pattern", False, "last_action_time stamp block not found")
        return
    pattern_str = m.group(1)
    missing = [a for a in REQUIRED_ACTIONS if a not in pattern_str]
    if missing:
        check("action_stamp_pattern", False, f"missing actions in pattern: {missing}")
    else:
        check("action_stamp_pattern", True, f"all required actions covered")


# ── 7. TOTAL_TIMESTEPS ───────────────────────────────────────────────────────

def audit_timesteps():
    path = ROOT / "btc_rl_train.py"
    if not path.exists():
        return
    src = read(path)
    m = re.search(r"TOTAL_TIMESTEPS\s*=\s*([\d_]+)", src)
    if m:
        n = int(m.group(1).replace("_", ""))
        check("total_timesteps", n >= 1_000_000, f"TOTAL_TIMESTEPS={n:,}")
    else:
        check("total_timesteps", False, "TOTAL_TIMESTEPS not found")


# ── 8. Klines candle count ───────────────────────────────────────────────────

def audit_klines_count():
    path = ROOT / "btc_bot.ps1"
    if not path.exists():
        return
    src = read(path)
    # Find Get-Klines "4h" <N>
    m = re.search(r'Get-Klines\s+"4h"\s+(\d+)', src)
    if m:
        n = int(m.group(1))
        check("klines_candle_count", n >= 100, f"Get-Klines 4h {n}")
    else:
        check("klines_candle_count", False, "Get-Klines 4h call not found")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    print("=" * 60)
    print("  BTC Bot Logic Audit")
    print("=" * 60)

    audit_rsi_window()
    audit_trade_log_qty()
    audit_rl_tranche_cap()
    audit_n_samples()
    audit_fng_training()
    audit_action_stamp()
    audit_timesteps()
    audit_klines_count()

    print(f"\n  Checks passed : {len(CHECKS_PASSED)}")
    print(f"  Issues found  : {len(ISSUES_FOUND)}")
    print(f"  Fixes applied : {len(FIXES_APPLIED)}")

    if CHECKS_PASSED:
        print("\n--- PASSED ---")
        for msg in CHECKS_PASSED:
            print(msg)

    if ISSUES_FOUND:
        print("\n--- ISSUES ---")
        for msg in ISSUES_FOUND:
            print(msg)

    if FIXES_APPLIED:
        print("\n--- FIXES APPLIED ---")
        for msg in FIXES_APPLIED:
            print(f"  * {msg}")

    print("=" * 60)


if __name__ == "__main__":
    main()
