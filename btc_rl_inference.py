"""
BTC RL Live Inference
=====================
Called every hour by GitHub Actions BEFORE btc_bot.ps1.
Loads the trained PPO model, builds the current observation
from live market data, and writes rl_signal.json.

btc_bot.ps1 reads rl_signal.json and overrides its own
rule-based decision when the RL signal is confident enough.

Usage:
    python btc_rl_inference.py [--state btc_state.json] [--out rl_signal.json]
"""

import os, sys, json, math, time, argparse
import numpy as np
import requests
from datetime import datetime, timezone

# ── Args ───────────────────────────────────────────────────────────────────────
ap = argparse.ArgumentParser()
ap.add_argument("--state",  default="btc_state.json")
ap.add_argument("--out",    default="rl_signal.json")
ap.add_argument("--model",  default="btc_rl_model")
args = ap.parse_args()

BINANCE = "https://api.binance.us/api/v3"
FNG_URL = "https://api.alternative.me/fng/?limit=1"
ACTION_NAMES = {0: "HOLD", 1: "BUY_TRANCHE", 2: "SELL_PARTIAL", 3: "SELL_ALL"}
AGGRESSIVENESS = 1.5


# ── Helpers ────────────────────────────────────────────────────────────────────

def safe_get(url, params=None, timeout=8):
    try:
        r = requests.get(url, params=params, timeout=timeout)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        print(f"  [warn] GET {url}: {e}")
        return None


def wilder_rsi(closes, period=14):
    closes = np.array(closes, dtype=float)
    if len(closes) < period + 1:
        return 50.0
    deltas = np.diff(closes)
    gains  = np.where(deltas > 0, deltas, 0.0)
    losses = np.where(deltas < 0, -deltas, 0.0)
    avg_g  = gains[:period].mean()
    avg_l  = losses[:period].mean()
    for i in range(period, len(closes) - 1):
        avg_g = (avg_g * (period - 1) + gains[i]) / period
        avg_l = (avg_l * (period - 1) + losses[i]) / period
    rs = avg_g / avg_l if avg_l > 0 else 1e9
    return float(100.0 - 100.0 / (1.0 + rs))


# ── Fetch live market data ─────────────────────────────────────────────────────

def fetch_candles(symbol="BTCUSD", interval="4h", limit=220):
    data = safe_get(f"{BINANCE}/klines", {"symbol": symbol, "interval": interval, "limit": limit})
    if not data:
        return None
    closes  = [float(c[4]) for c in data]
    highs   = [float(c[2]) for c in data]
    volumes = [float(c[5]) for c in data]
    return closes, highs, volumes


def fetch_fng():
    data = safe_get(FNG_URL)
    if data and "data" in data:
        return int(data["data"][0]["value"]), data["data"][0]["value_classification"]
    return 50, "Unknown"


def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


# ── Build observation (must match btc_rl_env._features exactly) ───────────────

def build_obs(closes, highs, vols, state, fng_val, news_score=0.0):
    price  = closes[-1]
    sma50  = float(np.mean(closes[-50:]))  if len(closes) >= 50  else price
    sma200 = float(np.mean(closes[-200:])) if len(closes) >= 200 else price
    rsi    = wilder_rsi(closes)  # use all candles — Wilder smoothing needs long history

    five_day_high = max(highs[-30:])
    dip_pct = (five_day_high - price) / five_day_high * 100 if five_day_high > 0 else 0.0

    vol_ma   = float(np.mean(vols[-21:-1])) if len(vols) >= 21 else 1.0
    vol_ratio = vols[-1] / vol_ma if vol_ma > 0 else 1.0

    # Price momentum
    p1  = closes[-2]  if len(closes) >= 2  else price
    p6  = closes[-7]  if len(closes) >= 7  else price
    p24 = closes[-25] if len(closes) >= 25 else price
    ret4h  = np.clip((price - p1)  / p1,  -0.10, 0.10) / 0.10
    ret24h = np.clip((price - p6)  / p6,  -0.20, 0.20) / 0.20
    ret4d  = np.clip((price - p24) / p24, -0.30, 0.30) / 0.30

    # Position state from btc_state.json
    in_pos      = float(state.get("in_position", False))
    avg_entry   = float(state.get("avg_entry",   0.0))
    total_qty   = float(state.get("total_qty",   0.0))
    tranche_cnt = int(state.get("tranche_count", 0))
    peak_price  = float(state.get("highest_price", avg_entry))
    partial_tkn = float(state.get("partial_taken", False))

    upnl = 0.0
    if in_pos and avg_entry > 0:
        upnl = np.clip((price - avg_entry) / avg_entry, -0.20, 0.20) / 0.20

    hold_h = 0.0
    if in_pos and state.get("entry_time"):
        try:
            from datetime import datetime, timezone
            entry_dt = datetime.fromisoformat(state["entry_time"].replace("Z", "+00:00"))
            hours    = (datetime.now(timezone.utc) - entry_dt).total_seconds() / 3600
            hold_h   = np.clip(hours / 120.0, 0.0, 1.0)
        except Exception:
            pass

    drawdown = 0.0
    if in_pos and peak_price > 0 and price < peak_price:
        drawdown = np.clip((peak_price - price) / peak_price / 0.10, 0.0, 1.0)

    obs = np.array([
        rsi / 100.0,
        np.clip((price - sma200) / sma200, -0.4, 0.4) / 0.4,
        np.clip((price - sma50)  / sma50,  -0.2, 0.2) / 0.2,
        np.clip(dip_pct / 10.0, 0.0, 1.0),
        np.clip(vol_ratio / 3.0, 0.0, 1.0),
        fng_val / 100.0,
        np.clip((news_score + 10.0) / 20.0, 0.0, 1.0),
        ret4h, ret24h, ret4d,
        in_pos, upnl,
        tranche_cnt / 3.0,
        hold_h, drawdown,
        partial_tkn,
    ], dtype=np.float32)

    return obs, {
        "price": price, "rsi": rsi, "sma200": sma200, "sma50": sma50,
        "dip_pct": dip_pct, "fng": fng_val, "vol_ratio": vol_ratio,
        "in_position": bool(in_pos), "unrealized_pnl_pct": upnl * 20.0,
    }


# ── Action confidence via repeated sampling ────────────────────────────────────

def predict_with_confidence(model, obs, n_samples=20):
    """
    Run inference n_samples times with stochastic policy to get action distribution.
    Returns best action + probability.
    """
    counts = {0: 0, 1: 0, 2: 0, 3: 0}
    for _ in range(n_samples):
        action, _ = model.predict(obs, deterministic=False)
        counts[int(action)] += 1
    best_action     = max(counts, key=counts.get)
    confidence      = counts[best_action] / n_samples
    # Also get deterministic prediction
    det_action, _   = model.predict(obs, deterministic=True)
    return int(det_action), float(confidence), counts


# ── Compute reward for current state (for dashboard) ──────────────────────────

def compute_reward(state, price, af):
    portfolio_return = 0.0
    max_drawdown     = 0.0
    tx_costs         = 0.0
    avg_entry   = float(state.get("avg_entry",   0.0))
    peak        = float(state.get("highest_price", avg_entry))
    tc          = int(state.get("tranche_count", 0))
    in_pos      = bool(state.get("in_position", False))
    if in_pos and avg_entry > 0:
        portfolio_return = (price - avg_entry) / avg_entry
        if peak > 0 and price < peak:
            max_drawdown = (peak - price) / peak
        tx_costs = 0.002 * tc
    reward = portfolio_return * (1.0 + af) - 0.3 * max_drawdown - tx_costs
    return round(reward, 6)


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    now = datetime.now(timezone.utc).isoformat()
    print(f"\n{'='*60}")
    print(f"  BTC RL Inference  --  {now[:19]} UTC")
    print(f"{'='*60}")

    # Check model exists
    model_zip = args.model + ".zip"
    if not os.path.exists(model_zip):
        print(f"  [skip] No model at {model_zip} — RL signal not generated.")
        signal = {"action": "NONE", "reason": "model_not_found", "confidence": 0.0}
        with open(args.out, "w") as f:
            json.dump(signal, f)
        return

    # Load model
    try:
        from stable_baselines3 import PPO
        model = PPO.load(args.model)
        print(f"  Model loaded: {model_zip}")
    except Exception as e:
        print(f"  [error] Cannot load model: {e}")
        return

    # Load state
    state = load_state(args.state)
    print(f"  State: in_position={state.get('in_position')}, "
          f"tranches={state.get('tranche_count',0)}/3")

    # Fetch market data
    result = fetch_candles()
    if result is None:
        print("  [error] Cannot fetch candles — RL signal skipped.")
        return
    closes, highs, vols = result
    price = closes[-1]
    print(f"  Live price: ${price:,.2f}")

    # Fetch F&G
    fng_val, fng_label = fetch_fng()
    print(f"  Fear & Greed: {fng_val}/100 {fng_label}")

    # Load news score from state (bot already computed it)
    news_score = float(state.get("news_score", 0.0))

    # Build observation
    obs, market = build_obs(closes, highs, vols, state, fng_val, news_score)
    print(f"  RSI: {market['rsi']:.1f}  Dip: {market['dip_pct']:.2f}%  "
          f"SMA200: ${market['sma200']:,.0f}")

    # Predict
    action, confidence, dist = predict_with_confidence(model, obs, n_samples=30)
    action_name = ACTION_NAMES[action]
    print(f"\n  RL Decision: {action_name} (confidence {confidence:.0%})")
    print(f"  Distribution: " +
          " ".join(f"{ACTION_NAMES[a]}={v/30:.0%}" for a, v in dist.items()))

    # Aggressiveness factor (simplified, matches bot logic)
    af = 0.15 if price > market["sma200"] else 0.05
    if fng_val <= 25: af += 0.15
    if fng_val >= 80: af -= 0.15
    if market["rsi"] <= 30: af += 0.10
    af = round(max(-0.20, min(0.50, af)), 3)
    cycle_reward = compute_reward(state, price, af)
    print(f"  Aggressiveness: {af}  Reward: {cycle_reward:+.4f}")

    # Write signal
    signal = {
        "action":          action_name,
        "action_id":       action,
        "confidence":      round(confidence, 3),
        "distribution":    {ACTION_NAMES[a]: round(v/30, 3) for a, v in dist.items()},
        "aggressiveness":  AGGRESSIVENESS,
        "af":              af,
        "cycle_reward":    cycle_reward,
        "price":           price,
        "rsi":             round(market["rsi"], 1),
        "dip_pct":         round(market["dip_pct"], 2),
        "fng":             fng_val,
        "generated_at":    now,
        # Confidence gate: bot only acts on RL signal if confidence >= this
        "confidence_gate": 0.60,
        "override":        confidence >= 0.60,
    }

    with open(args.out, "w") as f:
        json.dump(signal, f, indent=2)

    print(f"\n  Signal written → {args.out}")
    print(f"  Override active: {signal['override']} "
          f"({'bot will follow RL' if signal['override'] else 'bot uses own rules'})")
    print("=" * 60)


if __name__ == "__main__":
    main()
