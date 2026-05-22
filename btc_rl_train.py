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
TOTAL_TIMESTEPS  = 2_000_000    # training steps
N_ENVS           = 1            # DummyVecEnv: 1 env is faster on Windows
MODEL_PATH       = "btc_rl_model"
BINANCE_URL      = "https://api.binance.us/api/v3/klines"
SYMBOL           = "BTCUSD"
INTERVAL         = "4h"
LOOKBACK_CANDLES = 2500         # ~14 months of 4H data


# ── Data fetching ───────────────────────────────────────────────────────────────

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
    print(f"  Got {len(out)} candles: {out['open_time'].iloc[0]} → {out['open_time'].iloc[-1]}")
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


def engineer_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    closes = df["close"].values
    highs  = df["high"].values
    vols   = df["volume"].values

    # RSI
    df["rsi"] = wilder_rsi(closes)

    # SMA
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

    # Placeholder F&G and news (neutral; live inference uses real values)
    # In backtest we simulate F&G from RSI inversely (low RSI ≈ fear)
    df["fng"]        = np.clip(df["rsi"].values * 1.1, 0, 100)
    df["news_score"] = 0.0  # neutral baseline

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
    raw = fetch_klines(SYMBOL, INTERVAL, LOOKBACK_CANDLES)
    df  = engineer_features(raw)
    print(f"Dataset: {len(df)} candles with {df.shape[1]} features\n")

    # Train / validation split (80/20)
    split     = int(len(df) * 0.80)
    df_train  = df.iloc[:split].reset_index(drop=True)
    df_val    = df.iloc[split:].reset_index(drop=True)

    # 2. Make vectorized envs
    def make_env():
        env = BTCTradingEnv(df_train, aggressiveness=AGGRESSIVENESS)
        env = Monitor(env)
        return env

    print(f"Building {N_ENVS} parallel envs…")
    vec_env = make_vec_env(make_env, n_envs=N_ENVS, vec_env_cls=DummyVecEnv)

    # 3. PPO — aggressive exploration settings
    model = PPO(
        "MlpPolicy",
        vec_env,
        verbose       = 0,
        learning_rate = 3e-4,
        n_steps       = 2048,       # rollout length per env
        batch_size    = 256,        # larger batch = more stable updates
        n_epochs      = 10,
        gamma         = 0.995,      # near-1 = long-term value focus
        gae_lambda    = 0.95,
        clip_range    = 0.2,
        ent_coef      = 0.02,       # higher entropy = more exploration (aggressive)
        vf_coef       = 0.5,
        max_grad_norm = 0.5,
        policy_kwargs = dict(
            net_arch=[dict(pi=[128, 128], vf=[128, 128])],  # fast on CPU
        ),
    )

    # 4. Train
    print(f"\nTraining PPO — aggressiveness={AGGRESSIVENESS} — {TOTAL_TIMESTEPS:,} timesteps")
    print("=" * 68)
    callback = RewardLogger()
    model.learn(total_timesteps=TOTAL_TIMESTEPS, callback=callback, progress_bar=True)
    print("=" * 68)
    print("Training complete.\n")

    # 5. Save
    model.save(MODEL_PATH)
    print(f"Model saved → {MODEL_PATH}.zip")

    # 6. Backtest on held-out validation data
    print("\nValidation set backtest:")
    stats = run_backtest(model, df_val)

    # Save stats
    with open("btc_rl_stats.json", "w") as f:
        json.dump({
            **stats,
            "aggressiveness":  AGGRESSIVENESS,
            "trained_at":      datetime.now(timezone.utc).isoformat(),
            "train_candles":   len(df_train),
            "val_candles":     len(df_val),
            "timesteps":       TOTAL_TIMESTEPS,
        }, f, indent=2)
    print(f"\nStats saved → btc_rl_stats.json")

    vec_env.close()


if __name__ == "__main__":
    main()
