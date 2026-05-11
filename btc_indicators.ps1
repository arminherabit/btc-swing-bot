# BTC/USDT Technical Indicators — RSI(14), MACD(12,26,9), EMA(20), SMA(20)
# Data source: Binance.US public API, no key required.

$BaseUrl = "https://api.binance.us/api/v3/klines"
$Symbol  = "BTCUSDT"
$Limit   = 100   # need >= 35 for MACD; 100 gives stable values

$Intervals = @(
    [pscustomobject]@{ Key = "1m";  Label = "1-Minute"  }
    [pscustomobject]@{ Key = "15m"; Label = "15-Minute" }
    [pscustomobject]@{ Key = "1h";  Label = "1-Hour"    }
    [pscustomobject]@{ Key = "1d";  Label = "1-Day"     }
)

# ── Indicator functions ────────────────────────────────────────────────────────

function Get-SMA([double[]]$closes, [int]$period) {
    if ($closes.Count -lt $period) { return $null }
    $slice = $closes[($closes.Count - $period)..($closes.Count - 1)]
    return ($slice | Measure-Object -Sum).Sum / $period
}

function Get-EMAArray([double[]]$closes, [int]$period) {
    # Returns the full EMA array (same length as $closes), seeded with SMA.
    if ($closes.Count -lt $period) { return $null }
    $k    = 2.0 / ($period + 1)
    $emas = [double[]]::new($closes.Count)

    # seed: SMA of first $period values
    $seed = 0.0
    for ($i = 0; $i -lt $period; $i++) { $seed += $closes[$i] }
    $emas[$period - 1] = $seed / $period

    for ($i = $period; $i -lt $closes.Count; $i++) {
        $emas[$i] = $closes[$i] * $k + $emas[$i - 1] * (1 - $k)
    }
    return $emas
}

function Get-EMA([double[]]$closes, [int]$period) {
    $arr = Get-EMAArray $closes $period
    if ($null -eq $arr) { return $null }
    return $arr[$arr.Count - 1]
}

function Get-MACD([double[]]$closes) {
    # Returns [macdLine, signalLine, histogram]
    $ema12arr = Get-EMAArray $closes 12
    $ema26arr = Get-EMAArray $closes 26
    if ($null -eq $ema12arr -or $null -eq $ema26arr) { return $null }

    # MACD line = EMA12 - EMA26 (valid from index 25 onward)
    $macdLine = [double[]]::new($closes.Count)
    for ($i = 25; $i -lt $closes.Count; $i++) {
        $macdLine[$i] = $ema12arr[$i] - $ema26arr[$i]
    }

    # Signal = EMA(9) of macdLine, seeded from index 25
    $validMacd = $macdLine[25..($closes.Count - 1)]
    $sigArr    = Get-EMAArray $validMacd 9
    if ($null -eq $sigArr) { return $null }

    $macdVal   = $validMacd[$validMacd.Count - 1]
    $signalVal = $sigArr[$sigArr.Count - 1]
    $hist      = $macdVal - $signalVal

    return @($macdVal, $signalVal, $hist)
}

function Get-RSI([double[]]$closes, [int]$period = 14) {
    if ($closes.Count -lt ($period + 1)) { return $null }

    # Wilder smoothing
    $gains  = [double[]]::new($closes.Count - 1)
    $losses = [double[]]::new($closes.Count - 1)
    for ($i = 1; $i -lt $closes.Count; $i++) {
        $diff = $closes[$i] - $closes[$i - 1]
        if ($diff -gt 0) { $gains[$i - 1]  = $diff }
        else             { $losses[$i - 1] = [Math]::Abs($diff) }
    }

    # First average (simple)
    $avgGain = 0.0; $avgLoss = 0.0
    for ($i = 0; $i -lt $period; $i++) {
        $avgGain += $gains[$i]; $avgLoss += $losses[$i]
    }
    $avgGain /= $period; $avgLoss /= $period

    # Wilder smooth for remaining values
    for ($i = $period; $i -lt $gains.Count; $i++) {
        $avgGain = ($avgGain * ($period - 1) + $gains[$i])  / $period
        $avgLoss = ($avgLoss * ($period - 1) + $losses[$i]) / $period
    }

    if ($avgLoss -eq 0) { return 100.0 }
    $rs = $avgGain / $avgLoss
    return 100 - (100 / (1 + $rs))
}

function Format-Signal([double]$rsi, [double]$hist) {
    $rsiSig  = if ($rsi -gt 70) { "OVERBOUGHT" } elseif ($rsi -lt 30) { "OVERSOLD" } else { "NEUTRAL" }
    $macdSig = if ($hist -gt 0) { "BULLISH" } else { "BEARISH" }
    return "$rsiSig / $macdSig"
}

# ── Main ──────────────────────────────────────────────────────────────────────

$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
Write-Host ""
Write-Host "BTC/USDT Technical Indicators  --  $now UTC"
Write-Host ("=" * 68)
Write-Host ("{0,-8}  {1,10}  {2,10}  {3,9}  {4,9}  {5,9}  {6,-20}" -f `
    "TF", "Close", "SMA(20)", "EMA(20)", "RSI(14)", "MACD", "Signal")
Write-Host ("=" * 68)

foreach ($tf in $Intervals) {
    $url  = $BaseUrl + "?symbol=" + $Symbol + "&interval=" + $tf.Key + "&limit=" + $Limit
    $data = Invoke-RestMethod -Uri $url -UseBasicParsing

    [double[]]$closes = $data | ForEach-Object { [double]$_[4] }

    $close  = $closes[$closes.Count - 1]
    $sma20  = Get-SMA    $closes 20
    $ema20  = Get-EMA    $closes 20
    $rsi    = Get-RSI    $closes 14
    $macdR  = Get-MACD   $closes

    $macdVal = if ($null -ne $macdR) { $macdR[0] } else { $null }
    $hist    = if ($null -ne $macdR) { $macdR[2] } else { $null }

    $rsiStr  = if ($null -ne $rsi)    { $rsi.ToString("N2")    } else { "n/a" }
    $macdStr = if ($null -ne $macdVal){ $macdVal.ToString("N2") } else { "n/a" }
    $smaStr  = if ($null -ne $sma20)  { $sma20.ToString("N2")  } else { "n/a" }
    $emaStr  = if ($null -ne $ema20)  { $ema20.ToString("N2")  } else { "n/a" }
    $sig     = if ($null -ne $rsi -and $null -ne $hist) { Format-Signal $rsi $hist } else { "n/a" }

    Write-Host ("{0,-8}  {1,10}  {2,10}  {3,9}  {4,9}  {5,9}  {6,-20}" -f `
        $tf.Label, `
        $close.ToString("N2"), `
        $smaStr, $emaStr, $rsiStr, $macdStr, $sig)
}

Write-Host ""
Write-Host "  RSI guide:  < 30 = OVERSOLD  |  > 70 = OVERBOUGHT  |  else NEUTRAL"
Write-Host "  MACD guide: histogram > 0 = BULLISH momentum  |  < 0 = BEARISH momentum"
Write-Host ""

# ── Detail block for most recent candle per timeframe ─────────────────────────
foreach ($tf in $Intervals) {
    $url  = $BaseUrl + "?symbol=" + $Symbol + "&interval=" + $tf.Key + "&limit=" + $Limit
    $data = Invoke-RestMethod -Uri $url -UseBasicParsing

    [double[]]$closes = $data | ForEach-Object { [double]$_[4] }
    $last   = $data[$data.Count - 1]
    $open   = [double]$last[1]
    $high   = [double]$last[2]
    $low    = [double]$last[3]
    $close  = [double]$last[4]
    $vol    = [double]$last[5]

    $rsi   = Get-RSI  $closes 14
    $macdR = Get-MACD $closes
    $sma20 = Get-SMA  $closes 20
    $ema20 = Get-EMA  $closes 20

    $openTime = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$last[0]).UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss")

    Write-Host ("-" * 68)
    Write-Host ("  [ " + $tf.Label + " ]  Open time: $openTime UTC")
    Write-Host ("-" * 68)
    Write-Host ("  O: {0,10}   H: {1,10}   L: {2,10}   C: {3,10}" -f `
        $open.ToString("N2"), $high.ToString("N2"), $low.ToString("N2"), $close.ToString("N2"))
    Write-Host ("  Volume:  " + $vol.ToString("N4") + " BTC")
    Write-Host ("  SMA(20): " + $(if ($sma20) { $sma20.ToString("N2") } else { "n/a" }))
    Write-Host ("  EMA(20): " + $(if ($ema20) { $ema20.ToString("N2") } else { "n/a" }))
    Write-Host ("  RSI(14): " + $(if ($rsi)   { $rsi.ToString("N2")   } else { "n/a" }))
    if ($macdR) {
        Write-Host ("  MACD:    " + $macdR[0].ToString("N4") + "   Signal: " + $macdR[1].ToString("N4") + "   Hist: " + $macdR[2].ToString("N4"))
    }
    Write-Host ""
}
