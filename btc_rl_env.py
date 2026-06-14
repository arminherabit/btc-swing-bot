"""
BTC Aggressive Trading Environment for PPO
==========================================
reward = portfolio_return * (1 + aggressiveness) - 0.3 * max_drawdown - tx_costs

Actions:  0=HOLD  1=BUY_TRANCHE  2=SELL_PARTIAL(50%)  3=SELL_ALL
Features: 16 normalized floats per step
"""

import numpy as np
import pandas as pd
import gymnasium as gym
from gymnasium import spaces


# ── Action constants ──────────────────────────────────────────────────────────
HOLD         = 0
BUY_TRANCHE  = 1
SELL_PARTIAL = 2
SELL_ALL     = 3


class BTCTradingEnv(gym.Env):
    metadata = {"render_modes": ["human"]}

    def __init__(
        self,
        df,                          # DataFrame with OHLCV + indicators
        aggressiveness: float = 1.5, # amplifier on portfolio_return
        initial_capital: float = 500.0,
        tranche_size:    float = 167.0,
        max_tranches:    int   = 3,
        tx_fee:          float = 0.001,   # real Binance.US taker fee
        min_hold_steps:  int   = 3,       # must hold ≥3 steps (12h) before selling
        window:          int   = 1,       # set >1 for stacked-frame obs
    ):
        super().__init__()
        self.df             = df.reset_index(drop=True)
        self.aggressiveness = aggressiveness
        self.initial_capital = initial_capital
        self.tranche_size   = tranche_size
        self.max_tranches   = max_tranches
        self.tx_fee         = tx_fee
        self.min_hold_steps = min_hold_steps
        self.window         = window

        n_features = 18   # +2: funding_rate_norm, daily_vs_sma50
        self.action_space      = spaces.Discrete(4)
        self.observation_space = spaces.Box(
            low=-np.inf, high=np.inf,
            shape=(n_features * window,),
            dtype=np.float32,
        )

        self._reset_state()

    # ── Internal helpers ──────────────────────────────────────────────────────

    def _reset_state(self):
        self.in_position   = False
        self.tranche_count = 0
        self.avg_entry     = 0.0
        self.total_qty     = 0.0
        self.total_cost    = 0.0
        self.peak_price    = 0.0
        self.entry_step    = 0
        self.partial_taken      = False
        self.cash               = self.initial_capital
        self.trades             = []
        self.episode_reward     = 0.0
        self._last_realized_pnl = 0.0

    def _price(self, step=None):
        idx = step if step is not None else self.current_step
        return float(self.df.iloc[idx]["close"])

    def _features(self, idx: int) -> np.ndarray:
        """16 normalized features for one timestep."""
        row   = self.df.iloc[idx]
        price = float(row["close"])

        # ── Price momentum ──────────────────────────────────────────────────
        p1  = float(self.df.iloc[max(0, idx - 1)]["close"])
        p6  = float(self.df.iloc[max(0, idx - 6)]["close"])
        p24 = float(self.df.iloc[max(0, idx - 24)]["close"])
        ret4h  = np.clip((price - p1)  / p1,  -0.10, 0.10) / 0.10
        ret24h = np.clip((price - p6)  / p6,  -0.20, 0.20) / 0.20
        ret4d  = np.clip((price - p24) / p24, -0.30, 0.30) / 0.30

        # ── Technical indicators ─────────────────────────────────────────────
        rsi     = float(row.get("rsi", 50.0)) / 100.0
        sma200  = float(row.get("sma200", price))
        sma50   = float(row.get("sma50",  price))
        vs200   = np.clip((price - sma200) / sma200, -0.4, 0.4) / 0.4
        vs50    = np.clip((price - sma50)  / sma50,  -0.2, 0.2) / 0.2
        dip_pct = np.clip(float(row.get("dip_pct", 0.0)) / 10.0, 0.0, 1.0)
        vol_r   = np.clip(float(row.get("vol_ratio", 1.0)) / 3.0, 0.0, 1.0)

        # ── External signals ────────────────────────────────────────────────
        fng     = float(row.get("fng", 50.0)) / 100.0
        news    = np.clip((float(row.get("news_score", 0.0)) + 10.0) / 20.0, 0.0, 1.0)

        # ── Funding rate (annualised %, clipped ±200%) ─────────────────────
        funding_norm = np.clip(float(row.get("funding_rate_annual", 0.0)) / 200.0, -1.0, 1.0)

        # ── Daily SMA50 gap (price vs SMA50, clipped ±20%) ─────────────────
        daily_vs_sma50 = np.clip(float(row.get("daily_vs_sma50", 0.0)), -1.0, 1.0)

        # ── Position state ──────────────────────────────────────────────────
        in_pos  = float(self.in_position)
        upnl    = 0.0
        if self.in_position and self.avg_entry > 0:
            upnl = np.clip((price - self.avg_entry) / self.avg_entry, -0.20, 0.20) / 0.20
        tc_norm = self.tranche_count / float(self.max_tranches)
        hold_h  = 0.0
        if self.in_position and self.entry_step > 0:
            hold_h = np.clip((idx - self.entry_step) * 4 / 120.0, 0.0, 1.0)  # 4h candles
        drawdown = 0.0
        if self.in_position and self.peak_price > 0 and price < self.peak_price:
            drawdown = np.clip((self.peak_price - price) / self.peak_price / 0.10, 0.0, 1.0)

        return np.array([
            rsi, vs200, vs50, dip_pct, vol_r,   # market structure  (5)
            fng, news,                           # sentiment         (2)
            ret4h, ret24h, ret4d,               # momentum          (3)
            in_pos, upnl, tc_norm,              # position state    (3)
            hold_h, drawdown,                   # risk state        (2)
            float(self.partial_taken),          # partial flag      (1)
            funding_norm,                       # funding rate      (1) NEW
            daily_vs_sma50,                     # daily SMA50 gap   (1) NEW
        ], dtype=np.float32)

    def _get_obs(self) -> np.ndarray:
        if self.window == 1:
            return self._features(self.current_step)
        frames = [
            self._features(max(0, self.current_step - i))
            for i in range(self.window - 1, -1, -1)
        ]
        return np.concatenate(frames)

    # ── Reward ─────────────────────────────────────────────────────────────

    def _reward(self, action: int, realized_pnl: float = 0.0) -> float:
        """
        Realized P&L is the PRIMARY signal — passed in from step() when a
        trade closes.  All other shaping is light secondary guidance.
        """
        idx   = self.current_step
        price = self._price(idx)
        row   = self.df.iloc[idx]
        rsi   = float(row.get("rsi",     50.0))
        dip   = float(row.get("dip_pct",  0.0))
        fng   = float(row.get("fng",     50.0))

        # ── 1. Realized P&L on trade close (primary signal) ────────────────
        reward = realized_pnl * (1.0 + self.aggressiveness)

        # ── 2. Small per-step delta while in position ───────────────────────
        if self.in_position and self.total_qty > 0:
            prev_price = float(self.df.iloc[max(0, idx - 1)]["close"])
            step_pct   = (price - prev_price) / max(prev_price, 1.0)
            reward    += step_pct * 0.3            # gentle trend-following

            # Drawdown penalty
            if self.peak_price > 0 and price < self.peak_price:
                dd      = (self.peak_price - price) / self.peak_price
                reward -= 0.3 * dd

            # Tiny holding cost — avoids infinite hold
            reward -= 0.00005

        # ── 3. Entry quality shaping ────────────────────────────────────────
        if action == BUY_TRANCHE:
            if rsi < 35 and dip >= 1.5:
                reward += 0.005
            if rsi < 25:
                reward += 0.010
            if rsi > 65:
                reward -= 0.025           # hard penalty — don't buy tops
            if rsi > 55 and dip < 1.0:
                reward -= 0.010
            if fng >= 75:
                reward -= 0.010

        # ── 4. Exit quality shaping (on top of realized P&L) ───────────────
        elif action == SELL_ALL:
            if self.in_position and self.avg_entry > 0:
                ret      = (price - self.avg_entry) / self.avg_entry
                prev_rsi = float(self.df.iloc[max(0, idx - 1)].get("rsi", rsi))
                rsi_rising = rsi > prev_rsi
                if ret > 0.06:
                    reward += 0.010       # extra bonus for excellent exit
                if ret < -0.05:
                    reward += 0.005       # cutting a big loss = ok
                # Penalise selling into strength: bailing at a small gain while RSI is
                # still rising and not yet overbought == exiting the START of a swing.
                if 0.0 < ret < 0.04 and rsi < 65 and rsi_rising:
                    reward -= 0.015       # "you sold too early on the upside"
                # Win-rate pressure: book green closes, discourage red closes (on top of
                # raw P&L). Biases the policy toward setups that actually close positive.
                if ret > 0.0:
                    reward += 0.008
                else:
                    reward -= 0.008

        elif action == SELL_PARTIAL:
            if self.in_position and self.avg_entry > 0:
                ret = (price - self.avg_entry) / self.avg_entry
                if ret > 0.04:
                    reward += 0.008
                elif ret < 0.01:
                    reward -= 0.005

        # ── 5. Penalise obvious mistakes while holding ──────────────────────
        elif action == HOLD and self.in_position:
            if self.peak_price > 0 and price < self.peak_price:
                dd = (self.peak_price - price) / self.peak_price
                if dd > 0.08:
                    reward -= 0.012
                elif dd > 0.05:
                    reward -= 0.006
            if self.avg_entry > 0:
                ret      = (price - self.avg_entry) / self.avg_entry
                prev_rsi = float(self.df.iloc[max(0, idx - 1)].get("rsi", rsi))
                # Reward patience: holding a profitable position while the up-move is
                # still building (RSI rising, not yet overbought) == let the winner run.
                if ret > 0.01 and rsi < 68 and rsi > prev_rsi:
                    reward += 0.006
                # But still punish overstaying a clearly exhausted, extended position.
                if ret > 0.10 and rsi > 70:
                    reward -= 0.010

        return float(reward)

    # ── Gym interface ──────────────────────────────────────────────────────

    def reset(self, seed=None, options=None):
        super().reset(seed=seed)
        self._reset_state()
        # Random start point with enough history
        min_step = max(self.window + 24, 50)
        max_step = len(self.df) - 250
        if options and "start" in options:
            self.current_step = int(options["start"])
        else:
            self.current_step = int(np.random.randint(min_step, max(min_step + 1, max_step)))
        return self._get_obs(), {}

    def step(self, action: int):
        idx   = self.current_step
        price = self._price(idx)

        # Update trailing peak
        if self.in_position and price > self.peak_price:
            self.peak_price = price

        # ── Execute action ──────────────────────────────────────────────────
        if action == BUY_TRANCHE:
            if self.tranche_count < self.max_tranches and self.cash >= self.tranche_size:
                cost             = self.tranche_size * (1.0 + self.tx_fee)
                qty              = self.tranche_size / price
                self.total_qty   += qty
                self.total_cost  += cost
                self.avg_entry   = self.total_cost / self.total_qty
                self.tranche_count += 1
                self.cash        -= cost
                if not self.in_position:
                    self.in_position = True
                    self.entry_step  = idx
                    self.peak_price  = price

        elif action == SELL_PARTIAL:
            # Enforce minimum hold period
            held = idx - self.entry_step if self.in_position else 0
            if self.in_position and not self.partial_taken and self.total_qty > 0 \
                    and held >= self.min_hold_steps:
                sell_qty        = self.total_qty * 0.5
                proceeds        = sell_qty * price * (1.0 - self.tx_fee)
                self.cash       += proceeds
                self.total_qty  -= sell_qty
                self.total_cost *= 0.5
                self.partial_taken = True

        elif action == SELL_ALL:
            held = idx - self.entry_step if self.in_position else 0
            if self.in_position and self.total_qty > 0 and held >= self.min_hold_steps:
                proceeds  = self.total_qty * price * (1.0 - self.tx_fee)
                pnl       = proceeds - self.total_cost
                self.cash += proceeds
                self.trades.append({
                    "entry_price": self.avg_entry,
                    "exit_price":  price,
                    "pnl":         pnl,
                    "return_pct":  pnl / self.total_cost * 100,
                    "steps_held":  idx - self.entry_step,
                })
                self._last_realized_pnl = pnl / max(self.total_cost, 1.0)
                self.total_qty     = 0.0
                self.total_cost    = 0.0
                self.avg_entry     = 0.0
                self.tranche_count = 0
                self.in_position   = False
                self.partial_taken = False
                self.peak_price    = 0.0

        # Compute reward BEFORE advancing step — pass realized PnL if trade just closed
        realized = getattr(self, "_last_realized_pnl", 0.0)
        self._last_realized_pnl = 0.0
        reward = self._reward(action, realized_pnl=realized)
        self.episode_reward += reward

        # ── Advance ─────────────────────────────────────────────────────────
        self.current_step += 1
        done = self.current_step >= len(self.df) - 1 or self.cash <= 50

        # Liquidate at episode end
        if done and self.in_position and self.total_qty > 0:
            end_price  = self._price(self.current_step)
            self.cash += self.total_qty * end_price * (1.0 - self.tx_fee)
            self.total_qty = 0.0
            self.in_position = False

        portfolio_val = self.cash + (self.total_qty * price if self.in_position else 0)
        info = {
            "portfolio_value": portfolio_val,
            "total_return":    (portfolio_val - self.initial_capital) / self.initial_capital,
            "n_trades":        len(self.trades),
            "episode_reward":  self.episode_reward,
        }
        return self._get_obs(), reward, done, False, info

    def render(self, mode="human"):
        price = self._price()
        pv    = self.cash + (self.total_qty * price if self.in_position else 0)
        ret   = (pv - self.initial_capital) / self.initial_capital * 100
        print(
            f"Step {self.current_step:5d} | "
            f"BTC ${price:>10,.2f} | "
            f"Portfolio ${pv:>8,.2f} | "
            f"PnL {ret:+.2f}% | "
            f"Trades {len(self.trades):3d} | "
            f"{'IN[' + str(self.tranche_count) + '/3]' if self.in_position else 'WATCH'}"
        )
