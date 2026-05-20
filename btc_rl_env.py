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
        tx_fee:          float = 0.001,   # 0.1% per leg (Binance.US taker)
        window:          int   = 1,       # set >1 for stacked-frame obs
    ):
        super().__init__()
        self.df             = df.reset_index(drop=True)
        self.aggressiveness = aggressiveness
        self.initial_capital = initial_capital
        self.tranche_size   = tranche_size
        self.max_tranches   = max_tranches
        self.tx_fee         = tx_fee
        self.window         = window

        n_features = 16
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
        self.partial_taken = False
        self.cash          = self.initial_capital
        self.trades        = []
        self.episode_reward = 0.0

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

    def _reward(self, action: int) -> float:
        price = self._price()
        portfolio_return = 0.0
        max_drawdown     = 0.0
        tx_costs         = 0.0

        if self.in_position and self.avg_entry > 0:
            portfolio_return = (price - self.avg_entry) / self.avg_entry
            if self.peak_price > 0 and price < self.peak_price:
                max_drawdown = (self.peak_price - price) / self.peak_price
            tx_costs = self.tx_fee * 2.0 * self.tranche_count

        # ── Core formula ───────────────────────────────────────────────────
        #   reward = portfolio_return * (1 + aggressiveness)
        #          - 0.3 * max_drawdown
        #          - transaction_costs
        reward = (
            portfolio_return * (1.0 + self.aggressiveness)
            - 0.3 * max_drawdown
            - tx_costs
        )

        # ── Action quality shaping ─────────────────────────────────────────
        row = self.df.iloc[self.current_step]
        rsi = float(row.get("rsi", 50.0))
        dip = float(row.get("dip_pct", 0.0))
        fng = float(row.get("fng", 50.0))

        if action == BUY_TRANCHE:
            if rsi < 35 and dip >= 1.5:
                reward += 0.003           # buying the dip = bonus
            if rsi < 25:
                reward += 0.005           # capitulation buy = extra bonus
            if rsi > 65:
                reward -= 0.008           # buying overbought = hard penalty
            if fng >= 80:
                reward -= 0.005           # buying extreme greed = penalty

        elif action == SELL_ALL:
            if portfolio_return > 0.05:
                reward += 0.006           # strong profit exit = bonus
            elif portfolio_return > 0.02:
                reward += 0.002
            if max_drawdown > 0.06:
                reward += 0.003           # cutting a deep loss = also rewarded

        elif action == SELL_PARTIAL:
            if portfolio_return > 0.04:
                reward += 0.004           # locking gains = bonus
            elif portfolio_return < 0.01:
                reward -= 0.002           # partial sell before profit = small penalty

        elif action == HOLD:
            if self.in_position and max_drawdown > 0.06:
                reward -= 0.003           # holding through big drawdown = penalty
            if self.in_position and portfolio_return > 0.08 and rsi > 65:
                reward -= 0.002           # not selling an obvious top = penalty

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
            if self.in_position and not self.partial_taken and self.total_qty > 0:
                sell_qty        = self.total_qty * 0.5
                proceeds        = sell_qty * price * (1.0 - self.tx_fee)
                self.cash       += proceeds
                self.total_qty  -= sell_qty
                self.total_cost *= 0.5
                self.partial_taken = True

        elif action == SELL_ALL:
            if self.in_position and self.total_qty > 0:
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
                self.total_qty     = 0.0
                self.total_cost    = 0.0
                self.avg_entry     = 0.0
                self.tranche_count = 0
                self.in_position   = False
                self.partial_taken = False
                self.peak_price    = 0.0

        # Compute reward BEFORE advancing step
        reward = self._reward(action)
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
