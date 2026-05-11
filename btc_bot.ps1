# BTC Dip Ladder Bot
# Strategy: Buy RSI dips in 3 tranches ($167 each), exit on RSI recovery or trailing stop.
# Runs on Binance.US, gated by Claude news sentiment.

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

# -- Helpers --

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

function Get-RSI([double[]]$closes, [int]$period = 14) {
    $gains = 0.0; $losses = 0.0
    for ($i = 1; $i -le $period; $i++) {
        $d = $closes[$i] - $closes[$i-1]
        if ($d -gt 0) { $gains += $d } else { $losses += [Math]::Abs($d) }
    }
    $avgG = $gains / $period
    $avgL = $losses / $period
    for ($i = ($period + 1); $i -lt $closes.Count; $i++) {
        $d    = $closes[$i] - $closes[$i-1]
        $g    = if ($d -gt 0) { $d } else { 0.0 }
        $l    = if ($d -lt 0) { [Math]::Abs($d) } else { 0.0 }
        $avgG = ($avgG * ($period - 1) + $g) / $period
        $avgL = ($avgL * ($period - 1) + $l) / $period
    }
    if ($avgL -eq 0) { return 100.0 }
    return 100.0 - (100.0 / (1.0 + ($avgG / $avgL)))
}

# -- State --

function Load-State {
    if (Test-Path $StatePath) {
        try {
            $s = Get-Content $StatePath | ConvertFrom-Json
            foreach ($f in @("tranche_count","highest_price","total_cost","avg_entry","total_qty")) {
                if ($null -eq $s.$f) { Add-Member -InputObject $s -NotePropertyName $f -NotePropertyValue 0 }
            }
            if ($null -eq $s.last_action) { Add-Member -InputObject $s -NotePropertyName last_action -NotePropertyValue "none" }
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
        last_signal   = "INIT"
        last_action   = "none"
        last_run      = ""
    }
}

function Save-State($s) {
    $s | ConvertTo-Json -Depth 5 | Set-Content $StatePath
}

# -- Main cycle --

function Run-Cycle {
    $state = Load-State
    $now   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    $price = Get-Price

    Write-Host ""
    Write-Host ("="*66)
    Write-Host ("  BTC DIP LADDER BOT  --  {0} UTC" -f $now)
    Write-Host ("  BTC: `${0}  |  Tranches: {1}/3  |  Status: {2}" -f `
        $price.ToString("N2"), [int]$state.tranche_count, `
        $(if ($state.in_position) { "IN POSITION" } else { "WATCHING" }))
    Write-Host ("="*66)

    # -- News --
    $news      = Get-Newssentiment $cfg.anthropic_api_key ([int]$cfg.news_cache_hours)
    $newsBlock = ($news.Score -le [int]$cfg.news_skip_threshold)
    $newsBoost = ($news.Score -ge [int]$cfg.news_boost_threshold)
    $cacheTag  = if ($news.FromCache) { "cached {0}h" -f $news.CacheAge } else { "fresh" }
    Write-Host ("  News: {0}/10 {1}  [{2}]" -f $news.Score, $news.Sentiment.ToUpper(), $cacheTag)
    Write-Host ("  {0}" -f $news.Reasoning)

    # -- 4H indicators --
    $candles   = Get-Klines "4h" 60
    [double[]]$closes = $candles | ForEach-Object { $_.Close }
    $rsi4h     = [Math]::Round((Get-RSI $closes), 1)

    $recent      = $candles | Select-Object -Last 30
    $fiveDayHigh = ($recent | Measure-Object -Property High -Maximum).Maximum
    $dipPct      = [Math]::Round((($fiveDayHigh - $price) / $fiveDayHigh) * 100, 2)

    [double[]]$vols = $candles | Select-Object -Last 21 | ForEach-Object { $_.Volume }
    $avgVol = ($vols[0..19] | Measure-Object -Sum).Sum / 20
    $volOk  = ($vols[20] -ge $avgVol * 0.8)

    Write-Host ("  RSI(4H): {0}  |  Dip from 5d-high: {1}%  |  Volume: {2}" -f `
        $rsi4h, $dipPct, $(if ($volOk) { "OK" } else { "LOW" }))

    # ── EXIT ──────────────────────────────────────────────────────────────────

    if ($state.in_position -and [double]$state.total_qty -gt 0) {

        if ($price -gt [double]$state.highest_price) { $state.highest_price = $price }

        $avgEntry  = [double]$state.avg_entry
        $pnlPct    = [Math]::Round((($price - $avgEntry) / $avgEntry) * 100, 2)
        $trailStop = [Math]::Round([double]$state.highest_price * (1.0 - [double]$cfg.trailing_stop_pct / 100.0), 2)
        $hardStop  = [Math]::Round($avgEntry * (1.0 - [double]$cfg.hard_stop_pct / 100.0), 2)

        Write-Host ("  POSITION: avg `${0}  qty {1} BTC  PnL: {2}%" -f `
            $avgEntry.ToString("N2"), (Fmt-Qty $state.total_qty), $pnlPct)
        Write-Host ("  Trail stop: `${0}  Hard stop: `${1}  Peak: `${2}" -f `
            $trailStop.ToString("N2"), $hardStop.ToString("N2"), ([double]$state.highest_price).ToString("N2"))

        $exitReason = ""
        if ($rsi4h -ge [int]$cfg.rsi_exit) { $exitReason = "RSI " + $rsi4h + " >= " + $cfg.rsi_exit + " overbought" }
        if ($price -le $trailStop)         { $exitReason = "Trailing stop hit at `$" + $trailStop }
        if ($price -le $hardStop)          { $exitReason = "Hard stop hit at `$" + $hardStop }

        if ($exitReason -ne "") {
            Write-Host ("  EXIT SIGNAL: {0}" -f $exitReason)
            $order = Place-MarketOrder "SELL" ([double]$state.total_qty)
            if ($null -ne $order) {
                Write-Host ("  SOLD {0} BTC @ ~`${1}  PnL: {2}%" -f `
                    (Fmt-Qty $state.total_qty), $price.ToString("N2"), $pnlPct)
                $state.in_position    = $false
                $state.tranche_count  = 0
                $state.avg_entry      = 0.0
                $state.total_qty      = 0.0
                $state.total_cost     = 0.0
                $state.highest_price  = 0.0
                $state.last_action    = "SELL"
                $state.last_signal    = "EXIT: " + $exitReason
            }
        } else {
            Write-Host ("  HOLDING  --  RSI {0} (sell at >= {1})" -f $rsi4h, $cfg.rsi_exit)
            $state.last_signal = "HOLD"
            $state.last_action = "hold"
        }
    }

    # ── ENTRY ─────────────────────────────────────────────────────────────────

    if (-not $newsBlock) {

        $tc          = [int]$state.tranche_count
        $maxTranches = [int]$cfg.max_tranches
        $trancheUsdt = [double]$cfg.tranche_size_usdt

        $rsiThreshold = switch ($tc) {
            0       { [int]$cfg.rsi_tranche1 }
            1       { [int]$cfg.rsi_tranche2 }
            2       { [int]$cfg.rsi_tranche3 }
            default { 0 }
        }

        $dipOk  = ($dipPct -ge [double]$cfg.dip_pct_required)
        $rsiOk  = ($rsi4h  -le $rsiThreshold)
        $canAdd = ($tc -lt $maxTranches)

        if ($newsBoost -and $tc -eq 0) { $dipOk = $true }
        if ($tc -gt 0 -and $rsiOk)    { $dipOk = $true }

        if ($canAdd -and $rsiOk -and $dipOk -and $volOk) {

            $qty = [Math]::Round($trancheUsdt / $price, 5)
            Write-Host ("  BUY TRANCHE {0}/3  RSI={1}  Dip={2}%  Qty={3} BTC @ `${4}" -f `
                ($tc + 1), $rsi4h, $dipPct, (Fmt-Qty $qty), $price.ToString("N2"))

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
                $state.last_action   = "BUY_T" + ($tc + 1)
                $state.last_signal   = "BUY TRANCHE " + ($tc + 1) + "/3"
                Write-Host ("  Avg entry: `${0}  Total: {1} BTC  Cost: `${2}" -f `
                    $state.avg_entry.ToString("N2"), (Fmt-Qty $newQty), $newCost.ToString("N2"))
            }

        } elseif ($canAdd) {
            $reason = if (-not $rsiOk)  { "RSI " + $rsi4h + " > threshold " + $rsiThreshold + " for T" + ($tc+1) } `
                      elseif (-not $dipOk)  { "dip " + $dipPct + "% < required " + $cfg.dip_pct_required + "%" } `
                      elseif (-not $volOk)  { "volume too low" } `
                      else                  { "conditions not met" }
            Write-Host ("  WATCHING  --  {0}" -f $reason)
            if (-not $state.in_position) {
                $state.last_signal = "WATCH: " + $reason
                $state.last_action = "none"
            }
        } else {
            Write-Host ("  ALL 3 TRANCHES FILLED  --  waiting for exit signal")
        }

    } else {
        Write-Host ("  NEWS BLOCK: score {0} <= {1}. No new entries." -f $news.Score, [int]$cfg.news_skip_threshold)
        if (-not $state.in_position) {
            $state.last_signal = "NEWS BLOCK (" + $news.Score + ")"
            $state.last_action = "none"
        }
    }

    $state.last_run = (Get-Date).ToUniversalTime().ToString("o")
    Save-State $state

    Write-Host ""
    Write-Host ("  State saved. Next check in ~1 hour.")
    Write-Host ("="*66)
}

# -- Entry point --

if ($Once) {
    Run-Cycle
} else {
    while ($true) {
        Run-Cycle
        Start-Sleep -Seconds 3600
    }
}
