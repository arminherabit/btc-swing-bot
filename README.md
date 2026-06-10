# BTC Swing Trading Bot

Autonomous Bitcoin swing trading bot running 24/7 on GitHub Actions. Combines rule-based dip-ladder entry/exit logic with a live-retrained PPO reinforcement learning model, real-time news sentiment scoring via Claude AI, and multi-timeframe market signals.

**Live dashboard:** [arminherabit.github.io/btc-swing-bot](https://arminherabit.github.io/btc-swing-bot)

---

## Architecture

```
Every hour (GitHub Actions cron)
        │
        ▼
┌─────────────────────────┐
│  btc_rl_inference.py    │  ← Python: fetch 220 candles + F&G + funding rate
│  (RL Pre-signal)        │    run PPO model 30× → confidence score
│                         │    write rl_signal.json (action, confidence, RSI, price)
└────────────┬────────────┘
             │ rl_signal.json
             ▼
┌─────────────────────────┐
│  btc_bot.ps1            │  ← PowerShell: fetch live data, compute all signals,
│  (Run swing bot)        │    apply entry/exit rules, read RL signal,
│                         │    execute trades via Binance.US API
└────────────┬────────────┘
             │ btc_state.json + trade_log.jsonl
             ▼
┌─────────────────────────┐
│  Pages deploy           │  ← Dashboard updated at github.io
└─────────────────────────┘

Every night 03:00 UTC
┌─────────────────────────┐
│  btc_rl_train.py        │  ← Fetch price + real F&G + funding rate history
│  (Nightly RL Retrain)   │    walk-forward validation (3 folds)
│                         │    retrain PPO 2M steps, commit new model if passes
└─────────────────────────┘

Every day 10:00 UTC
┌─────────────────────────┐
│  btc_logic_audit.py     │  ← Scan source for 10 known bug patterns,
│  (Daily Logic Audit)    │    auto-commit fixes
└─────────────────────────┘

Every Monday 08:00 UTC
┌─────────────────────────┐
│  btc_rl_health.py       │  ← Check model win rate / alpha / drift week-over-week
│  (Weekly RL Health)     │    write rl_health_report.json
└─────────────────────────┘
```

---

## Market Modes

Mode is set each cycle from price vs 4H SMA200:

| Mode | Condition | RSI Gates (base) | Dip Required | Max Tranches | Trail Stop |
|------|-----------|-----------------|--------------|--------------|------------|
| **BULL** | Price > SMA200 | T1≤42, T2≤36, T3≤30 | ≥1.5% | 3 | 3% from peak |
| **NEAR-SMA** | 0–3% below SMA200 | T1≤42, T2≤36, T3≤30 | ≥2.0% | 2 | 7% from peak |
| **BEAR** | >3% below SMA200 | T1≤40, T2≤34, T3≤28 | ≥3.0% | 2 | 7% from peak |

> RSI gates shown are base values. All are raised by the Aggressiveness Factor (see below).
> NEAR-SMA uses BULL RSI gates but BEAR safety caps — catches breakout setups near SMA200 reclaim.
> BEAR offset is 2 points (BULL gate − 2).

---

## Signals Collected Every Cycle

| Signal | Source | Used For |
|--------|--------|---------|
| BTC price | Binance.US spot `/ticker/price` | All calculations |
| 4H OHLCV (210 candles) | Binance.US `/klines` | RSI, SMA200, dip%, ATR, divergence |
| RSI 4H (Wilder, 14-period) | Computed from candles | Entry/exit gates |
| SMA200 4H | Computed from candles | Mode determination |
| 5-day high / dip % | Computed from last 30 candles | Entry dip gate |
| ATR % (24h, 6 × 4H candles) | Computed | Position sizing scalar |
| Fear & Greed Index | alternative.me API | AF, entry block/boost |
| News sentiment (−10 to +10) | Claude AI (cached 4h) | AF, entry block/boost |
| Funding rate (annualised %) | Binance Futures `/premiumIndex` | AF adjustment |
| Daily SMA50 gap % | Binance.US 1D candles (52) | AF adjustment |
| Bullish RSI divergence | Computed from RSI series + closes | Entry gate relaxation |
| RSI direction (turning up?) | Last 3 bars of RSI series | T2/T3 BEAR confirmation |

---

## Entry Logic

```
Step 1 — Check blockers (any one blocks all entries):
    ├── Fear & Greed ≥ 80 (Extreme Greed) — never bypassed
    ├── News score ≤ −7 (strongly bearish)
    │     EXCEPTION: if F&G ≤ 15 (Extreme Fear), news block is LIFTED entirely
    │     Rationale: at extreme fear, bad news is already priced in
    └── Within 8h of last stop-out (cooldown)

Step 2 — Check entry conditions (all must be true):
    ├── RSI 4H ≤ threshold for next tranche (T1/T2/T3, adjusted upward by AF)
    ├── 5-day dip % ≥ required for mode (reduced by 0.5% when AF ≥ 0.30)
    ├── Tranche count < max for mode (2 BEAR/NEAR-SMA, 3 BULL)
    └── Turning confirmation:
          T1: ALWAYS OK — no turning check (allows entry at actual bottom)
          T2/T3 BEAR: RSI must be turning up (higher low in last 2 bars)
                      OR bullish divergence detected
          BULL/NEAR-SMA: no turning check needed

Step 3 — Boosted conditions (relax T1 dip check):
    ├── F&G boost active (≤25) → dip requirement waived for T1
    ├── News boost active (≥6) → dip requirement waived for T1
    └── Bullish divergence → dip waived + RSI gate +5pts for T1

Step 4 — Volatility-adjusted position sizing:
    ATR% < 0.4%  → tranche × 1.20  (calm market, size up)
    ATR% < 0.8%  → tranche × 1.05
    ATR% < 1.2%  → tranche × 1.00  (baseline)
    ATR% < 1.8%  → tranche × 0.85
    ATR% ≥ 1.8%  → tranche × 0.70  (volatile, size down)
    AF ≥ 0.35    → additional × 1.15 (HIGH conviction bonus)
    AF ≥ 0.20    → additional × 1.08
    Final tranche capped: $100–$300

Entry reason logged: RSI DIP / DIVERGENCE / F&G FEAR BOOST / NEWS BOOST / RSI TURN
```

---

## Aggressiveness Factor (AF)

A single conviction score (−0.20 to +0.50) computed each cycle that dynamically adjusts all gates:

| Signal | Effect on AF |
|--------|-------------|
| BULL mode base | +0.15 |
| BEAR mode base | +0.05 |
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
| Funding rate > 100% ann. | −0.10 (crowded longs = bearish) |
| Funding rate > 50% ann. | −0.05 |
| Funding rate < −50% ann. | +0.10 (crowded shorts = squeeze fuel) |
| Funding rate < −20% ann. | +0.05 |
| Daily SMA50 gap > +5% | +0.05 (price above SMA50, trend aligned) |
| Daily SMA50 gap < −10% (normal conditions) | −0.05 (deep below SMA50, caution) |
| Daily SMA50 gap < −10% (F&G ≤ 15) | **+0.05** (inverted: extreme dip = mean-reversion buy) |
| Daily SMA50 gap < −15% (F&G ≤ 15) | **+0.10** (extreme dip + extreme fear = strong buy setup) |
| **Stale watchdog** | +0.10 (idle 48h+ AND F&G ≤30 AND no position AND not blocked) |

**Gate effect:** each +0.10 AF above 0.00 raises all RSI thresholds by 1 point. AF ≥ 0.30 also reduces dip requirement by 0.5%.

Labels: DEFENSIVE (<0.05) / LOW (0.05–0.20) / MEDIUM (0.20–0.35) / HIGH (≥0.35)

---

## Exit Logic

Checked every cycle while in position:

| Trigger | Condition | Mode | Action |
|---------|-----------|------|--------|
| **Partial profit** | Price ≥ avg entry +5% (after 6h min hold) | BULL | Sell 50% |
| **Partial profit** | Price ≥ avg entry +5% (after 6h min hold) | BEAR | Sell 50% |
| **RSI overbought** | RSI 4H ≥ 60 | BULL | Sell ALL |
| **RSI overbought** | RSI 4H ≥ 55 | BEAR | Sell ALL (bounces rarely reach 60) |
| **Trail stop** | Price drops 3% from peak (after 6h min hold) | BULL | Sell ALL + 8h cooldown |
| **Trail stop** | Price drops 7% from peak (after 6h min hold) | BEAR | Sell ALL + 8h cooldown |
| **Hard stop** | Price drops 5% from avg entry | Both | Sell ALL + 8h cooldown (immediate) |

> Hard stop fires immediately regardless of min hold period.
> Trail stop only becomes ACTIVE after the 6h min hold clears.
> Partial profit locks 50% gains; remaining half rides to RSI exit or trail stop.

---

## Reinforcement Learning Layer

### Model
- **Algorithm:** PPO (Proximal Policy Optimization) via stable-baselines3
- **Architecture:** MLP policy, net_arch [128, 128]
- **Training:** 2,000,000 timesteps on 14+ months of 4H OHLCV data
- **Retrain:** Nightly at 03:00 UTC using `trade_log.jsonl` + fresh price/F&G/funding-rate data
- **Validation:** Walk-forward across 3 expanding time folds before committing new model

### Observation space (18 features)
```
Index  Feature                Description
─────  ───────────────────    ──────────────────────────────────────────────
  0    rsi / 100              RSI 14-period Wilder, normalised 0–1
  1    price_vs_sma200        (price−SMA200)/SMA200, clipped ±40%
  2    price_vs_sma50_4h      (price−SMA50_4h)/SMA50_4h, clipped ±20%
  3    dip_pct / 10           5-day dip %, clipped 0–1
  4    vol_ratio / 3          volume vs 20-period avg, clipped 0–1
  5    fng / 100              Fear & Greed 0–1
  6    news_score_norm        (score+10)/20, clipped 0–1
  7    ret_4h                 1-candle return, clipped ±10%
  8    ret_24h                6-candle return, clipped ±20%
  9    ret_4d                 24-candle return, clipped ±30%
 10    in_position            0 or 1
 11    unrealized_pnl         (price−avg_entry)/avg_entry, clipped ±20%
 12    tranche_count / 3      0, 0.33, 0.67, 1.0
 13    hold_hours / 120       hours held / 120, clipped 0–1
 14    drawdown               (peak−price)/peak / 0.10, clipped 0–1
 15    partial_taken          0 or 1
 16    funding_rate_norm      annualised funding / 200%, clipped ±1
 17    daily_vs_sma50         (price−daily_SMA50)/daily_SMA50, clipped ±1
```

### Action space
`0=HOLD  1=BUY_TRANCHE  2=SELL_PARTIAL  3=SELL_ALL`

### RL Override rules

| Condition | Override granted |
|-----------|-----------------|
| Conf ≥ 60%, SELL_ALL, in position | SELL_ALL immediately |
| Conf ≥ 60%, SELL_PARTIAL, in position, partial not taken | SELL 50% |
| Conf ≥ 60%, BUY_TRANCHE, entry not blocked, RSI ≤ gate | BUY tranche |
| **Conf ≥ 85%, BUY_TRANCHE, not F&G-blocked** | BUY even if news-blocked + RSI gate +10pts |

> High-confidence news bypass: at 85%+ confidence, the model can act despite bearish news — this is the contrarian scenario where the edge is largest.
> F&G ≥ 80 block is NEVER bypassed.
> Tranche count < maxTranchesEff always enforced (2 BEAR, 3 BULL).

### RSI sanity check
Each cycle, bot RSI is compared against the RL inference RSI. If the gap exceeds 20 points, the bot falls back to the RL value and logs `[RSI SANITY]`. Guards against an intermittent PowerShell array-ordering edge case where the RSI Wilder loop returns anomalous values.

### Reward function (training)
```
reward = realized_pnl × (1 + aggressiveness)   ← primary: fired on trade close
       + step_pct × 0.3                         ← trend-following while holding
       − 0.3 × drawdown                         ← drawdown penalty
       − 0.00005                                ← tiny holding cost
       + entry quality bonus (RSI<35, dip≥1.5%) up to +0.015
       − entry penalty (RSI>65 → −0.025)
       + exit quality bonus (profit>6% → +0.010)
```

---

## News Sentiment (Claude AI)

Every 4 hours, `btc_news.ps1` calls the Anthropic API to score Bitcoin news −10 to +10 for the 1–7 day swing window. Cached in `btc_news_cache.json`.

| Score | Label | Effect |
|-------|-------|--------|
| ≥ 6 | Strongly bullish | AF +0.10, T1 dip requirement waived |
| 3–5 | Mildly bullish | AF +0.05 |
| −2 to +2 | Neutral | No adjustment |
| −3 to −6 | Mildly bearish | AF −0.05 |
| ≤ −7 | **Strongly bearish** | **Blocks all entries** (unless F&G ≤ 15) |

---

## Extreme Fear Override

When F&G ≤ 15, the news block is **completely disabled** regardless of score. At historic extreme fear readings, negative news is already priced in and contrarian entries have historically been among the best BTC buying opportunities. The F&G ≥ 80 (extreme greed) block is never lifted by any override.

---

## Stale Watchdog

Triggers when all of these are true simultaneously:
- No trade action in 48+ hours
- Fear & Greed ≤ 30
- Not currently in position
- Entry not blocked

→ AF receives +0.10 boost. Prevents permanent paralysis in extended low-volatility Extreme Fear markets.

---

## Range-Scalp Module (disabled by default)

Secondary micro-position layer for low-volatility sideways markets. Controlled by `scalp_enabled` in config.

When enabled:
- **Entry:** no main position, ATR% < 1%, RSI 40–58, 4h cooldown elapsed, entry not blocked
- **Take profit:** +1.5% | **Stop loss:** −1.0% | **Max hold:** 8h
- **Size:** `scalp_size_usdt` (default $50), fully independent of main tranches

---

## Full Cycle Flow (every hour)

```
1. btc_rl_inference.py
   ├── Fetch 220 × 4H candles (Binance.US)
   ├── Fetch Fear & Greed (alternative.me)
   ├── Fetch funding rate (Binance Futures premiumIndex)
   ├── Fetch 52 × 1D candles → compute daily SMA50 + gap%
   ├── Load btc_state.json for position context
   ├── Build 18-feature observation vector
   ├── Load btc_rl_model.zip (PPO weights)
   ├── Sample model 30× stochastically → action distribution + confidence
   ├── Get deterministic best action
   └── Write rl_signal.json
         { action, action_id, confidence, distribution,
           af, rsi, dip_pct, fng, price, override (true if conf≥0.60) }

2. btc_bot.ps1
   ├── Load btc_state.json + rl_signal.json
   ├── Fetch live BTC price
   ├── Fetch Fear & Greed
   │     └── fngBlock (≥80), fngBoost (≤25), extremeFear (≤15)
   ├── Score news via Claude AI (cached 4h)
   │     └── newsBlock (≤−7), newsBoost (≥6)
   │     └── EXTREME FEAR OVERRIDE: if F&G≤15, newsBlock=false
   ├── Fetch funding rate → fundingTag
   ├── Fetch daily SMA50 → dailyTag + gapPct
   ├── Compute entryBlocked = newsBlock OR fngBlock
   ├── Check stop-out cooldown (8h from last_stopout)
   ├── Fetch 210 × 4H candles
   │     ├── Compute closes[], RSI (Wilder 14-period)
   │     ├── RSI SANITY CHECK vs rl.rsi (>20pt → use RL value)
   │     ├── Compute RSI series → divergence detection, turning check
   │     ├── Compute SMA200 → mode (BULL/NEAR-SMA/BEAR)
   │     ├── Compute dip% from 5-day high
   │     └── Compute ATR% (6 × 4H candles)
   ├── Compute Aggressiveness Factor (all signals)
   ├── Apply stale watchdog (+0.10 if idle 48h+ AND F&G≤30)
   ├── Compute adaptive RSI gates: base ± AF ± bear_offset
   │     T1 = rsi_tranche1 − bear_offset + afRsiBonus
   │     T2 = rsi_tranche2 − bear_offset + afRsiBonus
   │     T3 = rsi_tranche3 − bear_offset + afRsiBonus
   │
   ├── RL OVERRIDE (if rl_signal.override = true):
   │     ├── SELL_ALL → execute immediately if in position
   │     ├── SELL_PARTIAL → execute if in position + partial not taken
   │     └── BUY_TRANCHE:
   │           Standard: not entryBlocked AND RSI ≤ gate AND tranches < max
   │           High-conf: conf≥85% AND not fngBlock
   │                      RSI ≤ gate+10, entryBlocked may be true
   │
   ├── EXIT CHECK (if in position):
   │     ├── Update highest_price (trailing peak)
   │     ├── Partial profit: price ≥ avg+5%, after 6h → sell 50%
   │     ├── RSI exit: RSI ≥ 55 BEAR / ≥ 60 BULL → sell ALL
   │     ├── Trail stop: price ≤ peak×(1−trailPct%), after 6h → sell ALL + cooldown
   │     └── Hard stop: price ≤ avg×0.95 → sell ALL + cooldown (immediate)
   │
   ├── ENTRY CHECK (if not entryBlocked):
   │     ├── Compute ATR-adjusted tranche size ($100–$300)
   │     ├── Determine turningOk:
   │     │     T1: always true
   │     │     T2/T3 BEAR: rsiTurning OR divergence
   │     │     BULL/NEAR-SMA: always true
   │     ├── dipOk: dipPct ≥ dipReq (waived for T1 on boost/divergence)
   │     ├── rsiOk: rsi4h ≤ threshold (gate +5pts on divergence for T1)
   │     └── If canAdd AND rsiOk AND dipOk AND turningOk → BUY tranche
   │
   ├── SCALP MODULE (if scalp_enabled=true):
   │     ├── Exit: TP/SL/timeout on active scalp position
   │     └── Entry: ATR<1%, RSI 40–58, cooldown elapsed, not blocked
   │
   ├── Stamp last_action_time on any real trade
   ├── Update all telemetry in btc_state.json
   ├── git add + commit btc_state.json (+ btc_news_cache.json)
   └── Send SMS via Twilio
```

---

## Files

| File | Purpose |
|------|---------|
| `btc_bot.ps1` | Main trading engine (PowerShell) |
| `btc_news.ps1` | Claude AI news sentiment scorer |
| `btc_rl_inference.py` | Live PPO inference → `rl_signal.json` |
| `btc_rl_train.py` | Nightly PPO retrainer with walk-forward validation |
| `btc_rl_env.py` | Gymnasium trading environment (18-feature obs space) |
| `btc_rl_review.py` | Trade log stats (runs before retrain) |
| `btc_logic_audit.py` | Daily automated bug scanner / auto-fixer (10 checks) |
| `btc_rl_health.py` | Weekly model health check / drift detection |
| `btc_config.json` | All tunable parameters |
| `btc_state.json` | Live bot state (position, RSI, signals, telemetry) |
| `trade_log.jsonl` | Every closed trade with full context |
| `rl_signal.json` | Current RL action, confidence, RSI, distribution |
| `btc_rl_model.zip` | Trained PPO weights |
| `btc_rl_stats.json` | Last retrain backtest + walk-forward results |
| `rl_health_report.json` | Weekly health check output |
| `btc_news_cache.json` | Cached news sentiment (4h TTL) |

---

## Configuration (`btc_config.json`)

```json
{
  "paper_trading":            false,
  "tranche_size_usdt":        167,
  "max_tranches":             3,

  "rsi_tranche1":             42,
  "rsi_tranche2":             36,
  "rsi_tranche3":             30,
  "rsi_exit":                 60,
  "rsi_exit_bear":            55,
  "rsi_bear_offset":          2,

  "dip_pct_required":         1.5,
  "dip_pct_bear":             3.0,
  "trailing_stop_pct":        3.0,
  "trailing_stop_pct_bear":   7.0,
  "hard_stop_pct":            5.0,
  "min_hold_hours":           6,

  "partial_profit_pct":       5.0,
  "partial_profit_pct_bear":  5.0,
  "partial_profit_size":      0.5,

  "fng_block_threshold":      80,
  "fng_boost_threshold":      25,

  "news_cache_hours":         4,
  "news_skip_threshold":     -7,
  "news_boost_threshold":     6,

  "scalp_enabled":            false,
  "scalp_size_usdt":          50,
  "scalp_take_profit_pct":    1.5,
  "scalp_stop_pct":           1.0,
  "scalp_atr_max_pct":        1.0,
  "scalp_cooldown_hours":     4,
  "scalp_max_hold_hours":     8
}
```

---

## GitHub Actions Workflows

| Workflow | Schedule | Description |
|----------|----------|-------------|
| `bot.yml` | Every hour | Live trading cycle |
| `rl-retrain.yml` | Daily 03:00 UTC | PPO model retrain + walk-forward validation |
| `logic-audit.yml` | Daily 10:00 UTC | Auto bug detection + fix (10 checks) |
| `rl-health.yml` | Monday 08:00 UTC | Model drift / win-rate check |

---

## Current Model Performance (last retrain)

| Metric | Value |
|--------|-------|
| Trained at | 2026-06-07 |
| Timesteps | 2,000,000 |
| Observation features | 18 |
| Validation return | −6.84% |
| Buy-and-hold (same period) | −10.73% |
| Alpha vs BaH | **+3.89%** |
| Win rate | 66.7% |
| N trades (validation) | 3 |
| Walk-forward fold 2 alpha | +22.63% |

---

## Required Secrets

| Secret | Description |
|--------|-------------|
| `BINANCE_API_KEY` | Binance.US API key (spot trading) |
| `BINANCE_API_SECRET` | Binance.US API secret |
| `ANTHROPIC_API_KEY` | Claude AI API key (news scoring) |
| `TWILIO_ACCOUNT_SID` | Twilio account SID (SMS alerts) |
| `TWILIO_AUTH_TOKEN` | Twilio auth token |
| `TWILIO_FROM` | Twilio phone number (sender) |
| `TWILIO_TO` | Your phone number (recipient) |

---

## How It Learns

1. Every closed trade is appended to `trade_log.jsonl` with full context: price, RSI, mode, F&G, news score, AF, exit reason, PnL%
2. At 03:00 UTC, `btc_rl_train.py` fetches fresh 4H OHLCV + real Fear & Greed history + funding rate history
3. Walk-forward validation runs across 3 expanding time folds — poor generalisation triggers a warning
4. PPO retrains for 2,000,000 timesteps on the full dataset
5. Final backtest runs on held-out validation candles — if model file changes, it is committed (`[skip ci]`)
6. Next hourly run automatically picks up the new `btc_rl_model.zip`

As real trade outcomes accumulate, the model receives live PnL feedback and improves its timing. The 18-feature observation space (including funding rate and daily SMA50 gap) provides significantly richer context than the original 16-feature version.

---

## Change Log

| Date | Change |
|------|--------|
| 2026-05-29 | Added funding rate + daily SMA50 to AF and RL obs space (18 features) |
| 2026-05-29 | Added walk-forward validation to nightly retrain |
| 2026-05-29 | ATR-adjusted position sizing ($100–$300 per tranche) |
| 2026-05-29 | Fixed: RSI inference window (30 candles → full 220) |
| 2026-05-29 | Fixed: synthetic F&G in training replaced with real alternative.me data |
| 2026-06-09 | Extreme fear override: F&G ≤ 15 lifts news block entirely |
| 2026-06-09 | News block threshold: −5 → −7 |
| 2026-06-09 | BEAR RSI offset: 7 → 2 (T1 gate 35 → 40) |
| 2026-06-09 | RL ≥85% confidence bypasses news block (RSI gate +10pts) |
| 2026-06-09 | T1 entry: removed RSI-turning confirmation requirement |
| 2026-06-09 | BEAR trail stop: 4.5% → 7% |
| 2026-06-09 | BEAR RSI exit: 60 → 55 |
| 2026-06-09 | RSI sanity check vs RL inference (>20pt gap → fallback to RL value) |
| 2026-06-09 | Daily SMA50 gap AF: inverted in extreme fear (deep dip = buy signal) |
| 2026-06-10 | BEAR partial profit target: 3% → 5% (swing capture, not dead-cat) |
| 2026-06-10 | Min hold hours: 12h → 6h |
