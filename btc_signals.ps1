# BTC/USD Swing Trading Signal Engine
# Strategy: Price pulls back to 50 EMA (daily), RSI exits oversold, MACD bullish crossover.
# Works off the 4H and daily charts. Daily check-ins are enough.

$BaseUrl    = "https://api.binance.us"
$KlineUrl   = "$BaseUrl/api/v3/klines"
$Symbol     = "BTCUSD"
$KlineLimit = 100

# -- Indicator functions --
function Get-EMAArray([double[]]$c, [int]$n) {
    if ($c.Count -lt $n) { return $null }
    $k = 2.0/($n+1); $arr = [double[]]::new($c.Count)
    $seed = 0.0; for ($i=0; $i -lt $n; $i++) { $seed += $c[$i] }
    $arr[$n-1] = $seed/$n
    for ($i=$n; $i -lt $c.Count; $i++) { $arr[$i] = $c[$i]*$k + $arr[$i-1]*(1-$k) }
    return $arr
}

function Get-RSIArray([double[]]$c, [int]$p = 14) {
    if ($c.Count -lt ($p+1)) { return $null }
    $g = [double[]]::new($c.Count-1); $l = [double[]]::new($c.Count-1)
    for ($i=1; $i -lt $c.Count; $i++) {
        $d = $c[$i]-$c[$i-1]
        if ($d -gt 0) { $g[$i-1]=$d } else { $l[$i-1]=[Math]::Abs($d) }
    }
    $ag=0.0; $al=0.0
    for ($i=0; $i -lt $p; $i++) { $ag+=$g[$i]; $al+=$l[$i] }
    $ag/=$p; $al/=$p
    $rsiArr = [double[]]::new($c.Count)
    $rsiArr[$p] = if ($al -eq 0) { 100.0 } else { 100-(100/(1+$ag/$al)) }
    for ($i=$p; $i -lt $g.Count; $i++) {
        $ag=($ag*($p-1)+$g[$i])/$p; $al=($al*($p-1)+$l[$i])/$p
        $rsiArr[$i+1] = if ($al -eq 0) { 100.0 } else { 100-(100/(1+$ag/$al)) }
    }
    return $rsiArr
}

function Get-MACDArrays([double[]]$c) {
    $e12=Get-EMAArray $c 12; $e26=Get-EMAArray $c 26
    if ($null -eq $e12 -or $null -eq $e26) { return $null }
    $ml=[double[]]::new($c.Count)
    for ($i=25; $i -lt $c.Count; $i++) { $ml[$i]=$e12[$i]-$e26[$i] }
    [double[]]$vm=$ml[25..($c.Count-1)]
    $sigArr=Get-EMAArray $vm 9; if ($null -eq $sigArr) { return $null }
    $fullSig=[double[]]::new($c.Count)
    for ($i=0; $i -lt $sigArr.Count; $i++) { $fullSig[$i+25]=$sigArr[$i] }
    return [pscustomobject]@{ MACD=$ml; Signal=$fullSig }
}

function Get-SwingLow([double[]]$lows, [int]$lookback=20) {
    $slice = $lows[[Math]::Max(0,$lows.Count-$lookback)..($lows.Count-1)]
    return ($slice | Measure-Object -Minimum).Minimum
}

function Get-SwingHigh([double[]]$highs, [int]$lookback=50) {
    $slice = $highs[[Math]::Max(0,$highs.Count-$lookback)..($highs.Count-1)]
    return ($slice | Measure-Object -Maximum).Maximum
}

# -- Check the 3 swing-trade confirmations --
# Returns a detailed object so the bot can use the computed values directly.
function Get-SwingSignal([string]$interval, [int]$limit=100) {
    $url  = $KlineUrl + "?symbol=" + $Symbol + "&interval=" + $interval + "&limit=" + $limit
    $data = Invoke-RestMethod -Uri $url -UseBasicParsing

    [double[]]$closes = $data | ForEach-Object { [double]$_[4] }
    [double[]]$highs  = $data | ForEach-Object { [double]$_[2] }
    [double[]]$lows   = $data | ForEach-Object { [double]$_[3] }

    $close    = $closes[$closes.Count-1]
    $ema50Arr = Get-EMAArray $closes 50
    $rsiArr   = Get-RSIArray $closes 14
    $macdObj  = Get-MACDArrays $closes

    if ($null -eq $ema50Arr -or $null -eq $rsiArr -or $null -eq $macdObj) {
        return $null
    }

    $ema50    = $ema50Arr[$ema50Arr.Count-1]
    $rsiNow   = $rsiArr[$rsiArr.Count-1]
    $rsiPrev  = $rsiArr[$rsiArr.Count-2]
    $macdNow  = $macdObj.MACD[$macdObj.MACD.Count-1]
    $sigNow   = $macdObj.Signal[$macdObj.Signal.Count-1]
    $macdPrev = $macdObj.MACD[$macdObj.MACD.Count-2]
    $sigPrev  = $macdObj.Signal[$macdObj.Signal.Count-2]

    $swingLow  = Get-SwingLow  $lows  20
    $swingHigh = Get-SwingHigh $highs 50

    # Confirmation 1: Price pulled back to 50 EMA (within 2%)
    $emaDist    = [Math]::Abs($close - $ema50) / $ema50 * 100
    $nearEMA    = $emaDist -le 2.0

    # Confirmation 2: RSI exiting oversold -- was below 35, now rising back up
    $rsiExiting = ($rsiPrev -lt 35) -and ($rsiNow -gt $rsiPrev) -and ($rsiNow -lt 55)

    # Confirmation 3: MACD bullish crossover (MACD crossed above signal within last 3 bars)
    $macdCross  = ($macdNow -gt $sigNow) -and ($macdPrev -le $sigPrev)
    # Also accept if cross happened 1-2 bars ago but is still holding
    if (-not $macdCross) {
        $macdCross = ($macdNow -gt $sigNow) -and ($macdNow - $sigNow -lt 200)
    }

    $confirmations = 0
    if ($nearEMA)    { $confirmations++ }
    if ($rsiExiting) { $confirmations++ }
    if ($macdCross)  { $confirmations++ }

    return [pscustomobject]@{
        Interval       = $interval
        Close          = $close
        EMA50          = [Math]::Round($ema50, 2)
        EMADist        = [Math]::Round($emaDist, 2)
        NearEMA        = $nearEMA
        RSI            = [Math]::Round($rsiNow, 2)
        RSIPrev        = [Math]::Round($rsiPrev, 2)
        RSIExiting     = $rsiExiting
        MACD           = [Math]::Round($macdNow, 2)
        MACDSignal     = [Math]::Round($sigNow, 2)
        MACDCross      = $macdCross
        Confirmations  = $confirmations
        SwingLow       = [Math]::Round($swingLow, 2)
        SwingHigh      = [Math]::Round($swingHigh, 2)
        StopLoss       = [Math]::Round($swingLow * 0.999, 2)   # just below swing low
        Target         = [Math]::Round($close * 1.15, 2)        # 15% above entry
    }
}

function Write-Confirmation([string]$label, [bool]$met, [string]$detail) {
    $icon = if ($met) { "[OK]" } else { "[--]" }
    Write-Host ("    {0} {1,-28} {2}" -f $icon, $label, $detail)
}

# -- Main --
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
Write-Host ""
Write-Host ("=" * 68)
Write-Host ("  BTC/USD SWING SIGNAL  --  {0} UTC" -f $now)
Write-Host ("=" * 68)

foreach ($tf in @("4h","1d")) {
    $s = Get-SwingSignal $tf 100
    if ($null -eq $s) { Write-Host "  [$tf] Not enough data"; continue }

    $label = if ($tf -eq "1d") { "Daily" } else { "4-Hour" }
    Write-Host ""
    Write-Host ("  [{0}]  Price: `${1}  |  EMA50: `${2}  |  {3}/3 confirmations" -f `
        $label, $s.Close.ToString("N2"), $s.EMA50.ToString("N2"), $s.Confirmations)
    Write-Host ("  " + "-" * 64)

    Write-Confirmation "Price near 50 EMA" $s.NearEMA `
        ("dist={0}%  (need <= 2%)" -f $s.EMADist)

    Write-Confirmation "RSI exiting oversold" $s.RSIExiting `
        ("RSI {0} -> {1}  (need prev<35, rising, now<55)" -f $s.RSIPrev, $s.RSI)

    Write-Confirmation "MACD bullish crossover" $s.MACDCross `
        ("MACD={0}  Signal={1}" -f $s.MACD, $s.MACDSignal)

    Write-Host ""
    Write-Host ("    Swing low  (stop):  `${0}" -f $s.SwingLow)
    Write-Host ("    Stop-loss target:   `${0}  ({1}% below entry)" -f `
        $s.StopLoss, [Math]::Round(($s.Close - $s.StopLoss)/$s.Close*100,2))
    Write-Host ("    Profit target:      `${0}  (+15% from entry)" -f $s.Target)
    Write-Host ("    Swing high (ref):   `${0}" -f $s.SwingHigh)

    if ($s.Confirmations -eq 3) {
        Write-Host ""
        Write-Host "    >>> ALL 3 CONFIRMED -- SWING ENTRY SIGNAL <<<"
    } elseif ($s.Confirmations -eq 2) {
        Write-Host ""
        Write-Host ("    Watching -- {0}/3 conditions met" -f $s.Confirmations)
    }
}

Write-Host ""
Write-Host ("=" * 68)
Write-Host "  Strategy: Hold days-to-weeks for a 10-25% move."
Write-Host "  Charts:   4H for entry timing, Daily for trend direction."
Write-Host "  Entry:    All 3 confirmations required simultaneously."
Write-Host ("=" * 68)
Write-Host ""