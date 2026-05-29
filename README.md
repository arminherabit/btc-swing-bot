# BTC Swing Trading Bot

Autonomous Bitcoin swing trading bot running 24/7 on GitHub Actions. Combines rule-based dip-ladder entry/exit logic with a live-retrained PPO reinforcement learning model and real-time news sentiment scoring via Claude AI.

**Live dashboard:** [arminherabit.github.io/btc-swing-bot](https://arminherabit.github.io/btc-swing-bot)

---

## Architecture

```
Every hour (GitHub Actions cron)
        │
        ▼
┌─────────────────────────┐
│  btc_rl_inference.py    │  ← Python: fetch market data, run PPO model
│  (RL Pre-signal)        │    write rl_signal.json
└────────────┬────────────┘
             │ rl_signal.json
             ▼
┌─────────────────────────┐
│  btc_bot.ps1            │  ← PowerShell: fetch data, apply rules,
│  (Run swing bot)        │    read RL signal, execute trades via Binance.US
└────────────┬────────────┘
             │ btc_state.json + trade_log.jsonl
             ▼
┌─────────────────────────┐
│  Pages deploy           │  ← Dashboard updated at github.io
└─────────────────────────┘

Every night 03:00 UTC
┌─────────────────────────┐
│  btc_rl_train.py        │  ← Retrain PPO on trade_log.jsonl + fresh price data
│  (Nightly RL Retrain)   │    commit new btc_rl_model.zip if validation passes
└─────────────────────────┘

Every day 10:00 UTC
┌─────────────────────────┐
│  btc_logic_audit.py     │  ← Scan source for 8 known bug patterns,
│  (Daily Logic Audit)    │    auto-commit fixes
└─────────────────────────┘

Every Monday 08:00 UTC
┌─────────────────────────┐
│  btc_rl_health.py       │  ← Check model win rate / alpha / drift,
│  (Weekly RL Health)     │    write rl_health_report.json
└─────────────────────────┘
```

---

## Market Modes

The bot determines its mode from the 4H SMA200:

| Mode | Condition | RSI Gates | Dip Required | Max Tranches | Trail Stop |
|------|-----------|-----------|--------------|--------------|------------|
| **BULL** | Price > SMA200 | T1≤42, T2≤36, T3≤30 | ≥1.5% | 3 | 3% from peak |
| **NEAR-SMA** | 0–3% below SMA200 | T1≤42, T2≤36, T3≤30 (BULL gates) | ≥2.0% | 2 | 4.5% from peak |
| **BEAR** | >3% below SMA200 | T1≤35, T2≤29, T3≤23 | ≥3.0% | 2 | 4.5% from peak |

NEAR-SMA uses BULL RSI gates (easier entry) but BEAR safety caps — designed to catch breakout setups when price is recovering toward the SMA200.

---

## Entry Logic

Each cycle the bot checks whether to buy a tranche (up to the mode maximum):

```
entryBlocked?  →  NO action
    ├── Fear & Greed ≥ 80 (Extreme Greed)
    ├── News score ≤ -5 (strongly bearish Claude AI assessment)
    └── Within 8h of last stop-out (cooldown)

All of these must be TRUE to enter:
    ├── RSI 4H ≤ threshold for next tranche (T1/T2/T3, adjusted by AF)
    ├── 5-day dip % ≥ required for mode (adjusted by AF when AF ≥ 0.30)
    ├── Below max tranches for mode
    └── BEAR only: RSI must be turning up (higher low in last 2 bars)
          OR bullish divergence detected
          OR NEAR-SMA mode (breakout check skipped)

Entry reason logged: RSI DIP / DIVERGENCE / F&G FEAR BOOST / NEWS BOOST / RSI TURN
```

### Aggressiveness Factor (AF)

A single conviction score (−0.20 to +0.50) computed each cycle that loosens or tightens all gates dynamically:

| Signal | Contribution |
|--------|-------------|
| BULL base | +0.15 |
| BEAR base | +0.05 |
| F&G ≤ 15 (Extreme Fear) | +0.20 |
| F&G ≤ 25 (Extreme Fear) | +0.15 |
| F&G ≤ 45 (Fear) | +0.05 |
| F&G ≥ 65 (Greed) | −0.10 |
| F&G ≥ 80 (Extreme Greed) | −0.20 |
| News score ≥ 6 | +0.10 |
| News score ≥ 3 | +0.05 |
| News score ≤ −5 | −0.10 |
| News score ≤ −2 | −0.05 |
| RSI ≤ 25 | +0.15 |
| RSI ≤ 30 | +0.10 |
| RSI ≤ 35 | +0.05 |
| Bullish divergence | +0.10 |
| **Watchdog boost** | +0.10 (if idle 48h+ AND F&G ≤30 AND no position AND not blocked) |

**AF effect on gates:** each +0.10 AF (above 0.00) adds 1 RSI point to all thresholds. When AF ≥ 0.30, dip requirement drops by 0.5%.

Labels: DEFENSIVE (<0.05) / LOW (0.05–0.20) / MEDIUM (0.20–0.35) / HIGH (≥0.35)

---

## Exit Logic

Checked every cycle while in position:

| Trigger | Condition | Action |
|---------|-----------|--------|
| **Partial profit** | Price ≥ +5% BULL / +3% BEAR from avg entry (after 12h min hold) | Sell 50% |
| **RSI overbought** | RSI 4H ≥ 60 | Sell ALL |
| **Trail stop** | Price drops 3% BULL / 4.5% BEAR from peak (after 12h min hold) | Sell ALL + 8h cooldown |
| **Hard stop** | Price drops 5% from avg entry | Sell ALL + 8h cooldown |

---

## Reinforcement Learning Layer

### Model
- **Algorithm:** PPO (Proximal Policy Optimization) via stable-baselines3
- **Architecture:** MLP policy, net_arch [128, 128]
- **Training:** 2,000,000 timesteps on 14+ months of 4H OHLCV data
- **Retrain:** Nightly at 03:00 UTC from `trade_log.jsonl` + fresh price data + real Fear & Greed history

### Observation space (16 features)
```
[rsi/100, price_vs_sma200, price_vs_sma50, dip_pct/10, vol_ratio/3,
 fng/100, news_score_norm, ret_4h, ret_24h, ret_4d,
 in_position, unrealized_pnl, tranche_count/3,
 hold_hours/120, drawdown, partial_taken]
```

### Action space
`0=HOLD  1=BUY_TRANCHE  2=SELL_PARTIAL  3=SELL_ALL`

### Override rules
The RL model overrides rule-based logic **only when:**
- Confidence ≥ 60% (30-sample stochastic inference)
- For BUY: RSI is also below the current tranche gate (rule-based RSI gate is a hard floor)
- For SELL: position exists with qty > 0
- Entry is not blocked by news/F&G/cooldown
- Tranche count < maxTranchesEff (2 in BEAR, 3 in BULL)

Below 60% confidence, the RL signal is logged but ignored.

### Reward function (training)
```
reward = realized_pnl × (1 + aggressiveness)
       + step_pct × 0.3          (while in position)
       − 0.3 × drawdown          (drawdown penalty)
       − 0.00005                 (holding cost)
       + entry/exit quality shaping bonuses
```

---

## News Sentiment (Claude AI)

Every 4 hours, `btc_news.ps1` calls the Anthropic API to score Bitcoin news on a −10 to +10 scale for the 1–7 day swing window.

- Score ≥ 6 → boosts AF (+0.10)
- Score ≤ −2 → reduces AF (−0.05)
- Score ≤ −5 → **blocks all entries**

The reasoning is cached in `btc_news_cache.json` to avoid redundant API calls.

---

## Range-Scalp Module (optional)

A secondary $50 scalping layer for low-volatility sideways markets. **Disabled by default** (`scalp_enabled: false` in `btc_config.json`).

When enabled:
- Only fires when: no main position, ATR% < 1%, RSI 40–58, 4h cooldown elapsed, entry not blocked
- Take profit: +1.5% | Stop loss: −1.0% | Max hold: 8h
- Fully independent from main tranches

---

## Stale Watchdog

If the bot has taken no trade action in 48+ hours AND Fear & Greed ≤ 30 AND not in position AND entry not blocked → AF is boosted +0.10. Prevents the bot from sitting completely idle during extended low-volatility Extreme Fear periods.

---

## Files

| File | Purpose |
|------|---------|
| `btc_bot.ps1` | Main trading engine (PowerShell) |
| `btc_news.ps1` | Claude AI news sentiment scorer |
| `btc_rl_inference.py` | Live PPO inference → `rl_signal.json` |
| `btc_rl_train.py` | Nightly PPO retrainer |
| `btc_rl_env.py` | Gymnasium trading environment |
| `btc_rl_review.py` | Trade log stats (runs before retrain) |
| `btc_logic_audit.py` | Daily automated bug scanner / auto-fixer |
| `btc_rl_health.py` | Weekly model health check |
| `btc_config.json` | All tunable parameters |
| `btc_state.json` | Live bot state (position, RSI, signals…) |
| `trade_log.jsonl` | Every closed trade with full context |
| `rl_signal.json` | Current RL action + confidence |
| `btc_rl_model.zip` | Trained PPO weights |
| `btc_rl_stats.json` | Last retrain backtest results |
| `rl_health_report.json` | Weekly health check output |

---

## Configuration (`btc_config.json`)

```json
{
  "paper_trading":           false,
  "tranche_size_usdt":       167,
  "max_tranches":            3,
  "rsi_tranche1":            42,
  "rsi_tranche2":            36,
  "rsi_tranche3":            30,
  "rsi_exit":                60,
  "rsi_bear_offset":         7,
  "dip_pct_required":        1.5,
  "dip_pct_bear":            3.0,
  "trailing_stop_pct":       3.0,
  "hard_stop_pct":           5.0,
  "min_hold_hours":          12,
  "partial_profit_pct":      5.0,
  "partial_profit_pct_bear": 3.0,
  "partial_profit_size":     0.5,
  "fng_block_threshold":     80,
  "fng_boost_threshold":     25,
  "news_cache_hours":        4,
  "news_skip_threshold":    -5,
  "news_boost_threshold":    6,
  "scalp_enabled":           false
}
```

---

## GitHub Actions Workflows

| Workflow | Schedule | Description |
|----------|----------|-------------|
| `bot.yml` | Every hour | Live trading cycle |
| `rl-retrain.yml` | Daily 03:00 UTC | PPO model retrain |
| `logic-audit.yml` | Daily 10:00 UTC | Auto bug detection + fix |
| `rl-health.yml` | Monday 08:00 UTC | Model drift check |

---

## Current Model Performance (last retrain)

| Metric | Value |
|--------|-------|
| Trained at | 2026-05-28 |
| Timesteps | 2,000,000 |
| Validation win rate | 63.6% |
| Validation return | +1.9% |
| Buy-and-hold (same period) | +3.1% |
| Alpha | −1.2% |
| N trades (validation) | 11 |

---

## Required Secrets (GitHub → Settings → Secrets)

| Secret | Description |
|--------|-------------|
| `BINANCE_API_KEY` | Binance.US API key |
| `BINANCE_API_SECRET` | Binance.US API secret |
| `ANTHROPIC_API_KEY` | Claude AI API key (news scoring) |

---

## How It Learns

1. Every closed trade is appended to `trade_log.jsonl` with full context (price, RSI, mode, F&G, news score, AF, exit reason, PnL%)
2. At 03:00 UTC, `btc_rl_review.py` prints a stats summary of all trades
3. `btc_rl_train.py` fetches fresh 4H OHLCV + real Fear & Greed history, retrains PPO for 2M timesteps, runs a validation backtest
4. If the model file changes, it's committed back to the repo (`[skip ci]` to avoid loop)
5. The next hourly run automatically picks up the new `btc_rl_model.zip`

The model improves as real trade outcomes accumulate. With no trades yet, it trains purely on historical price data with neutral news. Once the bot starts trading, each exit enriches the training signal with live PnL feedback.
