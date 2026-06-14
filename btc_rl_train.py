"""
BTC RL Training Script
======================
1. Downloads historical 4H OHLCV from Binance.US
2. Engineers features (RSI, SMA50/200, dip%, vol ratio)
3. Trains PPO with aggressiveness=1.5 for 1M timesteps
4. Runs full backtest and prints trade report
5. Saves model → btc_rl_model.zip

Usage:
    pip install stable-baselines3[extra] gymnasium pandas numpy requests
    python btc_rl_train.py
"""

import os, json, math, time, warnings
import numpy as np
import pandas as pd
import requests
from datetime import datetime, timezone
from stable_baselines3 import PPO
from stable_baselines3.common.env_util import make_vec_env
from stable_baselines3.common.callbacks import EvalCallback, BaseCallback
from stable_baselines3.common.monitor import Monitor
from stable_baselines3.common.vec_env import SubprocVecEnv, DummyVecEnv
import gymnasium as gym
warnings.filterwarnings("ignore")

from btc_rl_env import BTCTradingEnv

# ── Config ─────────────────────────────────────────────────────────────────────
AGGRESSIVENESS   = 1.5          # amplifier on portfolio_return
TOTAL_TIMESTEPS  = 2_000_000    # training steps (single-shot reference)
# Best-of-N: train several candidates with different seeds, keep the one with the
# best blended win-rate + alpha score on held-out data. "Run training again and
# again" — automated. Override via env vars for quick local runs.
N_CANDIDATES      = int(os.getenv("RL_N_CANDIDATES",     "3"))
CANDIDATE_TIMESTEPS = int(os.getenv("RL_CANDIDATE_STEPS", "800000"))
N_ENVS           = 1            # DummyVecEnv: 1 env is faster on Windows
MODEL_PATH       = "btc_rl_model"
BINANCE_URL      = "https://api.binance.us/api/v3/klines"
SYMBOL           = "BTCUSD"
INTERVAL         = "4h"
LOOKBACK_CANDLES = 2500         # ~14 months of 4H data


# ── Data fetching ───────────────────────────────────────────────────────────────

def fetch_funding_rate_history(limit: int = 2500) -> pd.DataFrame:
    """
    Fetch historical 8H BTC funding rates from Binance futures.
    Returns DataFrame with columns: fundingTime (UTC), funding_rate_annual (float).
    """
    print(f"Fetching funding rate history (up to {limit} records)…")
    frames = []
    end_time = None
    remaining = limit

    while remaining > 0:
        batch = min(1000, remaining)
        params = {"symbol": "BTCUSDT", "limit": batch}
        if end_time:
            params["endTime"] = end_time
        try:
            r = requests.get("https://fapi.binance.com/fapi/v1/fundingRate",
                             params=params, timeout=10)
            r.raise_for_status()
            data = r.json()
        except Exception as e:
            print(f"  [warn] Funding rate fetch failed: {e}")
            break
        if not data:
            break
        df = pd.DataFrame(data)
        df["fundingTime"]          = pd.to_datetime(df["fundingTime"].astype(int), unit="ms", utc=True)
        df["funding_rate_annual"]  = df["fundingRate"].astype(float) * 3 * 365 * 100
        frames.insert(0, df[["fundingTime", "funding_rate_annual"]])
        end_time   = int(data[0]["fundingTime"]) - 1
        remaining -= batch
        time.sleep(0.1)

    if not frames:
        print("  [warn] No funding rate data — using neutral 0.0")
        return pd.DataFrame(columns=["fundingTime", "funding_rate_annual"])

    out = pd.concat(frames).drop_duplicates("fundingTime").sort_values("fundingTime").reset_index(drop=True)
    print(f"  Got {len(out)} funding rate records: "
          f"{out['fundingTime'].iloc[0].date()} to {out['fundingTime'].iloc[-1].date()}")
    return out


def fetch_fng_history(limit: int = 2500) -> pd.DataFrame:
    """
    Fetch historical Fear & Greed Index from alternative.me.
    Returns a DataFrame with columns: date (date), fng (int).
    The API returns daily values (one per day); we forward-fill to 4H candle frequency.
    Max ~900 days available from the API.
    """
    print(f"Fetching Fear & Greed history (up to {limit} days)…")
    try:
        r = requests.get(
            f"https://api.alternative.me/fng/?limit={min(limit, 900)}&format=json",
            timeout=15
        )
        r.raise_for_status()
        data = r.json().get("data", [])
        rows = []
        for entry in data:
            ts  = int(entry["timestamp"])
            val = int(entry["value"])
            rows.append({"date": pd.Timestamp(ts, unit="s", tz="UTC").normalize(), "fng": val})
        df = pd.DataFrame(rows).drop_duplicates("date").sort_values("date").reset_index(drop=True)
        print(f"  Got {len(df)} daily F&G records: {df['date'].iloc[0].date()} to {df['date'].iloc[-1].date()}")
        return df
    except Exception as e:
        print(f"  [warn] F&G history fetch failed: {e}  — using neutral 50")
        return pd.DataFrame(columns=["date", "fng"])


def fetch_klines(symbol: str, interval: str, limit: int = 2500) -> pd.DataFrame:
    """Download historical OHLCV from Binance.US (public endpoint, no auth)."""
    print(f"Fetching {limit} × {interval} candles for {symbol}…")
    frames = []
    end_time = None
    remaining = limit

    while remaining > 0:
        batch = min(1000, remaining)
        params = {"symbol": symbol, "interval": interval, "limit": batch}
        if end_time:
            params["endTime"] = end_time

        r = requests.get(BINANCE_URL, params=params, timeout=10)
        r.raise_for_status()
        data = r.json()
        if not data:
            break

        df = pd.DataFrame(data, columns=[
            "open_time","open","high","low","close","volume",
            "close_time","quote_vol","n_trades","taker_buy_base",
            "taker_buy_quote","ignore"
        ])
        df = df[["open_time","open","high","low","close","volume"]].copy()
        for col in ["open","high","low","close","volume"]:
            df[col] = df[col].astype(float)
        df["open_time"] = pd.to_datetime(df["open_time"], unit="ms", utc=True)
        frames.insert(0, df)

        end_time  = int(data[0][0]) - 1  # go further back
        remaining -= batch
        time.sleep(0.15)  # polite rate limiting

    out = pd.concat(frames, ignore_index=True)
    out = out.drop_duplicates("open_time").sort_values("open_time").reset_index(drop=True)
    print(f"  Got {len(out)} candles: {out['open_time'].iloc[0]} to {out['open_time'].iloc[-1]}")
    return out


# ── Feature engineering ─────────────────────────────────────────────────────────

def wilder_rsi(closes: np.ndarray, period: int = 14) -> np.ndarray:
    """Wilder smoothing RSI — matches the bot's implementation."""
    rsi = np.full(len(closes), 50.0)
    if len(closes) < period + 1:
        return rsi
    deltas = np.diff(closes)
    gains  = np.where(deltas > 0, deltas, 0.0)
    losses = np.where(deltas < 0, -deltas, 0.0)

    avg_gain = gains[:period].mean()
    avg_loss = losses[:period].mean()

    for i in range(period, len(closes) - 1):
        avg_gain = (avg_gain * (period - 1) + gains[i]) / period
        avg_loss = (avg_loss * (period - 1) + losses[i]) / period
        rs       = avg_gain / avg_loss if avg_loss > 0 else 1e9
        rsi[i + 1] = 100.0 - 100.0 / (1.0 + rs)
    return rsi


def engineer_features(df: pd.DataFrame,
                      fng_df:     pd.DataFrame = None,
                      funding_df: pd.DataFrame = None) -> pd.DataFrame:
    df = df.copy()
    closes = df["close"].values
    highs  = df["high"].values
    vols   = df["volume"].values

    # RSI
    df["rsi"] = wilder_rsi(closes)

    # SMA (4H)
    df["sma50"]  = pd.Series(closes).rolling(50,  min_periods=1).mean().values
    df["sma200"] = pd.Series(closes).rolling(200, min_periods=1).mean().values

    # 5-day high (30 × 4H candles) and dip %
    five_day_high = pd.Series(highs).rolling(30, min_periods=1).max().values
    df["dip_pct"] = np.where(
        five_day_high > 0,
        (five_day_high - closes) / five_day_high * 100,
        0.0
    )

    # Volume ratio vs 20-bar avg
    vol_ma = pd.Series(vols).rolling(20, min_periods=1).mean().values
    df["vol_ratio"] = np.where(vol_ma > 0, vols / vol_ma, 1.0)

    # Real Fear & Greed (daily → forward-filled to 4H)
    if fng_df is not None and len(fng_df) > 0:
        df["date"] = df["open_time"].dt.normalize()
        df = df.merge(fng_df.rename(columns={"fng": "fng_daily"}), on="date", how="left")
        df["fng"] = df["fng_daily"].ffill().fillna(50).astype(float)
        df = df.drop(columns=["date", "fng_daily"])
    else:
        df["fng"] = 50.0

    df["news_score"] = 0.0  # neutral baseline

    # ── NEW: Daily SMA50 gap (resample 4H → 1D, map back) ────────────────────
    daily_close = df.set_index("open_time")["close"].resample("1D").last().dropna()
    daily_sma50 = daily_close.rolling(50, min_periods=1).mean()
    daily_map   = daily_sma50.reset_index()
    daily_map.columns = ["date_key", "daily_sma50"]
    daily_map["date_key"] = daily_map["date_key"].dt.normalize()
    df["date_key"] = df["open_time"].dt.normalize()
    df = df.merge(daily_map, on="date_key", how="left")
    df["daily_sma50"]    = df["daily_sma50"].ffill().fillna(closes.mean())
    df["daily_vs_sma50"] = np.clip(
        (closes - df["daily_sma50"].values) / df["daily_sma50"].values, -1.0, 1.0
    )
    df = df.drop(columns=["date_key", "daily_sma50"])

    # ── NEW: Funding rate (8H Binance futures, forward-filled to 4H) ─────────
    if funding_df is not None and len(funding_df) > 0:
        funding_df = funding_df.copy()
        funding_df["time_4h"] = funding_df["fundingTime"].dt.floor("4h")
        fmap = funding_df[["time_4h", "funding_rate_annual"]].drop_duplicates("time_4h")
        df["time_4h"] = df["open_time"].dt.floor("4h")
        df = df.merge(fmap, on="time_4h", how="left")
        df["funding_rate_annual"] = df["funding_rate_annual"].ffill().fillna(0.0)
        df = df.drop(columns=["time_4h"])
    else:
        df["funding_rate_annual"] = 0.0

    df = df.dropna().reset_index(drop=True)
    return df


# ── Logging callback ────────────────────────────────────────────────────────────

class RewardLogger(BaseCallback):
    def __init__(self, verbose=0):
        super().__init__(verbose)
        self.ep_rewards = []

    def _on_step(self) -> bool:
        for info in self.locals.get("infos", []):
            if "episode" in info:
                self.ep_rewards.append(info["episode"]["r"])
                if len(self.ep_rewards) % 50 == 0:
                    mean_r = np.mean(self.ep_rewards[-50:])
                    print(f"  Episodes: {len(self.ep_rewards):5d}  "
                          f"Mean reward (last 50): {mean_r:+.4f}")
        return True


# ── Walk-forward validation ─────────────────────────────────────────────────────

def walk_forward_validate(df: pd.DataFrame, n_folds: int = 3) -> list:
    """
    Time-series walk-forward cross-validation.
    Trains lightweight models (300k steps) on expanding windows,
    validates on the next unseen slice. Checks for temporal generalization.

    Returns list of per-fold stats dicts.
    """
    print("\n── Walk-Forward Validation ──────────────────────────────────────────")
    n = len(df)
    results = []
    # Folds: 50%→60%, 60%→72%, 72%→84%
    fold_bounds = [(0.50, 0.60), (0.60, 0.72), (0.72, 0.84)]

    for fold_idx, (train_end_frac, val_end_frac) in enumerate(fold_bounds):
        train_end = int(n * train_end_frac)
        val_end   = int(n * val_end_frac)
        df_tr  = df.iloc[:train_end].reset_index(drop=True)
        df_val = df.iloc[train_end:val_end].reset_index(drop=True)

        if len(df_tr) < 100 or len(df_val) < 50:
            print(f"  Fold {fold_idx+1}: skipped (insufficient data)")
            continue

        print(f"\n  Fold {fold_idx+1}: train={len(df_tr)} candles → val={len(df_val)} candles")

        fold_env = BTCTradingEnv(df_tr, aggressiveness=AGGRESSIVENESS)
        fold_vec = DummyVecEnv([lambda e=fold_env: Monitor(e)])
        fold_model = PPO(
            "MlpPolicy", fold_vec, verbose=0,
            learning_rate=3e-4, n_steps=2048, batch_size=256,
            n_epochs=10, gamma=0.995, gae_lambda=0.95,
            clip_range=0.2, ent_coef=0.02,
            policy_kwargs=dict(net_arch=[dict(pi=[128, 128], vf=[128, 128])]),
        )
        fold_model.learn(total_timesteps=300_000)
        fold_vec.close()

        stats = run_backtest(fold_model, df_val)
        stats["fold"] = fold_idx + 1
        stats["train_candles"] = len(df_tr)
        stats["val_candles"]   = len(df_val)
        results.append(stats)

    if results:
        avg_wr    = sum(r["win_rate"]   for r in results) / len(results)
        avg_alpha = sum(r["alpha_pct"]  for r in results) / len(results)
        print(f"\n  Walk-forward summary: avg win_rate={avg_wr:.1f}%  avg_alpha={avg_alpha:+.2f}%")
        if avg_wr < 40 or avg_alpha < -5:
            print("  [warn] Model generalizes poorly across time folds — consider more data or tuning")
        else:
            print("  Temporal generalization: OK")
    print("─" * 68)
    return results


# ── Backtest ────────────────────────────────────────────────────────────────────

def run_backtest(model, df: pd.DataFrame) -> dict:
    print("\n── Backtest ─────────────────────────────────────────────────────────")
    env   = BTCTradingEnv(df, aggressiveness=AGGRESSIVENESS)
    obs, _ = env.reset(options={"start": 50})
    done  = False
    step  = 0

    while not done:
        action, _ = model.predict(obs, deterministic=True)
        obs, reward, done, _, info = env.step(int(action))
        step += 1

    trades = env.trades
    pv     = info["portfolio_value"]
    total_ret = (pv - env.initial_capital) / env.initial_capital * 100

    wins  = [t for t in trades if t["pnl"] > 0]
    loses = [t for t in trades if t["pnl"] <= 0]

    print(f"  Initial capital : ${env.initial_capital:.2f}")
    print(f"  Final portfolio : ${pv:.2f}")
    print(f"  Total return    : {total_ret:+.2f}%")
    print(f"  Total trades    : {len(trades)}")
    print(f"  Win rate        : {len(wins)/max(1,len(trades))*100:.1f}%")
    if trades:
        avg_win  = np.mean([t["return_pct"] for t in wins])  if wins  else 0
        avg_loss = np.mean([t["return_pct"] for t in loses]) if loses else 0
        best     = max(trades, key=lambda t: t["return_pct"])
        worst    = min(trades, key=lambda t: t["return_pct"])
        print(f"  Avg win         : +{avg_win:.2f}%")
        print(f"  Avg loss        : {avg_loss:.2f}%")
        print(f"  Best trade      : +{best['return_pct']:.2f}%  "
              f"entry ${best['entry_price']:,.0f} → exit ${best['exit_price']:,.0f}")
        print(f"  Worst trade     : {worst['return_pct']:.2f}%  "
              f"entry ${worst['entry_price']:,.0f} → exit ${worst['exit_price']:,.0f}")
        print(f"\n  Last 10 trades:")
        for t in trades[-10:]:
            sign = "✅" if t["pnl"] > 0 else "❌"
            print(f"    {sign}  entry ${t['entry_price']:>8,.0f}  "
                  f"exit ${t['exit_price']:>8,.0f}  "
                  f"{t['return_pct']:+6.2f}%  "
                  f"held {t['steps_held']*4:4d}h")

    # Buy-and-hold comparison
    start_price = df["close"].iloc[50]
    end_price   = df["close"].iloc[-1]
    bah_return  = (end_price - start_price) / start_price * 100
    print(f"\n  Buy-and-hold    : {bah_return:+.2f}%  "
          f"(${start_price:,.0f} → ${end_price:,.0f})")
    print(f"  Alpha           : {total_ret - bah_return:+.2f}%")
    print("─" * 68)

    return {
        "final_portfolio": round(pv, 2),
        "total_return_pct": round(total_ret, 2),
        "n_trades": len(trades),
        "win_rate": round(len(wins) / max(1, len(trades)) * 100, 1),
        "bah_return_pct": round(bah_return, 2),
        "alpha_pct": round(total_ret - bah_return, 2),
    }


# ── Main ────────────────────────────────────────────────────────────────────────

def main():
    # 1. Data
    raw        = fetch_klines(SYMBOL, INTERVAL, LOOKBACK_CANDLES)
    fng_df     = fetch_fng_history(limit=900)
    funding_df = fetch_funding_rate_history(limit=2500)
    df         = engineer_features(raw, fng_df, funding_df)
    print(f"Dataset: {len(df)} candles with {df.shape[1]} features\n")

    # Train / validation split (80/20)
    split     = int(len(df) * 0.80)
    df_train  = df.iloc[:split].reset_index(drop=True)
    df_val    = df.iloc[split:].reset_index(drop=True)

    def make_env():
        env = BTCTradingEnv(df_train, aggressiveness=AGGRESSIVENESS)
        env = Monitor(env)
        return env

    def candidate_score(s: dict) -> float:
        """Blended selection score. Weights win rate (the goal) AND alpha (profit),
        and punishes tiny trade samples whose win rate is statistical noise."""
        wr    = s["win_rate"]          # %
        alpha = s["alpha_pct"]         # %
        n     = s["n_trades"]
        sample_penalty = max(0, 3 - n) * 25.0   # < 3 trades -> unreliable win rate
        return 1.5 * wr + 1.0 * alpha - sample_penalty

    # 2-5. Best-of-N: train several seeds, keep the best on held-out data.
    print(f"\nBest-of-{N_CANDIDATES}: {CANDIDATE_TIMESTEPS:,} timesteps each, "
          f"select by 1.5*win_rate + alpha (min 3 trades)")
    print("=" * 68)
    best_model, best_stats, best_score, candidates = None, None, -1e9, []
    for c in range(N_CANDIDATES):
        seed = 1000 + c * 7
        print(f"\n── Candidate {c+1}/{N_CANDIDATES}  (seed={seed}) ─────────────────────")
        vec_env = make_vec_env(make_env, n_envs=N_ENVS, vec_env_cls=DummyVecEnv,
                               seed=seed)
        model = PPO(
            "MlpPolicy", vec_env, verbose=0, seed=seed,
            learning_rate=3e-4, n_steps=2048, batch_size=256, n_epochs=10,
            gamma=0.995, gae_lambda=0.95, clip_range=0.2,
            ent_coef=0.02, vf_coef=0.5, max_grad_norm=0.5,
            policy_kwargs=dict(net_arch=[dict(pi=[128, 128], vf=[128, 128])]),
        )
        model.learn(total_timesteps=CANDIDATE_TIMESTEPS,
                    callback=RewardLogger(), progress_bar=True)
        stats = run_backtest(model, df_val)
        score = candidate_score(stats)
        print(f"  Candidate {c+1} score: {score:+.1f}  "
              f"(win {stats['win_rate']}%  alpha {stats['alpha_pct']:+.2f}%  "
              f"trades {stats['n_trades']})")
        candidates.append({"seed": seed, "score": round(score, 1), **stats})
        if score > best_score:
            best_score, best_model, best_stats = score, model, stats
        vec_env.close()

    print("\n" + "=" * 68)
    print(f"Best candidate score {best_score:+.1f} "
          f"(win {best_stats['win_rate']}%  alpha {best_stats['alpha_pct']:+.2f}%)")
    model = best_model
    model.save(MODEL_PATH)
    print(f"Winner saved → {MODEL_PATH}.zip")

    # 6. Walk-forward validation (overfitting check) on the winning config
    wf_results = walk_forward_validate(df)

    # 7. Final stats = the winning candidate's held-out backtest (already computed)
    stats = best_stats

    # Save stats
    with open("btc_rl_stats.json", "w") as f:
        json.dump({
            **stats,
            "aggressiveness":     AGGRESSIVENESS,
            "trained_at":         datetime.now(timezone.utc).isoformat(),
            "train_candles":      len(df_train),
            "val_candles":        len(df_val),
            "timesteps":          CANDIDATE_TIMESTEPS,
            "n_candidates":       N_CANDIDATES,
            "selection_score":    round(best_score, 1),
            "candidates":         candidates,
            "obs_features":       18,
            "walk_forward_folds": wf_results,
        }, f, indent=2)
    print(f"\nStats saved → btc_rl_stats.json")


if __name__ == "__main__":
    main()
