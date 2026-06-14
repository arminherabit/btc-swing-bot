# BTC Dip Ladder Bot v3
# HIGH IMPACT IMPROVEMENTS:
#   - Partial profit taking: sell 50% at +5%, trail the rest
#   - Fear & Greed Index gate: block entries on extreme greed (>80), boost on extreme fear (<25)
#   - Bullish divergence detection: price lower low + RSI higher low = early entry signal

param([switch]$Once)

. (Join-Path $PSScriptRoot "btc_news.ps1")

$BaseUrl   = "https://api.binance.us"
$Symbol    = "BTCUSD"
$StatePath = Join-Path $PSScriptRoot "btc_state.json"

# -- Load config --
$cfg = Get-Content (Join-Path $PSScriptRoot "btc_config.json") | ConvertFrom-Json
if ($cfg.api_key           -eq "FROM_ENV") { $cfg.api_key           = "$($env:BINANCE_API_KEY)".Trim()    }
if ($cfg.api_secret        -eq "FROM_ENV") { $cfg.api_secret        = "$($env:BINANCE_API_SECRET)".Trim() }
if ($cfg.anthropic_api_key -eq "FROM_ENV") { $cfg.anthropic_api_key = "$($env:ANTHROPIC_API_KEY)".Trim()  }

# ── Helpers ──────────────────────────────────────────────────────────────────

function Get-ServerTime {
    $r = Invoke-RestMethod -Uri ($BaseUrl + "/api/v3/time") -UseBasicParsing
    return $r.serverTime
}

function Sign-Query([string]$qs) {
    $hmac     = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($cfg.api_secret)
    $bytes    = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($qs))
    return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Fmt-Qty([double]$v)   { $v.ToString("0.00000", [System.Globalization.CultureInfo]::InvariantCulture) }
function Fmt-Price([double]$v) { $v.ToString("0.00",    [System.Globalization.CultureInfo]::InvariantCulture) }

function Get-Price {
    $r = Invoke-RestMethod -Uri ($BaseUrl + "/api/v3/ticker/price?symbol=" + $Symbol) -UseBasicParsing
    return [double]$r.price
}

function Place-MarketOrder([string]$side, [double]$qty) {
    if ($cfg.paper_trading) {
        Write-Host ("  [PAPER] {0} {1} BTC" -f $side, (Fmt-Qty $qty))
        return [pscustomobject]@{ status = "FILLED"; executedQty = $qty }
    }
    $ts  = Get-ServerTime
    $qs  = "symbol=" + $Symbol + "&side=" + $side + "&type=MARKET&quantity=" + (Fmt-Qty $qty) + "&timestamp=" + $ts
    $sig = Sign-Query $qs
    try {
        return Invoke-RestMethod -Uri ($BaseUrl + "/api/v3/order") -Method POST `
            -Headers @{ "X-MBX-APIKEY" = $cfg.api_key; "Content-Type" = "application/x-www-form-urlencoded" } `
            -Body ($qs + "&signature=" + $sig) -UseBasicParsing
    } catch {
        Write-Host ("  ORDER ERROR: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-Klines([string]$interval, [int]$limit) {
    $url = $BaseUrl + "/api/v3/klines?symbol=" + $Symbol + "&interval=" + $interval + "&limit=" + $limit
    $r   = Invoke-RestMethod -Uri $url -UseBasicParsing
    return $r | ForEach-Object {
        [pscustomobject]@{
            High   = [double]$_[2]
            Low    = [double]$_[3]
            Close  = [double]$_[4]
            Volume = [double]$_[5]
        }
    }
}

# -- RSI as final value (Wilder smoothing) --
function Get-RSI([double[]]$closes, [int]$period = 14) {
    $gains = 0.0; $losses = 0.0
    for ($i = 1; $i -le $period; $i++) {
        $d = $closes[$i] - $closes[$i-1]
        if ($d -gt 0) { $gains += $d } else { $losses += [Math]::Abs($d) }
    }
    $avgG = $gains / $period; $avgL = $losses / $period
    for ($i = ($period + 1); $i -lt $closes.Count; $i++) {
        $d    = $closes[$i] - $closes[$i-1]
        $avgG = ($avgG * ($period - 1) + (if ($d -gt 0) { $d } else { 0.0 })) / $period
        $avgL = ($avgL * ($period - 1) + (if ($d -lt 0) { [Math]::Abs($d) } else { 0.0 })) / $period
    }
    if ($avgL -eq 0) { return 100.0 }
    return 100.0 - (100.0 / (1.0 + ($avgG / $avgL)))
}

# -- RSI as full series (needed for divergence) --
function Get-RSISeries([double[]]$closes, [int]$period = 14) {
    $result = [double[]]::new($closes.Count)
    if ($closes.Count -le $period) { return $result }
    $gains = 0.0; $losses = 0.0
    for ($i = 1; $i -le $period; $i++) {
        $d = $closes[$i] - $closes[$i-1]
        if ($d -gt 0) { $gains += $d } else { $losses += [Math]::Abs($d) }
    }
    $avgG = $gains / $period; $avgL = $losses / $period
    $result[$period] = if ($avgL -eq 0) { 100.0 } else { 100.0 - (100.0 / (1.0 + $avgG / $avgL)) }
    for ($i = ($period + 1); $i -lt $closes.Count; $i++) {
        $d    = $closes[$i] - $closes[$i-1]
        $avgG = ($avgG * ($period - 1) + (if ($d -gt 0) { $d } else { 0.0 })) / $period
        $avgL = ($avgL * ($period - 1) + (if ($d -lt 0) { [Math]::Abs($d) } else { 0.0 })) / $period
        $result[$i] = if ($avgL -eq 0) { 100.0 } else { 100.0 - (100.0 / (1.0 + $avgG / $avgL)) }
    }
    return $result
}

# -- Bullish divergence: price makes lower low, RSI makes higher low --
function Get-BullishDivergence([double[]]$closes, [double[]]$rsiSeries) {
    # Find RSI swing lows (local minima below 55, at least 3 bars apart)
    $swingLows = [System.Collections.Generic.List[pscustomobject]]::new()
    $start = [Math]::Max(15, $rsiSeries.Count - 60)  # look back 60 candles max
    for ($i = $start + 2; $i -lt ($rsiSeries.Count - 2); $i++) {
        $r = $rsiSeries[$i]
        if ($r -gt 0 -and $r -lt 55 -and $r -lt $rsiSeries[$i-1] -and $r -lt $rsiSeries[$i-2] `
            -and $r -lt $rsiSeries[$i+1] -and $r -lt $rsiSeries[$i+2]) {
            $swingLows.Add([pscustomobject]@{ Idx = $i; RSI = $r; Price = $closes[$i] })
        }
    }
    if ($swingLows.Count -lt 2) { return $false }

    # Two most recent swing lows at least 5 candles apart
    $recent = $swingLows[$swingLows.Count - 1]
    $older  = $null
    for ($i = $swingLows.Count - 2; $i -ge 0; $i--) {
        if (($recent.Idx - $swingLows[$i].Idx) -ge 5) { $older = $swingLows[$i]; break }
    }
    if ($null -eq $older) { return $false }

    # Bullish divergence: price lower low AND RSI higher low
    return ($recent.Price -lt $older.Price -and $recent.RSI -gt $older.RSI)
}

# -- Fear & Greed Index (0=Extreme Fear, 100=Extreme Greed) --
function Get-FearGreed {
    try {
        $r = Invoke-RestMethod -Uri "https://api.alternative.me/fng/?limit=1" -UseBasicParsing
        $val   = [int]$r.data[0].value
        $label = "$($r.data[0].value_classification)"
        return [pscustomobject]@{ Value = $val; Label = $label; Ok = $true }
    } catch {
        return [pscustomobject]@{ Value = 50; Label = "Unknown"; Ok = $false }
    }
}

# ── State ─────────────────────────────────────────────────────────────────────

function Load-State {
    if (Test-Path $StatePath) {
        try {
            $s = Get-Content $StatePath | ConvertFrom-Json
            foreach ($f in @("tranche_count","highest_price","total_cost","avg_entry","total_qty")) {
                if ($null -eq $s.$f) { Add-Member -InputObject $s -NotePropertyName $f -NotePropertyValue 0 }
            }
            if ($null -eq $s.last_action)   { Add-Member -InputObject $s -NotePropertyName last_action   -NotePropertyValue "none"  }
            if ($null -eq $s.entry_time)    { Add-Member -InputObject $s -NotePropertyName entry_time    -NotePropertyValue ""      }
            if ($null -eq $s.partial_taken) { Add-Member -InputObject $s -NotePropertyName partial_taken -NotePropertyValue $false  }
            if ($s.in_position -and [double]$s.total_qty -le 0) {
                $s.in_position = $false; $s.tranche_count = 0
            }
            return $s
        } catch {}
    }
    return [pscustomobject]@{
        in_position   = $false
        tranche_count = 0
        avg_entry     = 0.0
        total_qty     = 0.0
        total_cost    = 0.0
        highest_price = 0.0
        entry_time    = ""
        partial_taken = $false
        last_signal   = "INIT"
        last_action   = "none"
        last_run      = ""
    }
}

function Save-State($s) {
    $s | ConvertTo-Json -Depth 5 | Set-Content $StatePath
}

# ── Main cycle ────────────────────────────────────────────────────────────────

function Run-Cycle {
    $state  = Load-State
    $nowDt  = (Get-Date).ToUniversalTime()
    $now    = $nowDt.ToString("yyyy-MM-dd HH:mm:ss")
    $price  = Get-Price

    Write-Host ""
    Write-Host ("="*70)
    Write-Host ("  BTC DIP LADDER BOT v3  --  {0} UTC" -f $now)
    Write-Host ("  BTC: `${0}  |  Tranches: {1}/3  |  Status: {2}" -f `
        $price.ToString("N2"), [int]$state.tranche_count, `
        $(if ($state.in_position) { "IN POSITION" } else { "WATCHING" }))
    Write-Host ("="*70)

    # ── Fear & Greed Index ────────────────────────────────────────────────────
    $fng       = Get-FearGreed
    $fngBlock  = ($fng.Value -ge [int]$cfg.fng_block_threshold)
    $fngBoost  = ($fng.Value -le [int]$cfg.fng_boost_threshold)
    $fngStatus = if (-not $fng.Ok) { "unavailable" } `
                 elseif ($fngBlock) { "BLOCK (Extreme Greed)" } `
                 elseif ($fngBoost) { "BOOST (Extreme Fear)" } `
                 else { "neutral" }
    Write-Host ("  Fear & Greed: {0}/100 {1}  [{2}]" -f $fng.Value, $fng.Label.ToUpper(), $fngStatus)

    # ── News sentiment ────────────────────────────────────────────────────────
    $news      = Get-Newssentiment $cfg.anthropic_api_key ([int]$cfg.news_cache_hours)
    $newsBlock = ($news.Score -le [int]$cfg.news_skip_threshold)
    $newsBoost = ($news.Score -ge [int]$cfg.news_boost_threshold)
    $cacheTag  = if ($news.FromCache) { "cached {0}h" -f $news.CacheAge } else { "fresh" }
    Write-Host ("  News: {0}/10 {1}  [{2}]  -- {3}" -f $news.Score, $news.Sentiment.ToUpper(), $cacheTag, $news.Reasoning)

    # Combined block/boost (either source can block or boost)
    $entryBlocked = ($newsBlock -or $fngBlock)
    $entryBoosted = ($newsBoost -or $fngBoost)

    # ── 4H candles: fetch 210 for SMA200 + RSI series ─────────────────────────
    $candles          = Get-Klines "4h" 210
    [double[]]$closes = $candles | ForEach-Object { $_.Close }
    $rsi4h            = [Math]::Round((Get-RSI $closes), 1)

    # RSI series for divergence detection
    [double[]]$rsiSeries = Get-RSISeries $closes
    $divergence          = Get-BullishDivergence $closes $rsiSeries

    # SMA200 and bull/bear mode
    [double[]]$last200 = $closes | Select-Object -Last 200
    $sma200    = [Math]::Round(($last200 | Measure-Object -Sum).Sum / 200, 2)
    $bullMode  = ($price -gt $sma200)
    $modeLabel = if ($bullMode) { "BULL" } else { "BEAR" }

    # Adaptive thresholds
    $bearOffset = [int]$cfg.rsi_bear_offset
    $rsi1   = if ($bullMode) { [int]$cfg.rsi_tranche1 }       else { [int]$cfg.rsi_tranche1 - $bearOffset }
    $rsi2   = if ($bullMode) { [int]$cfg.rsi_tranche2 }       else { [int]$cfg.rsi_tranche2 - $bearOffset }
    $rsi3   = if ($bullMode) { [int]$cfg.rsi_tranche3 }       else { [int]$cfg.rsi_tranche3 - $bearOffset }
    $dipReq = if ($bullMode) { [double]$cfg.dip_pct_required } else { [double]$cfg.dip_pct_bear }

    # 5-day high and dip %
    $recent      = $candles | Select-Object -Last 30
    $fiveDayHigh = ($recent | Measure-Object -Property High -Maximum).Maximum
    $dipPct      = [Math]::Round((($fiveDayHigh - $price) / $fiveDayHigh) * 100, 2)

    # Volume (display only)
    [double[]]$vols = $candles | Select-Object -Last 21 | ForEach-Object { $_.Volume }
    $avgVol = ($vols[0..19] | Measure-Object -Sum).Sum / 20
    $volPct = if ($avgVol -gt 0) { [Math]::Round(($vols[20] / $avgVol) * 100, 0) } else { 0 }

    Write-Host ("  Mode: {0} (SMA200: `${1})  RSI: {2}  Dip: {3}%  Vol: {4}%  Divergence: {5}" -f `
        $modeLabel, $sma200.ToString("N0"), $rsi4h, $dipPct, $volPct, `
        $(if ($divergence) { "YES (bullish)" } else { "no" }))
    Write-Host ("  Entry thresholds: T1<{0}  T2<{1}  T3<{2}  Dip>={3}%" -f $rsi1, $rsi2, $rsi3, $dipReq)

    # ── EXIT & PARTIAL PROFIT ─────────────────────────────────────────────────

    if ($state.in_position -and [double]$state.total_qty -gt 0) {

        if ($price -gt [double]$state.highest_price) { $state.highest_price = $price }

        $avgEntry  = [double]$state.avg_entry
        $pnlPct    = [Math]::Round((($price - $avgEntry) / $avgEntry) * 100, 2)
        $trailStop = [Math]::Round([double]$state.highest_price * (1.0 - [double]$cfg.trailing_stop_pct / 100.0), 2)
        $hardStop  = [Math]::Round($avgEntry * (1.0 - [double]$cfg.hard_stop_pct / 100.0), 2)
        $partialTgt = [Math]::Round($avgEntry * (1.0 + [double]$cfg.partial_profit_pct / 100.0), 2)

        # Hold time
        $holdHours  = 0.0; $minHoldMet = $true
        if ($state.entry_time -ne "") {
            try {
                $holdHours  = [Math]::Round((New-TimeSpan -Start ([datetime]$state.entry_time) -End $nowDt).TotalHours, 1)
                $minHoldMet = ($holdHours -ge [double]$cfg.min_hold_hours)
            } catch { $minHoldMet = $true }
        }
        $trailStatus = if ($minHoldMet) { "ACTIVE" } else { "in " + [Math]::Round([double]$cfg.min_hold_hours - $holdHours, 1) + "h" }

        Write-Host ("  POSITION: avg `${0}  qty {1} BTC  PnL: {2}%  Held: {3}h" -f `
            $avgEntry.ToString("N2"), (Fmt-Qty $state.total_qty), $pnlPct, $holdHours)
        Write-Host ("  Partial target: `${0}  Trail: `${1} [{2}]  Hard: `${3}" -f `
            $partialTgt.ToString("N2"), $trailStop.ToString("N2"), $trailStatus, $hardStop.ToString("N2"))

        # ── PARTIAL PROFIT TAKE (50% at +5%) ─────────────────────────────────
        if (-not [bool]$state.partial_taken -and $price -ge $partialTgt) {
            $sellQty = [Math]::Round([double]$state.total_qty * [double]$cfg.partial_profit_size, 5)
            Write-Host ("  PARTIAL PROFIT: price `${0} >= target `${1} -- selling {2} BTC ({3}%)" -f `
                $price.ToString("N2"), $partialTgt.ToString("N2"), (Fmt-Qty $sellQty), ([int]([double]$cfg.partial_profit_size * 100)))
            $order = Place-MarketOrder "SELL" $sellQty
            if ($null -ne $order) {
                $remainQty          = [Math]::Round([double]$state.total_qty - $sellQty, 5)
                $remainCost         = [Math]::Round([double]$state.total_cost * (1.0 - [double]$cfg.partial_profit_size), 2)
                $state.total_qty    = $remainQty
                $state.total_cost   = $remainCost
                $state.partial_taken = $true
                $realizedPnl        = [Math]::Round(($price - $avgEntry) * $sellQty, 2)
                $state.last_action  = "PARTIAL_SELL"
                $state.last_signal  = "PARTIAL PROFIT +$([Math]::Round($pnlPct,1))% (PnL `$$realizedPnl)"
                Write-Host ("  Sold {0} BTC @ `${1}  Realized PnL: `${2}  Remaining: {3} BTC" -f `
                    (Fmt-Qty $sellQty), $price.ToString("N2"), $realizedPnl.ToString("N2"), (Fmt-Qty $remainQty))
            }
        }

        # ── FULL EXIT ─────────────────────────────────────────────────────────
        # Re-read qty after possible partial sell
        $exitReason = ""
        if ($rsi4h -ge [int]$cfg.rsi_exit)            { $exitReason = "RSI " + $rsi4h + " >= " + $cfg.rsi_exit + " overbought" }
        if ($minHoldMet -and $price -le $trailStop)   { $exitReason = "Trailing stop `$" + $trailStop + " (held " + $holdHours + "h)" }
        if ($price -le $hardStop)                      { $exitReason = "Hard stop `$" + $hardStop }

        if ($exitReason -ne "" -and [double]$state.total_qty -gt 0) {
            Write-Host ("  EXIT: {0}" -f $exitReason)
            $order = Place-MarketOrder "SELL" ([double]$state.total_qty)
            if ($null -ne $order) {
                $finalPnl = [Math]::Round(($price - $avgEntry) * [double]$state.total_qty, 2)
                Write-Host ("  SOLD {0} BTC @ ~`${1}  PnL on remaining: `${2}" -f `
                    (Fmt-Qty $state.total_qty), $price.ToString("N2"), $finalPnl.ToString("N2"))
                $state.in_position    = $false
                $state.tranche_count  = 0
                $state.avg_entry      = 0.0
                $state.total_qty      = 0.0
                $state.total_cost     = 0.0
                $state.highest_price  = 0.0
                $state.entry_time     = ""
                $state.partial_taken  = $false
                $state.last_action    = "SELL"
                $state.last_signal    = "EXIT: " + $exitReason
            }
        } elseif ($exitReason -eq "") {
            Write-Host ("  HOLDING  --  RSI {0} (sell >= {1})  Trail {2}" -f $rsi4h, $cfg.rsi_exit, $trailStatus)
            if ($state.last_action -ne "PARTIAL_SELL") {
                $state.last_signal = "HOLD"
                $state.last_action = "hold"
            }
        }
    }

    # ── ENTRY ─────────────────────────────────────────────────────────────────

    if (-not $entryBlocked) {

        $tc          = [int]$state.tranche_count
        $maxTranches = [int]$cfg.max_tranches
        $trancheUsdt = [double]$cfg.tranche_size_usdt

        $rsiThreshold = switch ($tc) {
            0       { $rsi1 }
            1       { $rsi2 }
            2       { $rsi3 }
            default { 0 }
        }

        $dipOk  = ($dipPct -ge $dipReq)
        $rsiOk  = ($rsi4h  -le $rsiThreshold)
        $canAdd = ($tc -lt $maxTranches)

        # Boost conditions skip dip check for T1
        if (($entryBoosted -or $divergence) -and $tc -eq 0) { $dipOk = $true }
        # Divergence also relaxes RSI threshold by 5 points for T1
        if ($divergence -and $tc -eq 0 -and $rsi4h -le ($rsiThreshold + 5)) { $rsiOk = $true }
        # Additional tranches don't need fresh dip
        if ($tc -gt 0 -and $rsiOk) { $dipOk = $true }

        if ($canAdd -and $rsiOk -and $dipOk) {
            $entryReason = if ($divergence) { "DIVERGENCE" } elseif ($fngBoost) { "F&G FEAR BOOST" } elseif ($newsBoost) { "NEWS BOOST" } else { "RSI DIP" }
            $qty = [Math]::Round($trancheUsdt / $price, 5)
            Write-Host ("  BUY TRANCHE {0}/3  [{1}]  RSI={2}  Dip={3}%  Mode={4}  Qty={5} BTC @ `${6}" -f `
                ($tc + 1), $entryReason, $rsi4h, $dipPct, $modeLabel, (Fmt-Qty $qty), $price.ToString("N2"))

            $order = Place-MarketOrder "BUY" $qty
            if ($null -ne $order) {
                $newQty              = [Math]::Round([double]$state.total_qty + $qty, 5)
                $newCost             = [double]$state.total_cost + $trancheUsdt
                $state.in_position   = $true
                $state.tranche_count = $tc + 1
                $state.total_qty     = $newQty
                $state.total_cost    = $newCost
                $state.avg_entry     = [Math]::Round($newCost / $newQty, 2)
                if ([double]$state.highest_price -lt $price) { $state.highest_price = $price }
                if ($tc -eq 0) { $state.entry_time = $nowDt.ToString("o") }
                $state.last_action   = "BUY_T" + ($tc + 1)
                $state.last_signal   = "BUY T" + ($tc + 1) + "/3 [" + $entryReason + "] (" + $modeLabel + ")"
                Write-Host ("  Avg entry: `${0}  Total: {1} BTC  Cost: `${2}  Partial target: `${3}" -f `
                    $state.avg_entry.ToString("N2"), (Fmt-Qty $newQty), $newCost.ToString("N2"), `
                    [Math]::Round($state.avg_entry * (1.0 + [double]$cfg.partial_profit_pct / 100.0), 2).ToString("N2"))
            }

        } elseif ($canAdd) {
            $reason = if (-not $rsiOk) { "RSI " + $rsi4h + " > T" + ($tc+1) + " threshold " + $rsiThreshold + " (" + $modeLabel + ")" } `
                      elseif (-not $dipOk) { "dip " + $dipPct + "% < " + $dipReq + "% (" + $modeLabel + ")" } `
                      else { "conditions not met" }
            $divNote = if ($divergence) { " [divergence detected]" } else { "" }
            Write-Host ("  WATCHING  --  {0}{1}" -f $reason, $divNote)
            if (-not $state.in_position) {
                $state.last_signal = "WATCH: " + $reason + $divNote
                $state.last_action = "none"
            }
        } else {
            Write-Host ("  ALL 3 TRANCHES FILLED  --  waiting for exit signal")
        }

    } else {
        $blockReason = if ($fngBlock) { "Fear & Greed $($fng.Value)/100 >= $($cfg.fng_block_threshold) (Extreme Greed)" } `
                       else { "News score $($news.Score) <= $($cfg.news_skip_threshold)" }
        Write-Host ("  ENTRY BLOCKED: {0}" -f $blockReason)
        if (-not $state.in_position) {
            $state.last_signal = "BLOCKED: " + $blockReason
            $state.last_action = "none"
        }
    }

    $state.last_run = $nowDt.ToString("o")
    Save-State $state

    Write-Host ""
    Write-Host ("  State saved. Next check in ~1 hour.")
    Write-Host ("="*70)
}

# ── Entry point ───────────────────────────────────────────────────────────────

if ($Once) {
    Run-Cycle
} else {
    while ($true) {
        Run-Cycle
        Start-Sleep -Seconds 3600
    }
}
