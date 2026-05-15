# Alpaca Live Dashboard -- refreshes every 10 seconds
# Shows: account, open positions, P&L, pending approvals, open orders.
# Run: .\alpaca_dashboard.ps1

. (Join-Path $PSScriptRoot "alpaca_client.ps1")

$RefreshSec  = 10
$StatePath   = Join-Path $PSScriptRoot "alpaca_state.json"
$PendingPath = Join-Path $PSScriptRoot "pending_approval.json"

function Load-State {
    if (Test-Path $StatePath) {
        try { return Get-Content $StatePath | ConvertFrom-Json } catch {}
    }
    return [pscustomobject]@{ trades_today=0; wins=0; losses=0; pnl_today=0.0; last_scan="" }
}

function Load-Pending {
    if (Test-Path $PendingPath) {
        try { return @(Get-Content $PendingPath | ConvertFrom-Json) } catch {}
    }
    return @()
}

function Write-Header([string]$title, [int]$width = 72) {
    $pad = "─" * (($width - $title.Length - 4) / 2)
    Write-Host ("┌{0} {1} {0}┐" -f $pad, $title) -ForegroundColor Cyan
}

function Write-Footer([int]$width = 72) {
    Write-Host ("└" + "─" * ($width - 2) + "┘") -ForegroundColor Cyan
}

function Write-Row([string]$label, [string]$value, [string]$color = "White") {
    Write-Host ("│  {0,-24} {1,-44}│" -f $label, $value) -ForegroundColor $color
}

function Write-Divider([int]$width = 72) {
    Write-Host ("├" + "─" * ($width - 2) + "┤") -ForegroundColor DarkCyan
}

function Write-Blank([int]$width = 72) {
    Write-Host ("│" + " " * ($width - 2) + "│") -ForegroundColor Cyan
}

function Render-Dashboard($cfg) {
    Clear-Host

    $now    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $state  = Load-State
    $pending = Load-Pending

    # ── Header ─────────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Header "  ALPACA DAY TRADER  "
    Write-Row "Time (local)"  $now
    Write-Row "Mode"          (if ($cfg.paper_trading) { "PAPER TRADING" } else { "LIVE TRADING" }) `
                              (if ($cfg.paper_trading) { "Yellow" } else { "Red" })
    Write-Divider

    # ── Account ────────────────────────────────────────────────────────────────
    $acct = Get-Account $cfg
    if ($null -ne $acct) {
        $equity   = [double]$acct.equity
        $cash     = [double]$acct.cash
        $bp       = [double]$acct.buying_power
        $dayPnl   = [double]$acct.equity - [double]$acct.last_equity
        $dayPnlPct = if ([double]$acct.last_equity -gt 0) { ($dayPnl / [double]$acct.last_equity) * 100 } else { 0 }
        $pnlColor  = if ($dayPnl -ge 0) { "Green" } else { "Red" }

        Write-Row "Equity"         ("`${0:N2}" -f $equity)
        Write-Row "Cash"           ("`${0:N2}" -f $cash)
        Write-Row "Buying Power"   ("`${0:N2}" -f $bp)
        Write-Row "Day P&L"        ("`${0:F2}  ({1:F2}%)" -f $dayPnl, $dayPnlPct) $pnlColor
        Write-Row "Pattern Day Trader" (if ($acct.pattern_day_trader) { "YES" } else { "No" }) `
                                      (if ($acct.pattern_day_trader) { "Red" } else { "Green" })
    } else {
        Write-Row "Account" "ERROR -- cannot reach Alpaca API" "Red"
    }
    Write-Divider

    # ── Session Stats ──────────────────────────────────────────────────────────
    Write-Row "Trades Today"  $state.trades_today.ToString()
    Write-Row "W / L"         ("{0} / {1}" -f $state.wins, $state.losses)
    $lastScan = if ($state.last_scan -ne "") {
        try { ([datetime]$state.last_scan).ToLocalTime().ToString("HH:mm:ss") } catch { $state.last_scan }
    } else { "--" }
    Write-Row "Last Scan"     $lastScan
    Write-Divider

    # ── Open Positions ─────────────────────────────────────────────────────────
    $positions = Get-Positions $cfg
    Write-Row "Open Positions" ("{0} / {1}" -f $positions.Count, $cfg.max_positions)
    Write-Blank
    if ($positions.Count -gt 0) {
        Write-Host ("│    {0,-6} {1,6} {2,10} {3,10} {4,10} {5,12}│" -f `
            "Symbol", "Qty", "Entry", "Current", "P&L", "P&L%") -ForegroundColor DarkGray
        foreach ($p in $positions) {
            $pnl    = [double]$p.unrealized_pl
            $pnlPct = [double]$p.unrealized_plpc * 100
            $color  = if ($pnl -ge 0) { "Green" } else { "Red" }
            Write-Host ("│    {0,-6} {1,6} {2,10:F2} {3,10:F2} {4,10:F2} {5,11:F2}%│" -f `
                $p.symbol, $p.qty, [double]$p.avg_entry_price, [double]$p.current_price, `
                $pnl, $pnlPct) -ForegroundColor $color
        }
    } else {
        Write-Host "│    No open positions                                                 │" -ForegroundColor DarkGray
    }
    Write-Blank
    Write-Divider

    # ── Open Orders ────────────────────────────────────────────────────────────
    $orders = Get-Orders $cfg "open"
    Write-Row "Open Orders" $orders.Count.ToString()
    if ($orders.Count -gt 0) {
        Write-Blank
        foreach ($o in $orders) {
            $typeStr = ("{0} {1} {2}" -f $o.side.ToUpper(), $o.qty, $o.type.ToUpper())
            Write-Host ("│    {0,-6}  {1,-28} {2,-16}│" -f $o.symbol, $typeStr, $o.status) -ForegroundColor DarkYellow
        }
    }
    Write-Divider

    # ── Pending Approvals ──────────────────────────────────────────────────────
    Write-Row "Pending Approvals" $pending.Count.ToString() (if ($pending.Count -gt 0) { "Yellow" } else { "White" })
    if ($pending.Count -gt 0) {
        Write-Blank
        foreach ($t in $pending) {
            Write-Host ("│  ► [{0}] {1,-6} {2} {3,4} shares  Entry=`${4:F2}  SL=`${5:F2}  TP=`${6:F2}  R:R 1:{7}│" -f `
                $t.id, $t.symbol, $t.side.ToUpper().PadRight(4), $t.shares, `
                $t.entry, $t.stop, $t.t1, $t.rr) -ForegroundColor Yellow
        }
        Write-Blank
        Write-Host "│  To approve all:  .\alpaca_bot.ps1 -Approve                          │" -ForegroundColor DarkYellow
        Write-Host "│  To approve one:  .\alpaca_bot.ps1 -ApproveId <id>                   │" -ForegroundColor DarkYellow
        Write-Host "│  To cancel all:   .\alpaca_bot.ps1 -Cancel                           │" -ForegroundColor DarkYellow
    }

    # ── Market Clock ──────────────────────────────────────────────────────────
    Write-Divider
    $clock = Get-MarketClock $cfg
    if ($null -ne $clock) {
        $statusStr = if ($clock.is_open) { "OPEN" } else { "CLOSED" }
        $nextStr   = try {
            $nt = [datetime]$clock.next_open
            "Next open: " + $nt.ToLocalTime().ToString("ddd MM/dd HH:mm")
        } catch { "" }
        $clockColor = if ($clock.is_open) { "Green" } else { "DarkGray" }
        Write-Row "Market Status" ("{0}  {1}" -f $statusStr, $nextStr) $clockColor
    }

    Write-Footer
    Write-Host ("  Refreshing every {0}s  |  Ctrl+C to exit" -f $RefreshSec) -ForegroundColor DarkGray
    Write-Host ""
}

# ── Run ────────────────────────────────────────────────────────────────────────

$cfg = Load-AlpacaConfig

Write-Host "  Starting Alpaca dashboard..." -ForegroundColor Cyan

while ($true) {
    try {
        Render-Dashboard $cfg
    } catch {
        Write-Host ("  [DASHBOARD ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Start-Sleep -Seconds $RefreshSec
}
