#!/usr/bin/env python3
"""
Self-healing helpers for the BTC swing bot.

Two modes:

  1. State integrity guard (default):
       python btc_self_heal.py
     Validates btc_state.json. If it is missing, unparseable, or has
     impossible values (NaN, negative qty/price, in_position without a
     positive quantity), it restores the last-good copy committed to git,
     and if that is also bad, writes a safe FLAT (cash) state. Read-only
     toward the exchange — it never trades, it only repairs the local file.

  2. Liveness check:
       python btc_self_heal.py --liveness <max_age_minutes>
     Reads last_run from btc_state.json and prints its age. Exits 0 if the
     bot ran within max_age_minutes, exit code 3 if it is stale/missing.
     The watchdog workflow branches on this to restart a stalled flow.

Exit codes: 0 = OK, 2 = state was repaired, 3 = liveness STALE.
"""
import json, math, subprocess, sys
from datetime import datetime, timezone

STATE_FILE = "btc_state.json"

# Keys every valid state must carry, with safe flat-state defaults.
FLAT_STATE = {
    "in_position": False, "tranche_count": 0, "avg_entry": 0.0,
    "total_qty": 0.0, "total_cost": 0.0, "highest_price": 0.0,
    "last_signal": "WATCH (state reset by self-heal)", "last_action": "none",
    "last_run": "", "entry_time": "", "partial_taken": False,
}


def _is_finite_number(x) -> bool:
    return isinstance(x, (int, float)) and math.isfinite(x)


def validate(state) -> list:
    """Return a list of integrity problems; empty list == healthy."""
    problems = []
    if not isinstance(state, dict):
        return ["state is not a JSON object"]
    for k in ("in_position", "tranche_count", "avg_entry", "total_qty",
              "total_cost", "highest_price"):
        if k not in state:
            problems.append(f"missing key: {k}")
    for k in ("avg_entry", "total_qty", "total_cost", "highest_price"):
        v = state.get(k, 0)
        if not _is_finite_number(v):
            problems.append(f"{k} is not a finite number ({v!r})")
        elif v < 0:
            problems.append(f"{k} is negative ({v})")
    tc = state.get("tranche_count", 0)
    if not isinstance(tc, int) or tc < 0 or tc > 3:
        problems.append(f"tranche_count out of range ({tc!r})")
    # In a position but holding nothing == corrupt (would crash exit math).
    if state.get("in_position") and not (_is_finite_number(state.get("total_qty"))
                                         and state.get("total_qty", 0) > 0):
        problems.append("in_position=True but total_qty<=0")
    return problems


def load_json_text(text):
    try:
        return json.loads(text), None
    except Exception as e:  # noqa: BLE001
        return None, str(e)


def last_good_from_git():
    """The btc_state.json as last committed to git (HEAD)."""
    try:
        out = subprocess.run(["git", "show", "HEAD:btc_state.json"],
                             capture_output=True, text=True, timeout=30)
        if out.returncode == 0:
            return out.stdout
    except Exception:  # noqa: BLE001
        pass
    return None


def heal_state() -> int:
    # 1. Read current file.
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            current_text = f.read()
    except FileNotFoundError:
        current_text = ""

    state, err = load_json_text(current_text)
    problems = [f"unparseable: {err}"] if err else validate(state)

    if not problems:
        print(f"[self-heal] state OK — in_position={state.get('in_position')} "
              f"tranches={state.get('tranche_count')} "
              f"last_run={state.get('last_run')}")
        return 0

    print(f"[self-heal] state INVALID: {problems}")

    # 2. Try the last-good committed copy.
    good_text = last_good_from_git()
    if good_text:
        good, gerr = load_json_text(good_text)
        if not gerr and not validate(good):
            with open(STATE_FILE, "w", encoding="utf-8") as f:
                f.write(good_text)
            print("[self-heal] restored last-good btc_state.json from git HEAD")
            return 2

    # 3. Last resort: write a safe flat (cash) state. Never invents a position.
    flat = dict(FLAT_STATE)
    flat["last_run"] = datetime.now(timezone.utc).isoformat()
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(flat, f, indent=2)
    print("[self-heal] no good backup — wrote safe FLAT (cash) state")
    return 2


def liveness(max_age_min: float) -> int:
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            state = json.load(f)
    except Exception as e:  # noqa: BLE001
        print(f"STALE — cannot read state ({e})")
        return 3
    lr = state.get("last_run", "")
    if not lr:
        print("STALE — no last_run timestamp")
        return 3
    try:
        ts = datetime.fromisoformat(lr.replace("Z", "+00:00"))
    except Exception as e:  # noqa: BLE001
        print(f"STALE — bad last_run {lr!r} ({e})")
        return 3
    age_min = (datetime.now(timezone.utc) - ts).total_seconds() / 60.0
    if age_min > max_age_min:
        print(f"STALE — last run {age_min:.0f} min ago (> {max_age_min:.0f})")
        return 3
    print(f"OK — last run {age_min:.0f} min ago (<= {max_age_min:.0f})")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--liveness":
        max_age = float(sys.argv[2]) if len(sys.argv) >= 3 else 90.0
        sys.exit(liveness(max_age))
    sys.exit(heal_state())
