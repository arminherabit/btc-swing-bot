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

# ── Aggressiveness Factor (0.0 – 0.5) ────────────────────────────────────────
# Combines all market signals into a single conviction score.
# High AF = favorable conditions → loosen RSI gates, amplify return weight.
# Low / negative AF = hostile conditions → tighten.
function Compute-AggressivenessFactor([bool]$bullMode, $fng, $news, [bool]$divergence, [double]$rsi4h) {
    # Base: bull market gets more rope than bear
    $af = if ($bullMode) { 0.15 } else { 0.05 }

    # Fear & Greed signal (extreme fear = great buying window)
    if    ($fng.Value -le 15) { $af += 0.20 }  # Extreme Fear  – max boost
    elseif($fng.Value -le 25) { $af += 0.15 }  # Extreme Fear
    elseif($fng.Value -le 45) { $af += 0.05 }  # Fear
    elseif($fng.Value -ge 80) { $af -= 0.20 }  # Extreme Greed – max penalty
    elseif($fng.Value -ge 65) { $af -= 0.10 }  # Greed

    # News sentiment
    if    ($news.Score -ge  6) { $af += 0.10 }  # Strongly bullish
    elseif($news.Score -ge  3) { $af += 0.05 }  # Mildly bullish
    elseif($news.Score -le -5) { $af -= 0.10 }  # Strongly bearish
    elseif($news.Score -le -2) { $af -= 0.05 }  # Mildly bearish

    # RSI depth below threshold (deeper oversold = more confident)
    if    ($rsi4h -le 25) { $af += 0.15 }
    elseif($rsi4h -le 30) { $af += 0.10 }
    elseif($rsi4h -le 35) { $af += 0.05 }

    # Technical divergence = strong reversal signal
    if ($divergence) { $af += 0.10 }

    # Clamp to [-0.20, 0.50]
    return [Math]::Round([Math]::Max(-0.20, [Math]::Min(0.50, $af)), 3)
}

# ── Cycle Reward ──────────────────────────────────────────────────────────────
# reward = portfolio_return * (1 + aggressiveness_factor)
#        - 0.3 * max_drawdown
#        - transaction_costs
#
# Positive = position is paying off relative to risk taken.
# Negative = drawdown or costs are eating the return.
function Compute-Reward([double]$price, $state, [double]$af) {
    $portfolioReturn = 0.0
    $maxDrawdown     = 0.0
    $txCosts         = 0.0

    if ($state.in_position -and [double]$state.avg_entry -gt 0) {
        $avgE            = [double]$state.avg_entry
        $portfolioReturn = ($price - $avgE) / $avgE

        $peak = [double]$state.highest_price
        if ($peak -gt 0 -and $price -lt $peak) {
            $maxDrawdown = ($peak - $price) / $peak
        }
        # 0.1% taker fee each side = 0.2% round-trip per tranche
        $txCosts = 0.002 * [double]$state.tranche_count
    }

    $reward = $portfolioReturn * (1.0 + $af) - 0.3 * $maxDrawdown - $txCosts
    return [Math]::Round($reward, 6)
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
            # Telemetry fields for live dashboard (added v3)
            foreach ($f in @("btc_price","rsi","sma200","dip_pct","fng_value","news_score","partial_target","trail_stop","hard_stop",
                             "aggressiveness_factor","cycle_reward","reward_rolling_avg","rl_confidence")) {
                if ($null -eq $s.$f) { Add-Member -InputObject $s -NotePropertyName $f -NotePropertyValue 0 }
            }
            if ($null -eq $s.mode)           { Add-Member -InputObject $s -NotePropertyName mode           -NotePropertyValue "" }
            if ($null -eq $s.fng_label)      { Add-Member -InputObject $s -NotePropertyName fng_label      -NotePropertyValue "" }
            if ($null -eq $s.reward_history) { Add-Member -InputObject $s -NotePropertyName reward_history -NotePropertyValue @()  }
            if ($null -eq $s.rl_action)      { Add-Member -InputObject $s -NotePropertyName rl_action      -NotePropertyValue "NONE" }
            if ($null -eq $s.rl_override)    { Add-Member -InputObject $s -NotePropertyName rl_override    -NotePropertyValue $false }
            if ($null -eq $s.last_stopout)   { Add-Member -InputObject $s -NotePropertyName last_stopout   -NotePropertyValue "" }
            if ($null -eq $s.last_action_time)      { Add-Member -InputObject $s -NotePropertyName last_action_time      -NotePropertyValue "" }
            if ($null -eq $s.watchdog_boost_active) { Add-Member -InputObject $s -NotePropertyName watchdog_boost_active -NotePropertyValue $false }
            if ($null -eq $s.scalp_in_position)     { Add-Member -InputObject $s -NotePropertyName scalp_in_position     -NotePropertyValue $false }
            if ($null -eq $s.scalp_entry_price)     { Add-Member -InputObject $s -NotePropertyName scalp_entry_price     -NotePropertyValue 0.0 }
            if ($null -eq $s.scalp_qty)             { Add-Member -InputObject $s -NotePropertyName scalp_qty             -NotePropertyValue 0.0 }
            if ($null -eq $s.scalp_entry_time)      { Add-Member -InputObject $s -NotePropertyName scalp_entry_time      -NotePropertyValue "" }
            if ($null -eq $s.last_scalp_exit_time)  { Add-Member -InputObject $s -NotePropertyName last_scalp_exit_time  -NotePropertyValue "" }
            if ($null -eq $s.atr_pct_24h)           { Add-Member -InputObject $s -NotePropertyName atr_pct_24h           -NotePropertyValue 0.0 }
            if ($s.in_position -and [double]$s.total_qty -le 0) {
                $s.in_position = $false; $s.tranche_count = 0
            }
            return $s
        } catch {}
    }
    return [pscustomobject]@{
        in_position    = $false
        tranche_count  = 0
        avg_entry      = 0.0
        total_qty      = 0.0
        total_cost      = 0.0
        highest_price  = 0.0
        entry_time     = ""
        partial_taken  = $false
        last_signal    = "INIT"
        last_action    = "none"
        last_run       = ""
        # Telemetry for live dashboard
        btc_price             = 0.0
        rsi                   = 0.0
        mode                  = ""
        sma200                = 0.0
        dip_pct               = 0.0
        fng_value             = 0
        fng_label             = ""
        news_score            = 0
        partial_target        = 0.0
        trail_stop            = 0.0
        hard_stop             = 0.0
        # Reward engine
        aggressiveness_factor = 0.0
        cycle_reward          = 0.0
        reward_rolling_avg    = 0.0
        reward_history        = @()
        # RL signal
        rl_action             = "NONE"
        rl_confidence         = 0.0
        rl_override           = $false
        # Cooldown tracking
        last_stopout          = ""
        # Stale-watchdog (48h idle + low F&G → AF boost)
        last_action_time      = ""
        watchdog_boost_active = $false
        # Range-scalp module (separate from main tranches)
        scalp_in_position     = $false
        scalp_entry_price     = 0.0
        scalp_qty             = 0.0
        scalp_entry_time      = ""
        last_scalp_exit_time  = ""
        atr_pct_24h           = 0.0
    }
}

function Save-State($s) {
    $s | ConvertTo-Json -Depth 5 | Set-Content $StatePath
}

# ── Trade outcome log (consumed by nightly RL retrain) ────────────────────────
function Append-TradeLog($entry) {
    $logPath = Join-Path $PSScriptRoot "trade_log.jsonl"
    try {
        $entry | ConvertTo-Json -Compress -Depth 4 | Add-Content -Path $logPath
    } catch {
        Write-Host ("  [warn] trade_log append failed: " + $_.Exception.Message)
    }
}

# ── Main cycle ────────────────────────────────────────────────────────────────

function Load-RLSignal {
    $path = Join-Path $PSScriptRoot "rl_signal.json"
    if (-not (Test-Path $path)) { return $null }
    try {
        $sig = Get-Content $path | ConvertFrom-Json
        if ($sig.override -eq $true -and $sig.action -ne "NONE") { return $sig }
    } catch {}
    return $null
}

function Run-Cycle {
    $state  = Load-State
    $rl     = Load-RLSignal
    $nowDt  = (Get-Date).ToUniversalTime()
    $now    = $nowDt.ToString("yyyy-MM-dd HH:mm:ss")
    $price  = Get-Price

    Write-Host ""
    Write-Host ("="*70)
    Write-Host ("  BTC DIP LADDER BOT v3 + RL  --  {0} UTC" -f $now)
    Write-Host ("  BTC: `${0}  |  Tranches: {1}/3  |  Status: {2}" -f `
        $price.ToString("N2"), [int]$state.tranche_count, `
        $(if ($state.in_position) { "IN POSITION" } else { "WATCHING" }))
    if ($null -ne $rl) {
        Write-Host ("  RL Signal: {0}  Confidence: {1}%  AF: {2}  [OVERRIDE ACTIVE]" -f `
            $rl.action, ([int]($rl.confidence * 100)), $rl.af)
    } else {
        Write-Host "  RL Signal: none (rule-based mode)"
    }
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

    # ── Stop-out cooldown: block re-entry for 24h after a stop fires ──────────
    $cooldownActive = $false
    $cooldownHoursLeft = 0.0
    if ($state.last_stopout -ne "") {
        try {
            $stopHours = (New-TimeSpan -Start ([datetime]$state.last_stopout) -End $nowDt).TotalHours
            if ($stopHours -lt 8.0) {
                $cooldownActive    = $true
                $cooldownHoursLeft = [Math]::Round(8.0 - $stopHours, 1)
                $entryBlocked      = $true
            }
        } catch {}
    }
    if ($cooldownActive) {
        Write-Host ("  COOLDOWN: stop-out {0}h ago -- entries blocked for {1}h more" -f `
            [Math]::Round((New-TimeSpan -Start ([datetime]$state.last_stopout) -End $nowDt).TotalHours, 1), $cooldownHoursLeft)
    }

    # ── 4H candles: fetch 210 for SMA200 + RSI series ─────────────────────────
    $candles          = Get-Klines "4h" 210
    [double[]]$closes = $candles | ForEach-Object { $_.Close }
    $rsi4h            = [Math]::Round((Get-RSI $closes), 1)

    # RSI series for divergence detection + direction confirmation
    [double[]]$rsiSeries = Get-RSISeries $closes
    $divergence          = Get-BullishDivergence $closes $rsiSeries

    # RSI direction: require RSI rising from low (higher low in last 2 bars)
    # Prevents buying a falling knife -- only enter when RSI is turning up
    $rsiTurning = $false
    if ($rsiSeries.Count -ge 4) {
        $r1 = $rsiSeries[$rsiSeries.Count - 2]   # prev bar
        $r2 = $rsiSeries[$rsiSeries.Count - 3]   # 2 bars ago
        $r3 = $rsiSeries[$rsiSeries.Count - 4]   # 3 bars ago
        # RSI made a low and is now rising: r2 < r3 AND r1 > r2 (turning up)
        $rsiTurning = ($r2 -lt $r3 -and $r1 -gt $r2 -and $r1 -gt 0 -and $r2 -gt 0)
    }

    # SMA200 and bull/bear mode
    [double[]]$last200 = $closes | Select-Object -Last 200
    $sma200    = [Math]::Round(($last200 | Measure-Object -Sum).Sum / 200, 2)
    $bullMode  = ($price -gt $sma200)

    # ── Near-SMA200 transition zone ───────────────────────────────────────────
    # When price is within 3% BELOW SMA200, relax to BULL RSI thresholds so the
    # bot can catch the breakout setup. Safety caps (2 tranches, 4.5% trail,
    # 3% partial profit, RSI-turn check) remain BEAR-level.
    $smaPctGap  = if ($sma200 -gt 0) { [Math]::Round(($sma200 - $price) / $sma200 * 100, 2) } else { 99.0 }
    $nearSma200 = (-not $bullMode) -and ($smaPctGap -gt 0) -and ($smaPctGap -le 3.0)
    $modeLabel  = if ($bullMode) { "BULL" } elseif ($nearSma200) { "NEAR-SMA" } else { "BEAR" }

    # ── Aggressiveness Factor & Reward ───────────────────────────────────────
    $af = Compute-AggressivenessFactor $bullMode $fng $news $divergence $rsi4h

    # ── Stale-watchdog: 48h+ idle AND Fear & Greed ≤30 → AF +0.10 boost ──────
    # Forces engagement in long sideways markets where dip strategy never fires
    $watchdogBoost = 0.0
    $watchdogActive = $false
    $idleHours = 9999.0
    if ($state.last_action_time -ne "") {
        try { $idleHours = (New-TimeSpan -Start ([datetime]$state.last_action_time) -End $nowDt).TotalHours } catch {}
    }
    if ($idleHours -ge 48.0 -and [int]$fng -le 30 -and -not $state.in_position -and -not $entryBlocked) {
        $watchdogBoost  = 0.10
        $af             = [Math]::Round([Math]::Min(0.50, $af + $watchdogBoost), 2)
        $watchdogActive = $true
    }
    $state.watchdog_boost_active = $watchdogActive

    $cycleReward = Compute-Reward $price $state $af

    # Rolling 24-cycle (24h) average reward
    $rHist = [System.Collections.Generic.List[double]]::new()
    if ($state.reward_history -is [System.Array] -and $state.reward_history.Count -gt 0) {
        foreach ($v in $state.reward_history) { $rHist.Add([double]$v) }
    }
    $rHist.Add($cycleReward)
    if ($rHist.Count -gt 24) { $rHist.RemoveAt(0) }
    $rewardAvg = [Math]::Round(($rHist | Measure-Object -Sum).Sum / $rHist.Count, 6)

    $afLabel = if ($af -ge 0.35) { "HIGH" } elseif ($af -ge 0.20) { "MEDIUM" } elseif ($af -ge 0.05) { "LOW" } else { "DEFENSIVE" }
    Write-Host ("  Aggressiveness: {0} ({1})  Reward: {2}  Avg24h: {3}" -f $af, $afLabel, $cycleReward, $rewardAvg)

    # ── Adaptive thresholds (AF loosens RSI gates) ────────────────────────────
    # Each +0.10 AF adds 1 RSI point -- e.g. AF=0.30 → RSI gate +3 pts
    $afRsiBonus = [int]([Math]::Floor($af * 10))   # 0 to +5 pts
    $bearOffset = [int]$cfg.rsi_bear_offset
    # NEAR-SMA200 uses BULL RSI thresholds (no offset) -- price close to reclaiming SMA200
    $rsi1   = if ($bullMode -or $nearSma200) { [int]$cfg.rsi_tranche1 } else { [int]$cfg.rsi_tranche1 - $bearOffset }
    $rsi2   = if ($bullMode -or $nearSma200) { [int]$cfg.rsi_tranche2 } else { [int]$cfg.rsi_tranche2 - $bearOffset }
    $rsi3   = if ($bullMode -or $nearSma200) { [int]$cfg.rsi_tranche3 } else { [int]$cfg.rsi_tranche3 - $bearOffset }
    $rsi1  += $afRsiBonus; $rsi2 += $afRsiBonus; $rsi3 += $afRsiBonus
    # Dip: BULL=1.5% | NEAR-SMA=2.0% (intermediate) | BEAR=4.0%
    $dipReq = if ($bullMode) { [double]$cfg.dip_pct_required } `
              elseif ($nearSma200) { 2.0 } `
              else { [double]$cfg.dip_pct_bear }
    if ($af -ge 0.30) { $dipReq = [Math]::Max(0.5, $dipReq - 0.5) }

    # BEAR mode: cap at 2 tranches (less exposure in downtrend)
    # BEAR mode: lower partial profit target (3% vs 5% -- rallies are shorter)
    $maxTranchesEff    = if ($bullMode) { [int]$cfg.max_tranches } else { [Math]::Min(2, [int]$cfg.max_tranches) }
    $partialProfitPct  = if ($bullMode) { [double]$cfg.partial_profit_pct } else { [double]$cfg.partial_profit_pct_bear }

    # 5-day high and dip %
    $recent      = $candles | Select-Object -Last 30
    $fiveDayHigh = ($recent | Measure-Object -Property High -Maximum).Maximum
    $dipPct      = [Math]::Round((($fiveDayHigh - $price) / $fiveDayHigh) * 100, 2)

    # Volume (display only)
    [double[]]$vols = $candles | Select-Object -Last 21 | ForEach-Object { $_.Volume }
    $avgVol = ($vols[0..19] | Measure-Object -Sum).Sum / 20
    $volPct = if ($avgVol -gt 0) { [Math]::Round(($vols[20] / $avgVol) * 100, 0) } else { 0 }

    # ── ATR % (24h, last 6 × 4H candles) -- used by range-scalp module ────────
    $atrCandles = $candles | Select-Object -Last 6
    $trList = @()
    for ($i = 1; $i -lt $atrCandles.Count; $i++) {
        $h = [double]$atrCandles[$i].High; $l = [double]$atrCandles[$i].Low
        $pc = [double]$atrCandles[$i-1].Close
        $tr = [Math]::Max([Math]::Max($h - $l, [Math]::Abs($h - $pc)), [Math]::Abs($l - $pc))
        $trList += $tr
    }
    $atrAbs = if ($trList.Count -gt 0) { ($trList | Measure-Object -Sum).Sum / $trList.Count } else { 0 }
    $atrPct = if ($price -gt 0) { [Math]::Round(($atrAbs / $price) * 100, 2) } else { 0.0 }
    $state.atr_pct_24h = $atrPct

    $nearLabel = if ($nearSma200) { "  [SMA gap: $smaPctGap%  NEAR-SMA mode active]" } else { "" }
    if ($watchdogActive) {
        Write-Host ("  Watchdog: ACTIVE  Idle {0:F1}h  F&G {1}  AF boosted +0.10" -f $idleHours, $fng)
    }
    Write-Host ("  Mode: {0} (SMA200: `${1})  RSI: {2}  Dip: {3}%  Vol: {4}%  Divergence: {5}  RSI-Turning: {6}{7}" -f `
        $modeLabel, $sma200.ToString("N0"), $rsi4h, $dipPct, $volPct, `
        $(if ($divergence) { "YES (bullish)" } else { "no" }), `
        $(if ($rsiTurning) { "YES" } else { "no" }), $nearLabel)
    Write-Host ("  Entry thresholds: T1<{0}  T2<{1}  T3<{2}  Dip>={3}%  MaxTranches={4}" -f $rsi1, $rsi2, $rsi3, $dipReq, $maxTranchesEff)

    # ── RL SIGNAL OVERRIDE ────────────────────────────────────────────────────
    # When the PPO model is confident (>=60%), it can trigger actions directly,
    # bypassing the rule-based RSI/dip gates. Rule-based hard stops always fire.

    if ($null -ne $rl) {
        $rlAction = $rl.action
        # RSI threshold for current tranche (RL BUY must respect same gate as rule-based)
        $rlRsiThreshold = switch ([int]$state.tranche_count) {
            0       { $rsi1 }
            1       { $rsi2 }
            2       { $rsi3 }
            default { 0 }
        }

        if ($rlAction -eq "SELL_ALL" -and $state.in_position -and [double]$state.total_qty -gt 0) {
            $pnlPct = [Math]::Round((($price - [double]$state.avg_entry) / [double]$state.avg_entry) * 100, 2)
            Write-Host ("  RL OVERRIDE: SELL_ALL  (conf={0}%  PnL={1}%)" -f ([int]($rl.confidence*100)), $pnlPct)
            $order = Place-MarketOrder "SELL" ([double]$state.total_qty)
            if ($null -ne $order) {
                $state.in_position   = $false; $state.tranche_count = 0
                $state.avg_entry     = 0.0;     $state.total_qty     = 0.0
                $state.total_cost    = 0.0;     $state.highest_price = 0.0
                $state.entry_time    = "";       $state.partial_taken = $false
                $state.last_action   = "RL_SELL"
                $state.last_signal   = "RL EXIT conf=$([int]($rl.confidence*100))% PnL=$pnlPct%"
                Append-TradeLog @{
                    time = $nowDt.ToString("o"); kind = "RL_EXIT"; reason = "rl_override"
                    entry_price = [double]$state.avg_entry; exit_price = $price
                    qty = [double]$state.total_qty; pnl_pct = $pnlPct
                    rl_confidence = [double]$rl.confidence
                    mode = $modeLabel; rsi = $rsi4h; fng = $fng; news = $news; af = $af
                }
            }
        }
        elseif ($rlAction -eq "SELL_PARTIAL" -and $state.in_position `
                -and -not [bool]$state.partial_taken -and [double]$state.total_qty -gt 0) {
            $pnlPct  = [Math]::Round((($price - [double]$state.avg_entry) / [double]$state.avg_entry) * 100, 2)
            $sellQty = [Math]::Round([double]$state.total_qty * 0.5, 5)
            Write-Host ("  RL OVERRIDE: SELL_PARTIAL  (conf={0}%  PnL={1}%)" -f ([int]($rl.confidence*100)), $pnlPct)
            $order = Place-MarketOrder "SELL" $sellQty
            if ($null -ne $order) {
                $state.total_qty     = [Math]::Round([double]$state.total_qty - $sellQty, 5)
                $state.total_cost    = [Math]::Round([double]$state.total_cost * 0.5, 2)
                $state.partial_taken = $true
                $state.last_action   = "RL_PARTIAL"
                $state.last_signal   = "RL PARTIAL conf=$([int]($rl.confidence*100))% PnL=$pnlPct%"
                Append-TradeLog @{
                    time = $nowDt.ToString("o"); kind = "RL_PARTIAL"; reason = "rl_override"
                    entry_price = [double]$state.avg_entry; exit_price = $price; qty = $sellQty
                    pnl_pct = $pnlPct; rl_confidence = [double]$rl.confidence
                    mode = $modeLabel; rsi = $rsi4h; fng = $fng; news = $news; af = $af
                }
            }
        }
        elseif ($rlAction -eq "BUY_TRANCHE" -and -not $entryBlocked `
                -and [int]$state.tranche_count -lt [int]$cfg.max_tranches `
                -and $rsi4h -le $rlRsiThreshold) {
            $qty = [Math]::Round([double]$cfg.tranche_size_usdt / $price, 5)
            Write-Host ("  RL OVERRIDE: BUY_TRANCHE T{0}/3  (conf={1}%  RSI={2})" -f `
                ([int]$state.tranche_count + 1), ([int]($rl.confidence*100)), $rsi4h)
            $order = Place-MarketOrder "BUY" $qty
            if ($null -ne $order) {
                $tc = [int]$state.tranche_count
                $newQty              = [Math]::Round([double]$state.total_qty + $qty, 5)
                $newCost             = [double]$state.total_cost + [double]$cfg.tranche_size_usdt
                $state.in_position   = $true
                $state.tranche_count = $tc + 1
                $state.total_qty     = $newQty
                $state.total_cost    = $newCost
                $state.avg_entry     = [Math]::Round($newCost / $newQty, 2)
                if ([double]$state.highest_price -lt $price) { $state.highest_price = $price }
                if ($tc -eq 0) { $state.entry_time = $nowDt.ToString("o") }
                $state.last_action   = "RL_BUY_T$($tc+1)"
                $state.last_signal   = "RL BUY T$($tc+1)/3 conf=$([int]($rl.confidence*100))%"
            }
        }
        else {
            Write-Host ("  RL HOLD: {0} (no override action needed this cycle)" -f $rlAction)
        }
    }

    # ── EXIT & PARTIAL PROFIT ─────────────────────────────────────────────────

    if ($state.in_position -and [double]$state.total_qty -gt 0) {

        if ($price -gt [double]$state.highest_price) { $state.highest_price = $price }

        $avgEntry  = [double]$state.avg_entry
        $pnlPct    = [Math]::Round((($price - $avgEntry) / $avgEntry) * 100, 2)
        # Wider trail stop in BEAR mode (4.5%) to avoid getting shaken out by volatility
        $trailPct  = if ($bullMode) { [double]$cfg.trailing_stop_pct } else { [double]$cfg.trailing_stop_pct + 1.5 }
        $trailStop = [Math]::Round([double]$state.highest_price * (1.0 - $trailPct / 100.0), 2)
        $hardStop  = [Math]::Round($avgEntry * (1.0 - [double]$cfg.hard_stop_pct / 100.0), 2)
        $partialTgt = [Math]::Round($avgEntry * (1.0 + $partialProfitPct / 100.0), 2)

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
                Append-TradeLog @{
                    time = $nowDt.ToString("o"); kind = "PARTIAL_PROFIT"; reason = "partial_target"
                    entry_price = $avgEntry; exit_price = $price; qty = $sellQty
                    pnl_usd = $realizedPnl; pnl_pct = [Math]::Round($pnlPct,2)
                    mode = $modeLabel; rsi = $rsi4h; fng = $fng; news = $news; af = $af
                    tranche_count = [int]$state.tranche_count
                }
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
                $finalPnlPct = [Math]::Round((($price - $avgEntry) / $avgEntry) * 100, 2)
                Write-Host ("  SOLD {0} BTC @ ~`${1}  PnL on remaining: `${2}" -f `
                    (Fmt-Qty $state.total_qty), $price.ToString("N2"), $finalPnl.ToString("N2"))
                Append-TradeLog @{
                    time = $nowDt.ToString("o"); kind = "MAIN_EXIT"; reason = $exitReason
                    entry_price = $avgEntry; exit_price = $price; qty = [double]$state.total_qty
                    pnl_usd = $finalPnl; pnl_pct = $finalPnlPct
                    mode = $modeLabel; rsi = $rsi4h; fng = $fng; news = $news; af = $af
                    tranche_count = [int]$state.tranche_count
                }
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
                # Record stop-out time for 24h cooldown
                if ($exitReason -match "stop") { $state.last_stopout = $nowDt.ToString("o") }
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
        $maxTranches = $maxTranchesEff     # BEAR=2, BULL=3
        $trancheUsdt = [double]$cfg.tranche_size_usdt

        $rsiThreshold = switch ($tc) {
            0       { $rsi1 }
            1       { $rsi2 }
            2       { $rsi3 }
            default { 0 }
        }

        $dipOk     = ($dipPct -ge $dipReq)
        $rsiOk     = ($rsi4h  -le $rsiThreshold)
        $canAdd    = ($tc -lt $maxTranches)
        # In BEAR mode require RSI turning up (bottom confirmation)
        # In BULL or NEAR-SMA200 mode, skip turning check (breakout setup)
        $turningOk = ($bullMode -or $nearSma200 -or $divergence -or $rsiTurning)

        # Boost conditions skip dip check for T1
        if (($entryBoosted -or $divergence) -and $tc -eq 0) { $dipOk = $true }
        # Divergence also relaxes RSI threshold by 5 points for T1
        if ($divergence -and $tc -eq 0 -and $rsi4h -le ($rsiThreshold + 5)) { $rsiOk = $true }
        # Additional tranches don't need fresh dip
        if ($tc -gt 0 -and $rsiOk) { $dipOk = $true }

        if ($canAdd -and $rsiOk -and $dipOk -and $turningOk) {
            $entryReason = if ($divergence) { "DIVERGENCE" } elseif ($fngBoost) { "F&G FEAR BOOST" } elseif ($newsBoost) { "NEWS BOOST" } elseif ($rsiTurning) { "RSI TURN" } else { "RSI DIP" }
            $qty = [Math]::Round($trancheUsdt / $price, 5)
            Write-Host ("  BUY TRANCHE {0}/{1}  [{2}]  RSI={3}  Dip={4}%  Mode={5}  Qty={6} BTC @ `${7}" -f `
                ($tc + 1), $maxTranches, $entryReason, $rsi4h, $dipPct, $modeLabel, (Fmt-Qty $qty), $price.ToString("N2"))

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
                Append-TradeLog @{
                    time = $nowDt.ToString("o"); kind = "MAIN_ENTRY"; tranche = ($tc + 1)
                    entry_price = $price; qty = $tQty
                    mode = $modeLabel; rsi = $rsi4h; dip_pct = $dipPct
                    fng = $fng; news = $news; af = $af
                    near_sma = [bool]$nearSma200; divergence = [bool]$divergence; rsi_turning = [bool]$rsiTurning
                }
                Write-Host ("  Avg entry: `${0}  Total: {1} BTC  Cost: `${2}  Partial target: `${3}" -f `
                    $state.avg_entry.ToString("N2"), (Fmt-Qty $newQty), $newCost.ToString("N2"), `
                    [Math]::Round($state.avg_entry * (1.0 + [double]$cfg.partial_profit_pct / 100.0), 2).ToString("N2"))
            }

        } elseif ($canAdd) {
            $reason = if (-not $rsiOk) { "RSI " + $rsi4h + " > T" + ($tc+1) + " threshold " + $rsiThreshold + " (" + $modeLabel + ")" } `
                      elseif (-not $dipOk) { "dip " + $dipPct + "% < " + $dipReq + "% (" + $modeLabel + ")" } `
                      elseif (-not $turningOk) { "RSI not yet turning up (BEAR confirmation)" } `
                      else { "conditions not met" }
            $divNote = if ($divergence) { " [divergence detected]" } else { "" }
            Write-Host ("  WATCHING  --  {0}{1}" -f $reason, $divNote)
            if (-not $state.in_position) {
                $state.last_signal = "WATCH: " + $reason + $divNote
                $state.last_action = "none"
            }
        } else {
            Write-Host ("  ALL {0} TRANCHES FILLED  --  waiting for exit signal" -f $maxTranches)
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

    # ── Enrich state with telemetry so the live dashboard can read it ─────
    $state.btc_price  = $price
    $state.rsi        = $rsi4h
    $state.mode       = $modeLabel
    $state.sma200     = $sma200
    $state.dip_pct    = $dipPct
    $state.fng_value             = $fng.Value
    $state.fng_label             = $fng.Label
    $state.news_score            = $news.Score
    $state.aggressiveness_factor = $af
    $state.cycle_reward          = $cycleReward
    $state.reward_rolling_avg    = $rewardAvg
    $state.reward_history        = $rHist.ToArray()
    # RL signal passthrough (for dashboard)
    if ($null -ne $rl) {
        $state.rl_action     = $rl.action
        $state.rl_confidence = $rl.confidence
        $state.rl_override   = $rl.override
    } else {
        $state.rl_action     = "NONE"
        $state.rl_confidence = 0.0
        $state.rl_override   = $false
    }
    if ($state.in_position -and [double]$state.avg_entry -gt 0) {
        $avgE  = [double]$state.avg_entry
        $peakP = [double]$state.highest_price
        $dashTrailPct         = if ($bullMode) { [double]$cfg.trailing_stop_pct } else { [double]$cfg.trailing_stop_pct + 1.5 }
        $state.partial_target = [Math]::Round($avgE  * (1.0 + [double]$cfg.partial_profit_pct / 100.0), 2)
        $state.trail_stop     = [Math]::Round($peakP * (1.0 - $dashTrailPct                   / 100.0), 2)
        $state.hard_stop      = [Math]::Round($avgE  * (1.0 - [double]$cfg.hard_stop_pct      / 100.0), 2)
    } else {
        $state.partial_target = 0
        $state.trail_stop     = 0
        $state.hard_stop      = 0
    }

    # ── Range-Scalp Module ───────────────────────────────────────────────────
    # Tight-range scalping for low-ATR chop markets. Independent from main tranches.
    # ENTRY:  no main position, no active scalp, ATR < threshold, RSI 40-58, cooldown elapsed
    # EXIT:   TP +scalp_take_profit_pct, SL -scalp_stop_pct, or max-hold expired
    if ([bool]$cfg.scalp_enabled) {
        $scalpTpPct      = [double]$cfg.scalp_take_profit_pct
        $scalpSlPct      = [double]$cfg.scalp_stop_pct
        $scalpAtrMax     = [double]$cfg.scalp_atr_max_pct
        $scalpCdHours    = [double]$cfg.scalp_cooldown_hours
        $scalpMaxHold    = [double]$cfg.scalp_max_hold_hours
        $scalpSizeUsdt   = [double]$cfg.scalp_size_usdt

        # EXIT first
        if ([bool]$state.scalp_in_position -and [double]$state.scalp_qty -gt 0) {
            $sEntry    = [double]$state.scalp_entry_price
            $sPnlPct   = [Math]::Round((($price - $sEntry) / $sEntry) * 100, 2)
            $sHoldHrs  = 0.0
            try { $sHoldHrs = (New-TimeSpan -Start ([datetime]$state.scalp_entry_time) -End $nowDt).TotalHours } catch {}

            $sExit = ""
            if     ($sPnlPct -ge  $scalpTpPct)  { $sExit = "TP +$sPnlPct%" }
            elseif ($sPnlPct -le -$scalpSlPct)  { $sExit = "SL $sPnlPct%" }
            elseif ($sHoldHrs -ge $scalpMaxHold){ $sExit = "TIMEOUT $([Math]::Round($sHoldHrs,1))h PnL=$sPnlPct%" }

            if ($sExit -ne "") {
                Write-Host ("  SCALP EXIT: {0}" -f $sExit)
                $order = Place-MarketOrder "SELL" ([double]$state.scalp_qty)
                if ($null -ne $order) {
                    $state.scalp_in_position    = $false
                    $state.scalp_entry_price    = 0.0
                    $state.scalp_qty            = 0.0
                    $state.scalp_entry_time     = ""
                    $state.last_scalp_exit_time = $nowDt.ToString("o")
                    $state.last_action          = "SCALP_EXIT"
                    $state.last_signal          = "SCALP $sExit"
                    Append-TradeLog @{
                        time = $nowDt.ToString("o"); kind = "SCALP_EXIT"; reason = $sExit
                        entry_price = $sEntry; exit_price = $price
                        qty = [double]$state.scalp_qty; pnl_pct = $sPnlPct
                        hold_hours = [Math]::Round($sHoldHrs, 2)
                        mode = $modeLabel; rsi = $rsi4h; atr_pct = $atrPct
                        fng = $fng; news = $news
                    }
                }
            }
        }
        # ENTRY (only if no main position, no active scalp, conditions met)
        elseif (-not $state.in_position -and -not [bool]$state.scalp_in_position `
                -and -not $entryBlocked -and $atrPct -lt $scalpAtrMax `
                -and $rsi4h -ge 40 -and $rsi4h -le 58) {
            $cdElapsed = $true
            if ($state.last_scalp_exit_time -ne "") {
                try {
                    $hrsSince = (New-TimeSpan -Start ([datetime]$state.last_scalp_exit_time) -End $nowDt).TotalHours
                    $cdElapsed = ($hrsSince -ge $scalpCdHours)
                } catch {}
            }
            if ($cdElapsed) {
                $scalpQty = [Math]::Round($scalpSizeUsdt / $price, 5)
                Write-Host ("  SCALP ENTRY: ATR={0}%  RSI={1}  Qty={2} BTC (~`${3})" -f $atrPct, $rsi4h, $scalpQty, $scalpSizeUsdt)
                $order = Place-MarketOrder "BUY" $scalpQty
                if ($null -ne $order) {
                    $state.scalp_in_position = $true
                    $state.scalp_entry_price = $price
                    $state.scalp_qty         = $scalpQty
                    $state.scalp_entry_time  = $nowDt.ToString("o")
                    $state.last_action       = "SCALP_BUY"
                    $state.last_signal       = "SCALP BUY ATR=$atrPct% RSI=$rsi4h"
                }
            }
        }
    }

    # ── Stamp last_action_time on any real trade (clears stale-watchdog) ─────
    if ($state.last_action -match '^(BUY_T|SELL|PARTIAL_SELL|RL_BUY|RL_SELL|RL_PARTIAL|SCALP_)') {
        $state.last_action_time = $nowDt.ToString("o")
    }

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
