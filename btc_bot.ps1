# BTC/USD Swing Trading Bot -- Binance.US + Claude News Sentiment
# Strategy: 50 EMA pullback + RSI exit oversold + MACD crossover (daily/4H)
# News: scrapes crypto RSS feeds, analyzes with Claude API, gates trade entry/exit.

param([switch]$Once)

$BaseUrl    = "https://api.binance.us"
$KlineUrl   = "$BaseUrl/api/v3/klines"
$Symbol     = "BTCUSD"
$KlineLimit = 100

$ConfigPath = Join-Path $PSScriptRoot "btc_config.json"
if (-not (Test-Path $ConfigPath)) { Write-Error "btc_config.json not found."; exit 1 }
$cfg = Get-Content $ConfigPath | ConvertFrom-Json
# Resolve secrets from environment variables when running in CI
if ($cfg.api_key    -eq "FROM_ENV") { $cfg.api_key           = "$($env:BINANCE_API_KEY)".Trim()    }
if ($cfg.api_secret -eq "FROM_ENV") { $cfg.api_secret        = "$($env:BINANCE_API_SECRET)".Trim() }
if ($cfg.anthropic_api_key -eq "FROM_ENV") { $cfg.anthropic_api_key = "$($env:ANTHROPIC_API_KEY)".Trim() }
if ([string]::IsNullOrWhiteSpace($cfg.api_key)) { $cfg.paper_trading = $true }

# -- Dot-source the news module --
. (Join-Path $PSScriptRoot "btc_news.ps1")

# ============================================================
# BINANCE HELPERS
# ============================================================

function Get-ServerTime {
    $r = Invoke-RestMethod -Uri ($BaseUrl + "/api/v3/time") -UseBasicParsing
    return $r.serverTime
}

function Get-Signature([string]$qs, [string]$secret) {
    $hmac  = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($secret))
    $bytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($qs))
    return ([System.BitConverter]::ToString($bytes)).Replace("-","").ToLower()
}

function Invoke-SignedGet([string]$path, [string]$query) {
    $ts  = Get-ServerTime
    $qs  = if ($query) { "$query&timestamp=$ts" } else { "timestamp=$ts" }
    $sig = Get-Signature $qs $cfg.api_secret
    $url = $BaseUrl + $path + "?" + $qs + "&signature=" + $sig
    return Invoke-RestMethod -Uri $url -Headers @{ "X-MBX-APIKEY" = $cfg.api_key } -Method GET -UseBasicParsing
}

function Invoke-SignedPost([string]$path, [string]$body) {
    $ts  = Get-ServerTime
    $b   = "$body&timestamp=$ts"
    $sig = Get-Signature $b $cfg.api_secret
    return Invoke-RestMethod -Uri ($BaseUrl + $path) `
        -Headers @{ "X-MBX-APIKEY" = $cfg.api_key; "Content-Type" = "application/x-www-form-urlencoded" } `
        -Method POST -Body ($b + "&signature=" + $sig) -UseBasicParsing
}

function Invoke-SignedDelete([string]$path, [string]$query) {
    $ts  = Get-ServerTime
    $qs  = "$query&timestamp=$ts"
    $sig = Get-Signature $qs $cfg.api_secret
    $url = $BaseUrl + $path + "?" + $qs + "&signature=" + $sig
    return Invoke-RestMethod -Uri $url -Headers @{ "X-MBX-APIKEY" = $cfg.api_key } -Method DELETE -UseBasicParsing
}

function Get-Balances {
    $acct = Invoke-SignedGet "/api/v3/account" ""
    $btc  = $acct.balances | Where-Object { $_.asset -eq "BTC" }
    $usd  = $acct.balances | Where-Object { $_.asset -eq "USD" }
    return [pscustomobject]@{ BTC=[double]$btc.free; USD=[double]$usd.free }
}

function Get-CurrentPrice {
    $r = Invoke-RestMethod -Uri ($BaseUrl + "/api/v3/ticker/price?symbol=" + $Symbol) -UseBasicParsing
    return [double]$r.price
}

function Fmt-Qty([double]$v)   { $v.ToString("0.00000", [System.Globalization.CultureInfo]::InvariantCulture) }
function Fmt-Price([double]$v) { $v.ToString("0.00",    [System.Globalization.CultureInfo]::InvariantCulture) }

function Place-MarketBuy([double]$usdAmt, [double]$price) {
    $qty = [Math]::Round($usdAmt / $price, 5)
    if ($cfg.paper_trading) {
        Write-Host ("  [PAPER] MARKET BUY  {0} BTC @ `${1}  (cost: `${2})" -f (Fmt-Qty $qty),(Fmt-Price $price),$usdAmt.ToString("N2"))
        return [pscustomobject]@{ orderId="PAPER-"+(Get-Random); status="FILLED"; executedQty=$qty; price=$price }
    }
    return Invoke-SignedPost "/api/v3/order" ("symbol="+$Symbol+"&side=BUY&type=MARKET&quantity="+(Fmt-Qty $qty))
}

function Place-MarketSell([double]$qty) {
    $q = [Math]::Round($qty, 5)
    if ($cfg.paper_trading) {
        $p = Get-CurrentPrice
        Write-Host ("  [PAPER] MARKET SELL {0} BTC @ `${1}  (proceeds: `${2})" -f (Fmt-Qty $q),(Fmt-Price $p),([Math]::Round($q*$p,2)).ToString("N2"))
        return [pscustomobject]@{ orderId="PAPER-"+(Get-Random); status="FILLED"; executedQty=$q; price=$p }
    }
    return Invoke-SignedPost "/api/v3/order" ("symbol="+$Symbol+"&side=SELL&type=MARKET&quantity="+(Fmt-Qty $q))
}

function Place-StopLimitSell([double]$qty, [double]$stopPrice, [double]$limitPrice) {
    $q=[Math]::Round($qty,5); $s=[Math]::Round($stopPrice,2); $l=[Math]::Round($limitPrice,2)
    if ($cfg.paper_trading) {
        Write-Host ("  [PAPER] STOP-LIMIT SELL {0} BTC  stop=`${1}  limit=`${2}" -f (Fmt-Qty $q),(Fmt-Price $s),(Fmt-Price $l))
        return [pscustomobject]@{ orderId="PAPER-SL-"+(Get-Random); status="NEW" }
    }
    $body = "symbol="+$Symbol+"&side=SELL&type=STOP_LOSS_LIMIT&quantity="+(Fmt-Qty $q)+"&stopPrice="+(Fmt-Price $s)+"&price="+(Fmt-Price $l)+"&timeInForce=GTC"
    return Invoke-SignedPost "/api/v3/order" $body
}

function Cancel-Order([string]$orderId) {
    if ($cfg.paper_trading) { Write-Host "  [PAPER] CANCEL order $orderId"; return }
    Invoke-SignedDelete "/api/v3/order" ("symbol="+$Symbol+"&orderId="+$orderId) | Out-Null
}

# ============================================================
# TECHNICAL INDICATORS
# ============================================================

function Get-EMAArray([double[]]$c, [int]$n) {
    if ($c.Count -lt $n) { return $null }
    $k=2.0/($n+1); $arr=[double[]]::new($c.Count)
    $seed=0.0; for($i=0;$i -lt $n;$i++){$seed+=$c[$i]}
    $arr[$n-1]=$seed/$n
    for($i=$n;$i -lt $c.Count;$i++){$arr[$i]=$c[$i]*$k+$arr[$i-1]*(1-$k)}
    return $arr
}

function Get-RSIArray([double[]]$c, [int]$p=14) {
    if ($c.Count -lt ($p+1)) { return $null }
    $g=[double[]]::new($c.Count-1); $l=[double[]]::new($c.Count-1)
    for($i=1;$i -lt $c.Count;$i++){
        $d=$c[$i]-$c[$i-1]
        if($d -gt 0){$g[$i-1]=$d}else{$l[$i-1]=[Math]::Abs($d)}
    }
    $ag=0.0;$al=0.0
    for($i=0;$i -lt $p;$i++){$ag+=$g[$i];$al+=$l[$i]}
    $ag/=$p;$al/=$p
    $rsiArr=[double[]]::new($c.Count)
    $rsiArr[$p]=if($al -eq 0){100.0}else{100-(100/(1+$ag/$al))}
    for($i=$p;$i -lt $g.Count;$i++){
        $ag=($ag*($p-1)+$g[$i])/$p;$al=($al*($p-1)+$l[$i])/$p
        $rsiArr[$i+1]=if($al -eq 0){100.0}else{100-(100/(1+$ag/$al))}
    }
    return $rsiArr
}

function Get-MACDArrays([double[]]$c) {
    $e12=Get-EMAArray $c 12;$e26=Get-EMAArray $c 26
    if($null -eq $e12 -or $null -eq $e26){return $null}
    $ml=[double[]]::new($c.Count)
    for($i=25;$i -lt $c.Count;$i++){$ml[$i]=$e12[$i]-$e26[$i]}
    [double[]]$vm=$ml[25..($c.Count-1)]
    $sigArr=Get-EMAArray $vm 9;if($null -eq $sigArr){return $null}
    $fullSig=[double[]]::new($c.Count)
    for($i=0;$i -lt $sigArr.Count;$i++){$fullSig[$i+25]=$sigArr[$i]}
    return [pscustomobject]@{MACD=$ml;Signal=$fullSig}
}

function Get-SwingSignal([string]$interval) {
    $url  = $KlineUrl+"?symbol="+$Symbol+"&interval="+$interval+"&limit="+$KlineLimit
    $data = Invoke-RestMethod -Uri $url -UseBasicParsing
    [double[]]$closes=$data|ForEach-Object{[double]$_[4]}
    [double[]]$highs =$data|ForEach-Object{[double]$_[2]}
    [double[]]$lows  =$data|ForEach-Object{[double]$_[3]}

    $close    = $closes[$closes.Count-1]
    $ema50Arr = Get-EMAArray $closes 50
    $rsiArr   = Get-RSIArray $closes 14
    $macdObj  = Get-MACDArrays $closes
    if($null -eq $ema50Arr -or $null -eq $rsiArr -or $null -eq $macdObj){return $null}

    $ema50   = $ema50Arr[$ema50Arr.Count-1]
    $rsiNow  = $rsiArr[$rsiArr.Count-1]
    $rsiPrev = $rsiArr[$rsiArr.Count-2]
    $macdNow = $macdObj.MACD[$macdObj.MACD.Count-1]
    $sigNow  = $macdObj.Signal[$macdObj.Signal.Count-1]
    $macdPrev= $macdObj.MACD[$macdObj.MACD.Count-2]
    $sigPrev = $macdObj.Signal[$macdObj.Signal.Count-2]

    [double[]]$lowSlice  = $lows[[Math]::Max(0,$lows.Count-20)..($lows.Count-1)]
    [double[]]$highSlice = $highs[[Math]::Max(0,$highs.Count-50)..($highs.Count-1)]
    $swingLow  = ($lowSlice  | Measure-Object -Minimum).Minimum
    $swingHigh = ($highSlice | Measure-Object -Maximum).Maximum

    $emaDist  = [Math]::Abs($close-$ema50)/$ema50*100
    $nearEMA  = $emaDist -le 2.0
    $rsiExit  = ($rsiPrev -lt 35) -and ($rsiNow -gt $rsiPrev) -and ($rsiNow -lt 55)
    $macdCross= ($macdNow -gt $sigNow) -and ($macdPrev -le $sigPrev)
    if(-not $macdCross){$macdCross=($macdNow -gt $sigNow) -and (($macdNow-$sigNow) -lt 200)}

    $conf=0
    if($nearEMA){$conf++}; if($rsiExit){$conf++}; if($macdCross){$conf++}

    return [pscustomobject]@{
        Confirmations=$conf; Close=$close
        NearEMA=$nearEMA; RSIExiting=$rsiExit; MACDCross=$macdCross
        EMA50=[Math]::Round($ema50,2); EMADist=[Math]::Round($emaDist,2)
        RSI=[Math]::Round($rsiNow,2); RSIPrev=[Math]::Round($rsiPrev,2)
        MACD=[Math]::Round($macdNow,2); MACDSignal=[Math]::Round($sigNow,2)
        SwingLow=[Math]::Round($swingLow,2)
        StopLoss=[Math]::Round($swingLow*0.999,2)
        Target=[Math]::Round($close*1.15,2)
    }
}

# ============================================================
# POSITION STATE
# ============================================================

$StatePath = Join-Path $PSScriptRoot "btc_state.json"
function Load-State {
    if(Test-Path $StatePath){return Get-Content $StatePath|ConvertFrom-Json}
    return [pscustomobject]@{inPosition=$false;entryPrice=0.0;qty=0.0;stopOrderId="";target=0.0;stopLoss=0.0}
}
function Save-State($s){$s|ConvertTo-Json|Set-Content $StatePath}

function Calc-PositionSize([double]$usdBal,[double]$price,[string]$newsRec) {
    $base = [Math]::Min([Math]::Round($usdBal*($cfg.risk_percent/100),2),$cfg.max_position_usdt)
    # News boosts: if tailwind, add 50% (still capped at max); if reduce_size, halve it
    if ($newsRec -eq "boost_size")  { $base = [Math]::Min([Math]::Round($base*1.5,2),$cfg.max_position_usdt) }
    if ($newsRec -eq "reduce_size") { $base = [Math]::Round($base*0.5,2) }
    return $base
}

# ============================================================
# NEWS SENTIMENT DISPLAY HELPER
# ============================================================

function Write-NewsSummary($news) {
    $cacheNote = if($news.FromCache){" (cached {0}h)" -f $news.CacheAge}else{" (fresh)"}
    $bar = ""
    $score = [int]$news.Score
    if ($score -gt 0) { $bar = "+" * [Math]::Min($score, 10) }
    elseif ($score -lt 0) { $bar = "-" * [Math]::Min([Math]::Abs($score), 10) }
    else { $bar = "=" }

    Write-Host ("  NEWS   Score: {0,3}/10  [{1,-10}]  {2}{3}" -f `
        $score, $bar, $news.Sentiment.ToUpper(), $cacheNote)
    Write-Host ("         Rec: {0,-12}  Articles: {1}" -f $news.Recommendation.ToUpper(), $news.ArticleCount)

    if ($news.KeyItems -and $news.KeyItems.Count -gt 0) {
        Write-Host "         Headlines:"
        foreach ($h in $news.KeyItems | Select-Object -First 3) {
            $short = if ($h.Length -gt 70) { $h.Substring(0,70)+"..." } else { $h }
            Write-Host ("           - {0}" -f $short)
        }
    }
    if ($news.Reasoning) {
        Write-Host ("         Analysis: {0}" -f $news.Reasoning)
    }
}

# ============================================================
# MAIN CYCLE
# ============================================================

function Run-Cycle {
    $now   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    $mode  = if($cfg.paper_trading){"PAPER"}else{"LIVE"}
    $state = Load-State

    Write-Host ""
    Write-Host ("="*68)
    Write-Host ("  BTC SWING BOT  [{0}]  --  {1} UTC" -f $mode,$now)
    Write-Host ("="*68)

    # 1. Technical signals
    Write-Host "  [1/3] Technical signals..."
    $daily = Get-SwingSignal "1d"
    $h4    = Get-SwingSignal "4h"
    if($null -eq $daily -or $null -eq $h4){Write-Host "  [ERR] Signal computation failed.";return}

    Write-Host ("  TECH   Daily {0}/3  |  4H {1}/3  |  Price: `${2}" -f `
        $daily.Confirmations, $h4.Confirmations, $daily.Close.ToString("N2"))
    Write-Host ("         EMA50=`${0} (dist {1}%)  RSI={2}  MACD cross={3}" -f `
        $daily.EMA50, $daily.EMADist, $daily.RSI, $(if($daily.MACDCross){"YES"}else{"no"}))

    # 2. News sentiment
    Write-Host "  [2/3] News sentiment..."
    $news = Get-Newssentiment $cfg.anthropic_api_key ([int]$cfg.news_cache_hours)
    Write-NewsSummary $news

    # 3. Balance
    Write-Host "  [3/3] Account balance..."
    try {
        $bal = Get-Balances
        Write-Host ("  BAL    {0} BTC  |  `${1} USD" -f $bal.BTC.ToString("N6"),$bal.USD.ToString("N2"))
    } catch {
        Write-Host ("  [WARN] Balance unavailable -- {0}" -f $_)
        $bal = [pscustomobject]@{BTC=0.0;USD=500.0}
    }

    Write-Host ("  " + "-"*64)
    $price = $daily.Close

    # ---- DECISION LOGIC ----

    $techEntryOk = ($daily.Confirmations -eq 3) -and ($h4.Confirmations -ge 2)
    $newsScore   = [int]$news.Score
    $newsRec     = $news.Recommendation
    $blockEntry  = $newsScore -le [int]$cfg.news_block_threshold
    $emergencyExit = $newsScore -le [int]$cfg.news_exit_threshold

    if (-not $state.inPosition) {

        # -- Entry decision --
        if ($emergencyExit) {
            Write-Host ("  [NEWS BLOCK]  Score {0} is at/below emergency threshold ({1}) -- no entry" -f $newsScore,[int]$cfg.news_exit_threshold)

        } elseif ($blockEntry) {
            Write-Host ("  [NEWS BLOCK]  Score {0} is bearish (threshold {1}) -- skipping entry" -f $newsScore,[int]$cfg.news_block_threshold)
            Write-Host ("               Risk: {0}" -f $news.Risks)

        } elseif (-not $techEntryOk) {
            Write-Host ("  [WATCH]  Technical: daily {0}/3, 4H {1}/3 -- waiting for all confirmations" -f $daily.Confirmations,$h4.Confirmations)
            if(-not $daily.NearEMA)    {Write-Host ("           Need: price within 2% of EMA50 (currently {0}% away)" -f $daily.EMADist)}
            if(-not $daily.RSIExiting) {Write-Host ("           Need: RSI to exit oversold (RSI={0})" -f $daily.RSI)}
            if(-not $daily.MACDCross)  {Write-Host  "           Need: MACD bullish crossover"}

        } else {
            # All clear -- enter
            $usdToUse = Calc-PositionSize $bal.USD $price $newsRec
            if ($usdToUse -lt 1) { Write-Host "  [SKIP] Insufficient USD balance."; return }

            $sizeNote = switch ($newsRec) {
                "boost_size"  { " (NEWS TAILWIND: +50% size)" }
                "reduce_size" { " (NEWS CAUTION: half size)" }
                default       { "" }
            }
            Write-Host ("  >> SWING ENTRY | `${0}{1}" -f $usdToUse.ToString("N2"),$sizeNote)
            Write-Host ("     Tech: daily 3/3 + 4H {0}/3  |  News: {1} ({2})" -f $h4.Confirmations,$newsScore,$newsRec)
            Write-Host ("     Stop:   `${0}  (swing low `${1})" -f $daily.StopLoss,$daily.SwingLow)
            Write-Host ("     Target: `${0}  (+15%)" -f $daily.Target)

            $order = Place-MarketBuy $usdToUse $price
            [double]$qty = if($order.executedQty -gt 0){$order.executedQty}else{[Math]::Round($usdToUse/$price,5)}
            $slOrder = Place-StopLimitSell $qty $daily.StopLoss ([Math]::Round($daily.StopLoss*0.999,2))

            $state.inPosition  = $true
            $state.entryPrice  = $price
            $state.qty         = $qty
            $state.stopOrderId = if($slOrder){"$($slOrder.orderId)"}else{""}
            $state.target      = $daily.Target
            $state.stopLoss    = $daily.StopLoss
            Save-State $state
            Write-Host ("  [OPEN]  {0} BTC @ `${1}" -f $qty.ToString("N5"),$price.ToString("N2"))
        }

    } else {

        # -- Position management --
        [double]$pnlPct = [Math]::Round(($price-$state.entryPrice)/$state.entryPrice*100,2)
        [double]$pnlUsd = [Math]::Round(($price-$state.entryPrice)*$state.qty,2)
        Write-Host ("  [POS]  {0} BTC | Entry `${1} | Now `${2} | PnL {3}% (`${4})" -f `
            ([double]$state.qty).ToString("N5"),([double]$state.entryPrice).ToString("N2"),`
            $price.ToString("N2"),$pnlPct,$pnlUsd)
        Write-Host ("         Stop `${0}  |  Target `${1}" -f `
            ([double]$state.stopLoss).ToString("N2"),([double]$state.target).ToString("N2"))

        $hitStop     = $price -le [double]$state.stopLoss
        $hitTarget   = $price -ge [double]$state.target
        $macdFlipped = -not $daily.MACDCross

        function Close-Position([string]$reason) {
            Write-Host ("  >> {0}" -f $reason.ToUpper())
            Place-MarketSell ([double]$state.qty) | Out-Null
            if ($state.stopOrderId -ne "") { try { Cancel-Order $state.stopOrderId } catch {} }
            $state.inPosition=$false;$state.qty=0.0;$state.entryPrice=0.0;$state.stopOrderId=""
            Save-State $state
        }

        if ($emergencyExit) {
            Close-Position "EMERGENCY EXIT -- news score $newsScore is strongly bearish"
            Write-Host ("  Risk cited: {0}" -f $news.Risks)
        } elseif ($hitTarget) {
            Close-Position "TARGET HIT +15% -- closing for profit"
        } elseif ($hitStop) {
            Close-Position "STOP-LOSS HIT -- closing position"
        } elseif ($macdFlipped) {
            Close-Position "DAILY MACD TURNED BEARISH -- swing trade exit"
        } else {
            Write-Host "  [HOLD]  Conditions OK -- holding swing trade"
            if ($blockEntry) {
                Write-Host ("  [NOTE]  News is bearish ({0}) but not at emergency exit threshold ({1})" -f $newsScore,[int]$cfg.news_exit_threshold)
            }
        }
    }

    Write-Host ("="*68)
}

# ============================================================
# ENTRY POINT
# ============================================================

if ($cfg.paper_trading) {
    Write-Host ""
    Write-Host "  *** PAPER TRADING MODE -- no real orders will be placed ***"
}

if ($Once) {
    Run-Cycle
} else {
    Write-Host "  Swing bot running. Checks every 4 hours. Press Ctrl+C to stop."
    while ($true) {
        Run-Cycle
        Write-Host "  Next check in 4 hours..."
        Start-Sleep -Seconds 14400
    }
}
