# BTC Dip Ladder Bot -- Dashboard Generator v2
# Shows: live price, position, entry/exit targets, projected P&L table, entry conditions, news, run history.

param([switch]$GenerateOnly)

$BaseUrl = "https://api.binance.us"
$Symbol  = "BTCUSD"
$OutFile = Join-Path $PSScriptRoot "dashboard.html"

if (-not $GenerateOnly) {
    Write-Host "Pulling latest state from GitHub..."
    git -C $PSScriptRoot pull --quiet 2>&1 | Out-Null
}

# -- Load files --
$StatePath = Join-Path $PSScriptRoot "btc_state.json"
$NewsPath  = Join-Path $PSScriptRoot "btc_news_cache.json"
$CfgPath   = Join-Path $PSScriptRoot "btc_config.json"

$state = if (Test-Path $StatePath) { Get-Content $StatePath | ConvertFrom-Json } else { $null }
$news  = if (Test-Path $NewsPath)  { Get-Content $NewsPath  | ConvertFrom-Json } else { $null }
$cfg   = if (Test-Path $CfgPath)   { Get-Content $CfgPath   | ConvertFrom-Json } else { $null }

# -- Live data from Binance --
Write-Host "Fetching live market data..."
$livePrice = 0; $change24h = 0; $high24h = 0; $low24h = 0; $vol24h = 0
try {
    $ticker    = Invoke-RestMethod -Uri ($BaseUrl + "/api/v3/ticker/24hr?symbol=" + $Symbol) -UseBasicParsing
    $livePrice = [Math]::Round([double]$ticker.lastPrice, 2)
    $change24h = [Math]::Round([double]$ticker.priceChangePercent, 2)
    $high24h   = [Math]::Round([double]$ticker.highPrice, 2)
    $low24h    = [Math]::Round([double]$ticker.lowPrice, 2)
    $vol24h    = [Math]::Round([double]$ticker.quoteVolume / 1000000, 1)
} catch { Write-Host "Warning: Could not fetch ticker data" }

# -- Fetch 4H candles for RSI + SMA200 --
$rsi4h = 0; $sma200 = 0; $dipPct = 0; $bullMode = $false
try {
    $url     = $BaseUrl + "/api/v3/klines?symbol=" + $Symbol + "&interval=4h&limit=210"
    $candles = Invoke-RestMethod -Uri $url -UseBasicParsing
    [double[]]$closes = $candles | ForEach-Object { [double]$_[4] }
    [double[]]$highs  = $candles | ForEach-Object { [double]$_[2] }

    # RSI Wilder
    $p = 14; $g = 0.0; $l = 0.0
    for ($i = 1; $i -le $p; $i++) { $d = $closes[$i]-$closes[$i-1]; if($d -gt 0){$g+=$d}else{$l+=[Math]::Abs($d)} }
    $ag = $g/$p; $al = $l/$p
    for ($i = ($p+1); $i -lt $closes.Count; $i++) {
        $d = $closes[$i]-$closes[$i-1]
        $ag = ($ag*($p-1)+(if($d -gt 0){$d}else{0}))/$p
        $al = ($al*($p-1)+(if($d -lt 0){[Math]::Abs($d)}else{0}))/$p
    }
    $rsi4h = if($al -eq 0){100}else{[Math]::Round(100-(100/(1+$ag/$al)),1)}

    # SMA200
    [double[]]$last200 = $closes | Select-Object -Last 200
    $sma200  = [Math]::Round(($last200 | Measure-Object -Sum).Sum / 200, 2)
    $bullMode = ($livePrice -gt $sma200)

    # Dip from 5-day high
    $recent5d    = $highs | Select-Object -Last 30
    $fiveDayHigh = ($recent5d | Measure-Object -Maximum).Maximum
    $dipPct      = if($fiveDayHigh -gt 0){[Math]::Round((($fiveDayHigh - $livePrice)/$fiveDayHigh)*100,2)}else{0}
} catch { Write-Host "Warning: Could not fetch candle data" }

# -- Compute exit targets from state --
$avgEntry    = if($state -and $state.avg_entry) { [double]$state.avg_entry } else { 0 }
$totalQty    = if($state -and $state.total_qty) { [double]$state.total_qty } else { 0 }
$totalCost   = if($state -and $state.total_cost){ [double]$state.total_cost} else { 0 }
$peakPrice   = if($state -and $state.highest_price){ [double]$state.highest_price } else { 0 }
$inPosition  = if($state -and $state.in_position){ [bool]$state.in_position } else { $false }
$trancheCnt  = if($state -and $state.tranche_count){ [int]$state.tranche_count } else { 0 }
$entryTime   = if($state -and $state.entry_time){ "$($state.entry_time)" } else { "" }

$trailPct    = if($cfg -and $cfg.trailing_stop_pct){ [double]$cfg.trailing_stop_pct } else { 3.0 }
$hardPct     = if($cfg -and $cfg.hard_stop_pct){    [double]$cfg.hard_stop_pct }     else { 5.0 }
$rsiExit     = if($cfg -and $cfg.rsi_exit){         [int]$cfg.rsi_exit }             else { 60 }
$minHold     = if($cfg -and $cfg.min_hold_hours){   [int]$cfg.min_hold_hours }       else { 12 }
$rsi1        = if($cfg -and $cfg.rsi_tranche1){     [int]$cfg.rsi_tranche1 }         else { 42 }
$rsi2        = if($cfg -and $cfg.rsi_tranche2){     [int]$cfg.rsi_tranche2 }         else { 36 }
$rsi3        = if($cfg -and $cfg.rsi_tranche3){     [int]$cfg.rsi_tranche3 }         else { 30 }
$dipReq      = if($cfg -and $cfg.dip_pct_required){ [double]$cfg.dip_pct_required }  else { 1.5 }
$newsBoostTh = if($cfg -and $cfg.news_boost_threshold){ [int]$cfg.news_boost_threshold } else { 6 }
$newsBlockTh = if($cfg -and $cfg.news_skip_threshold){  [int]$cfg.news_skip_threshold }  else { -5 }
$bearOffset  = if($cfg -and $cfg.rsi_bear_offset){  [int]$cfg.rsi_bear_offset }      else { 7 }

# Adaptive thresholds
$t1Thresh = if($bullMode){ $rsi1 } else { $rsi1 - $bearOffset }
$t2Thresh = if($bullMode){ $rsi2 } else { $rsi2 - $bearOffset }
$t3Thresh = if($bullMode){ $rsi3 } else { $rsi3 - $bearOffset }
$dipThresh = if($bullMode){ $dipReq } else { [double]$cfg.dip_pct_bear }

$trailStopPrice = if($peakPrice -gt 0){ [Math]::Round($peakPrice * (1 - $trailPct/100), 2) } else { 0 }
$hardStopPrice  = if($avgEntry -gt 0){  [Math]::Round($avgEntry  * (1 - $hardPct/100),  2) } else { 0 }
$currentPnlPct  = if($avgEntry -gt 0 -and $livePrice -gt 0){ [Math]::Round((($livePrice-$avgEntry)/$avgEntry)*100,2) } else { 0 }
$currentPnlUsd  = if($totalQty -gt 0 -and $livePrice -gt 0 -and $avgEntry -gt 0){ [Math]::Round(($livePrice-$avgEntry)*$totalQty,2) } else { 0 }

# Hold time
$holdHours = 0
if ($entryTime -ne "") {
    try { $holdHours = [Math]::Round(((Get-Date).ToUniversalTime() - [datetime]$entryTime).TotalHours, 1) } catch {}
}
$trailActive = ($holdHours -ge $minHold)
$trailArmedIn = [Math]::Max(0, [Math]::Round($minHold - $holdHours, 1))

# News values
$newsScore = if($news){ [int]$news.score } else { 0 }
$newsSentiment = if($news){ "$($news.sentiment)" } else { "unknown" }
$newsBlock = ($newsScore -le $newsBlockTh)
$newsBoost = ($newsScore -ge $newsBoostTh)

# Next tranche threshold
$nextRsiThresh = switch($trancheCnt) { 0{$t1Thresh} 1{$t2Thresh} 2{$t3Thresh} default{0} }

# Get recent runs
$runs = @()
try {
    $env:PATH = $env:PATH + ";C:\Program Files\GitHub CLI"
    $rawRuns  = gh run list --repo arminherabit/btc-swing-bot --limit 10 --json "databaseId,status,conclusion,startedAt,event" 2>$null | ConvertFrom-Json
    $runs     = $rawRuns | ForEach-Object {
        [pscustomobject]@{ id=$_.databaseId; status=$_.status; conclusion=$_.conclusion; startedAt=$_.startedAt; event=$_.event }
    }
} catch {}

# Serialize to JSON for embedding
$stateJson   = if($state){ $state | ConvertTo-Json -Compress -Depth 5 } else { "null" }
$newsJson    = if($news){  $news  | ConvertTo-Json -Compress -Depth 5 } else { "null" }
$runsJson    = if($runs){  $runs  | ConvertTo-Json -Compress -Depth 3 } else { "[]" }
$genTime     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm") + " UTC"
$modeLabel   = if($bullMode){ "BULL" } else { "BEAR" }
$paperTrading = if($cfg -and $cfg.paper_trading){ "true" } else { "false" }

# P&L scenarios: compute for embedding
$scenarios = @(-20,-15,-10,-7,-5,-3,0,3,5,7,10,15,20,25,30)
$scenarioRows = ""
foreach ($pct in $scenarios) {
    $scPrice     = if($avgEntry -gt 0){ [Math]::Round($avgEntry * (1 + $pct/100), 2) } else { [Math]::Round($livePrice * (1 + $pct/100), 2) }
    $scPnlUsd    = if($totalQty -gt 0 -and $avgEntry -gt 0){ [Math]::Round(($scPrice - $avgEntry) * $totalQty, 2) } else { 0 }
    $isHardStop  = ($avgEntry -gt 0 -and $scPrice -le $hardStopPrice)
    $isTrailStop = ($peakPrice -gt 0 -and $scPrice -le $trailStopPrice -and $trailActive)
    $rowClass    = if($isHardStop){"row-danger"}elseif($isTrailStop){"row-warn"}elseif($pct -gt 0){"row-profit"}elseif($pct -lt 0){"row-loss"}else{"row-entry"}
    $pctSign     = if($pct -ge 0){"+"}else{""}
    $pnlClass    = if($scPnlUsd -ge 0){"pos"}else{"neg"}
    $pnlSign     = if($scPnlUsd -ge 0){"+"}else{""}
    $noteText    = if($isHardStop){"HARD STOP"}elseif($isTrailStop){"TRAIL STOP"}elseif($pct -eq 0){"&lt;-- ENTRY"}else{""}
    $scenarioRows += "<tr class='$rowClass'><td>$pctSign$pct%</td><td>`$$($scPrice.ToString('N2'))</td><td class='$pnlClass'>$pctSign$pct%</td><td class='$pnlClass'>$pnlSign`$$($scPnlUsd.ToString('N2'))</td><td>$noteText</td></tr>"
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BTC Bot Dashboard</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0d1117;color:#c9d1d9;font-family:'Segoe UI',system-ui,sans-serif;padding:18px;min-height:100vh}
h2{font-size:.7rem;font-weight:700;text-transform:uppercase;letter-spacing:1px;color:#8b949e;margin-bottom:14px}
.topbar{display:flex;justify-content:space-between;align-items:center;margin-bottom:20px;padding-bottom:14px;border-bottom:1px solid #21262d}
.topbar h1{font-size:1.3rem;font-weight:700;color:#f0f6fc}
.topbar-right{text-align:right;font-size:.75rem;color:#8b949e}
.badge{padding:2px 10px;border-radius:20px;font-size:.68rem;font-weight:700;letter-spacing:.5px}
.badge-live{background:#1a4731;color:#3fb950;border:1px solid #238636}
.badge-paper{background:#271a0c;color:#d29922;border:1px solid #9e6a03}
.badge-bull{background:#1a4731;color:#3fb950;border:1px solid #238636}
.badge-bear{background:#2d1c1c;color:#f85149;border:1px solid #6e1c1c}
.live-dot{width:7px;height:7px;border-radius:50%;background:#3fb950;display:inline-block;margin-right:5px;animation:pulse 1.5s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:14px}
.grid3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:14px;margin-bottom:14px}
.grid4{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-bottom:14px}
.card{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:18px}
.price-big{font-size:2.8rem;font-weight:700;color:#f0f6fc;letter-spacing:-1px;font-variant-numeric:tabular-nums}
.stat-label{font-size:.72rem;color:#8b949e;margin-bottom:3px}
.stat-val{font-size:1rem;font-weight:600;color:#f0f6fc}
.stat-val-sm{font-size:.85rem;color:#c9d1d9}
.row{display:flex;justify-content:space-between;align-items:center;padding:5px 0;border-bottom:1px solid #21262d;font-size:.82rem}
.row:last-child{border-bottom:none}
.divider{height:1px;background:#21262d;margin:10px 0}
.pos{color:#3fb950!important}
.neg{color:#f85149!important}
.neu{color:#8b949e!important}
.warn{color:#d29922!important}
.pnl-big{font-size:1.6rem;font-weight:700}
/* P&L TABLE */
.pnl-table{width:100%;border-collapse:collapse;font-size:.8rem}
.pnl-table th{text-align:left;padding:6px 10px;border-bottom:2px solid #30363d;color:#8b949e;font-size:.7rem;text-transform:uppercase;letter-spacing:.5px}
.pnl-table td{padding:6px 10px;border-bottom:1px solid #21262d}
.pnl-table tr:last-child td{border-bottom:none}
.row-profit td:first-child{color:#3fb950}
.row-loss   td:first-child{color:#f85149}
.row-entry  {background:#1c2128}
.row-entry  td:first-child{color:#58a6ff;font-weight:700}
.row-danger {background:#2d1c1c}
.row-danger td:first-child{color:#f85149;font-weight:700}
.row-warn   {background:#271e0a}
.row-warn   td:first-child{color:#d29922;font-weight:700}
.pos{color:#3fb950}
.neg{color:#f85149}
/* EXIT TARGETS */
.target-card{display:flex;flex-direction:column;gap:8px}
.target-row{display:flex;justify-content:space-between;align-items:center;padding:8px 12px;border-radius:6px;font-size:.83rem}
.target-trail{background:#1c1a0a;border:1px solid #9e6a03}
.target-hard {background:#1c1010;border:1px solid #6e1c1c}
.target-rsi  {background:#0a1c10;border:1px solid #1a4731}
.target-hold {background:#0d1117;border:1px solid #30363d}
/* ENTRY CONDITIONS */
.cond-row{display:flex;justify-content:space-between;align-items:center;padding:7px 0;border-bottom:1px solid #21262d;font-size:.82rem}
.cond-row:last-child{border-bottom:none}
.cond-ok{color:#3fb950;font-weight:700}
.cond-no{color:#f85149;font-weight:700}
.cond-close{color:#d29922;font-weight:700}
/* PROGRESS BAR */
.progress-wrap{height:6px;background:#21262d;border-radius:3px;margin-top:4px;overflow:hidden}
.progress-fill{height:100%;border-radius:3px}
/* RUNS */
.run-row{display:flex;justify-content:space-between;align-items:center;padding:6px 0;border-bottom:1px solid #21262d;font-size:.78rem}
.run-row:last-child{border-bottom:none}
.dot{width:7px;height:7px;border-radius:50%;display:inline-block;margin-right:6px}
.dot-ok{background:#3fb950}.dot-fail{background:#f85149}.dot-run{background:#d29922;animation:pulse 1s infinite}
.tag{padding:2px 8px;border-radius:4px;font-size:.68rem;font-weight:700}
.tag-ok{background:#1a4731;color:#3fb950}
.tag-fail{background:#2d1c1c;color:#f85149}
.tag-neu{background:#1c2128;color:#8b949e}
.news-score{font-size:2.2rem;font-weight:700}
.sbar{height:7px;border-radius:3px;background:#21262d;overflow:hidden;margin:6px 0}
.sfill{height:100%;border-radius:3px}
</style>
</head>
<body>

<div class="topbar">
  <div>
    <h1>&#8383; BTC Dip Ladder Bot</h1>
    <div style="font-size:.75rem;color:#8b949e;margin-top:3px">arminherabit/btc-swing-bot &nbsp;|&nbsp; Binance.US BTCUSD</div>
  </div>
  <div class="topbar-right">
    <span class="badge badge-live" id="mode-badge">LIVE</span>
    &nbsp;
    <span class="badge badge-$($modeLabel.ToLower())" id="market-mode">$modeLabel MODE</span>
    <div style="margin-top:6px"><span class="live-dot"></span><span id="last-refresh">$genTime</span></div>
  </div>
</div>

<!-- ROW 1: Price + 24h stats -->
<div class="grid4" style="margin-bottom:14px">
  <div class="card">
    <h2>&#128200; Live BTC Price</h2>
    <div class="price-big" id="live-price">$($livePrice.ToString("N2"))</div>
    <div style="margin-top:6px;font-size:.9rem" id="change-el">
      <span id="chg-val" class="$(if($change24h -ge 0){"pos"}else{"neg"})">$(if($change24h -ge 0){"+"})$($change24h)%</span>
      <span style="color:#484f58;margin-left:5px">24h</span>
    </div>
  </div>
  <div class="card">
    <h2>&#128257; 24h Range</h2>
    <div class="row"><span style="color:#8b949e">High</span><span class="pos">$($high24h.ToString("N2"))</span></div>
    <div class="row"><span style="color:#8b949e">Low</span><span class="neg">$($low24h.ToString("N2"))</span></div>
    <div class="row"><span style="color:#8b949e">Volume</span><span>$($vol24h)M USD</span></div>
  </div>
  <div class="card">
    <h2>&#128307; Market Mode</h2>
    <div class="row"><span style="color:#8b949e">SMA200 (4H)</span><span>$($sma200.ToString("N2"))</span></div>
    <div class="row"><span style="color:#8b949e">Price vs SMA200</span><span class="$(if($bullMode){"pos"}else{"neg"})">$(if($bullMode){"+"}else{"-"})$([Math]::Round([Math]::Abs(($livePrice-$sma200)/$sma200*100),2))%</span></div>
    <div class="row"><span style="color:#8b949e">Mode</span><span class="$(if($bullMode){"pos"}else{"neg"})">$modeLabel</span></div>
  </div>
  <div class="card">
    <h2>&#128200; RSI &amp; Dip</h2>
    <div class="row"><span style="color:#8b949e">RSI (4H)</span><span id="rsi-val">$rsi4h</span></div>
    <div class="row"><span style="color:#8b949e">Dip from 5d-high</span><span>$dipPct%</span></div>
    <div class="row"><span style="color:#8b949e">Next entry RSI</span><span class="$(if($rsi4h -le $nextRsiThresh){"pos"}else{"neu"})">< $nextRsiThresh</span></div>
  </div>
</div>

<!-- ROW 2: Position + Exit Targets + PnL Table -->
<div class="grid2" style="margin-bottom:14px">

  <!-- POSITION -->
  <div class="card">
    <h2>&#127919; Current Position</h2>
    <div id="pos-section">
      $(if ($inPosition -and $avgEntry -gt 0) {
        $pnlColor = if($currentPnlPct -ge 0){"pos"}else{"neg"}
        $pnlSign  = if($currentPnlPct -ge 0){"+"}else{""}
        @"
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
        <div>
          <div class="stat-label">Live P&amp;L</div>
          <div class="pnl-big $pnlColor" id="live-pnl">$pnlSign$($currentPnlPct)% ($($currentPnlUsd.ToString("N2")))</div>
        </div>
        <span class="tag tag-ok">OPEN</span>
      </div>
      <div class="divider"></div>
      <div class="row"><span class="stat-label">Avg entry price</span><span class="stat-val-sm">$($avgEntry.ToString("N2"))</span></div>
      <div class="row"><span class="stat-label">Total BTC held</span><span class="stat-val-sm">$($totalQty.ToString("0.00000")) BTC</span></div>
      <div class="row"><span class="stat-label">Total cost</span><span class="stat-val-sm">$($totalCost.ToString("N2"))</span></div>
      <div class="row"><span class="stat-label">Tranches filled</span><span class="stat-val-sm">$trancheCnt / 3</span></div>
      <div class="row"><span class="stat-label">Peak price since entry</span><span class="stat-val-sm pos">$($peakPrice.ToString("N2"))</span></div>
      <div class="row"><span class="stat-label">Hold time</span><span class="stat-val-sm">$holdHours hours</span></div>
"@
      } else {
        @"
      <div style="text-align:center;padding:20px 0">
        <div style="font-size:1.4rem;font-weight:700;color:#8b949e">NOT IN POSITION</div>
        <div style="font-size:.8rem;color:#484f58;margin-top:8px">Watching for RSI dip entry</div>
        <div style="font-size:.8rem;color:#484f58;margin-top:4px">Tranches filled: $trancheCnt / 3</div>
      </div>
      <div class="divider"></div>
      <div class="row"><span class="stat-label">Last signal</span><span class="stat-val-sm" style="color:#58a6ff;font-size:.75rem">$($state.last_signal)</span></div>
      <div class="row"><span class="stat-label">Last run</span><span class="stat-val-sm">$($state.last_run.ToString().Substring(0, [Math]::Min(19, $state.last_run.ToString().Length)))</span></div>
"@
      })
    </div>
  </div>

  <!-- EXIT TARGETS -->
  <div class="card">
    <h2>&#127987; Exit Targets &amp; Stop Levels</h2>
    <div class="target-card">
      <div class="target-row target-rsi">
        <div>
          <div style="font-weight:700;color:#3fb950">RSI Exit (Take Profit)</div>
          <div style="font-size:.72rem;color:#8b949e;margin-top:2px">When RSI(4H) crosses above $rsiExit</div>
        </div>
        <div style="text-align:right">
          <div style="color:#3fb950;font-weight:700;font-size:.9rem">RSI $rsiExit target</div>
          <div style="font-size:.72rem;color:#8b949e">Current RSI: $rsi4h</div>
        </div>
      </div>
      <div class="target-row target-trail">
        <div>
          <div style="font-weight:700;color:#d29922">Trailing Stop ($trailPct%)</div>
          <div style="font-size:.72rem;color:#8b949e;margin-top:2px">$(if($trailActive){"ACTIVE"}else{"Arms in $trailArmedIn h (min hold: $minHold h)"})</div>
        </div>
        <div style="text-align:right">
          <div style="color:#d29922;font-weight:700;font-size:.9rem">$(if($trailStopPrice -gt 0){ '$' + $trailStopPrice.ToString("N2") }else{"N/A"})</div>
          <div style="font-size:.72rem;color:#8b949e">Peak: $(if($peakPrice -gt 0){'$'+$peakPrice.ToString("N2")}else{"--"})</div>
        </div>
      </div>
      <div class="target-row target-hard">
        <div>
          <div style="font-weight:700;color:#f85149">Hard Stop Loss ($hardPct%)</div>
          <div style="font-size:.72rem;color:#8b949e;margin-top:2px">Fires immediately regardless of hold time</div>
        </div>
        <div style="text-align:right">
          <div style="color:#f85149;font-weight:700;font-size:.9rem">$(if($hardStopPrice -gt 0){ '$' + $hardStopPrice.ToString("N2") }else{"N/A"})</div>
          <div style="font-size:.72rem;color:#8b949e">Avg entry: $(if($avgEntry -gt 0){'$'+$avgEntry.ToString("N2")}else{"--"})</div>
        </div>
      </div>
      <div class="target-row target-hold">
        <div>
          <div style="font-weight:700;color:#8b949e">Min Hold Before Trail</div>
          <div style="font-size:.72rem;color:#8b949e;margin-top:2px">Protects against premature exit</div>
        </div>
        <div style="text-align:right">
          <div style="font-weight:700;font-size:.9rem">$holdHours h / $minHold h</div>
          <div style="font-size:.72rem;color:$(if($trailActive){"#3fb950"}else{"#d29922"})">$(if($trailActive){"Trail ACTIVE"}else{"Trail PENDING"})</div>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- ROW 3: P&L Projection Table -->
<div class="card" style="margin-bottom:14px">
  <h2>&#128181; Projected P&amp;L at Different Price Levels $(if($inPosition){"(based on avg entry: `$$($avgEntry.ToString("N2"))  |  qty: $($totalQty.ToString("0.00000")) BTC)"}else{"(not in position -- using live price as reference)"})</h2>
  <div style="overflow-x:auto">
  <table class="pnl-table">
    <thead>
      <tr>
        <th>Price Change</th>
        <th>BTC Price</th>
        <th>P&amp;L %</th>
        <th>P&amp;L (USD)</th>
        <th>Note</th>
      </tr>
    </thead>
    <tbody>
      $scenarioRows
    </tbody>
  </table>
  </div>
</div>

<!-- ROW 4: Entry Conditions + News + Runs -->
<div class="grid3">

  <!-- ENTRY CONDITIONS -->
  <div class="card">
    <h2>&#9654; Entry Conditions (Next Tranche: $($trancheCnt+1)/3)</h2>
    $(
    $rsiOk   = ($rsi4h -le $nextRsiThresh)
    $dipOk   = ($dipPct -ge $dipThresh)
    $newsOk  = (-not $newsBlock)
    $rsiDiff = [Math]::Round($rsi4h - $nextRsiThresh, 1)
    $dipDiff = [Math]::Round($dipThresh - $dipPct, 2)

    $rsiClass  = if($rsiOk){"cond-ok"}elseif($rsiDiff -le 5){"cond-close"}else{"cond-no"}
    $dipClass  = if($dipOk){"cond-ok"}elseif($dipDiff -le 1){"cond-close"}else{"cond-no"}
    $newsClass = if($newsOk){"cond-ok"}else{"cond-no"}

    $rsiProg  = [Math]::Min(100, [Math]::Max(0, [Math]::Round((1 - $rsiDiff/20)*100)))
    $dipProg  = [Math]::Min(100, [Math]::Max(0, [Math]::Round($dipPct/$dipThresh*100)))

    @"
    <div class="cond-row">
      <div>
        <div>RSI(4H) &lt; $nextRsiThresh ($modeLabel mode)</div>
        <div class="progress-wrap"><div class="progress-fill" style="width:$rsiProg%;background:$(if($rsiOk){"#3fb950"}elseif($rsiDiff -le 5){"#d29922"}else{"#f85149"})"></div></div>
      </div>
      <span class="$rsiClass">$rsi4h $(if($rsiOk){"OK"}else{"(-$rsiDiff)"})</span>
    </div>
    <div class="cond-row">
      <div>
        <div>Dip &ge; $dipThresh% from 5-day high</div>
        <div class="progress-wrap"><div class="progress-fill" style="width:$dipProg%;background:$(if($dipOk){"#3fb950"}elseif($dipDiff -le 1){"#d29922"}else{"#f85149"})"></div></div>
      </div>
      <span class="$dipClass">$dipPct% $(if($dipOk){"OK"}else{"(-$dipDiff%)"})</span>
    </div>
    <div class="cond-row">
      <span>News score (not blocked)</span>
      <span class="$newsClass">$newsScore $(if($newsOk){"OK"}else{"BLOCKED"})</span>
    </div>
    <div class="cond-row">
      <span>News boost (skip dip req)</span>
      <span class="$(if($newsBoost){"cond-ok"}else{"neu"})">$(if($newsBoost){"YES"}else{"No ($newsBoostTh+ needed)"})</span>
    </div>
    <div class="cond-row">
      <span>Market mode</span>
      <span class="$(if($bullMode){"cond-ok"}else{"cond-no"})">$modeLabel</span>
    </div>
    <div class="divider"></div>
    <div style="font-size:.78rem;color:#8b949e">Thresholds &mdash; T1:RSI&lt;$t1Thresh  T2:RSI&lt;$t2Thresh  T3:RSI&lt;$t3Thresh  Dip&ge;$dipThresh%</div>
"@
    )
  </div>

  <!-- NEWS -->
  <div class="card">
    <h2>&#128240; News Sentiment</h2>
    $(
    $sc = $newsScore
    $cl = if($sc -ge 5){"#3fb950"}elseif($sc -le -5){"#f85149"}elseif($sc -ge 3){"#3fb950"}elseif($sc -le -3){"#f85149"}else{"#d29922"}
    $sl = if($sc -ge 5){"STRONGLY BULLISH"}elseif($sc -ge 3){"BULLISH"}elseif($sc -le -5){"STRONGLY BEARISH"}elseif($sc -le -3){"BEARISH"}else{"NEUTRAL"}
    $sp = [Math]::Round([Math]::Abs($sc)/10*100)
    $headlines = if($news -and $news.key_items){ @($news.key_items) | Select-Object -First 3 } else { @() }
    $hlHtml = ($headlines | ForEach-Object { "<div style='font-size:.73rem;color:#8b949e;padding:3px 0;border-bottom:1px solid #21262d'>&bull; $($_.ToString().Substring(0,[Math]::Min(90,$_.ToString().Length)))</div>" }) -join ""
    @"
    <div style="display:flex;align-items:center;gap:14px;margin-bottom:10px">
      <div class="news-score" style="color:$cl">$(if($sc -ge 0){"+"})$sc</div>
      <div style="flex:1">
        <div style="color:$cl;font-weight:700;font-size:.9rem">$sl</div>
        <div class="sbar"><div class="sfill" style="width:$sp%;background:$cl"></div></div>
        <div style="font-size:.7rem;color:#8b949e">$(if($news){"$($news.article_count) articles  |  cached $([Math]::Round((New-TimeSpan -Start ([datetime]$news.timestamp) -End (Get-Date)).TotalHours,1))h ago"}else{"No data"})</div>
      </div>
    </div>
    <div class="divider"></div>
    $hlHtml
    <div class="divider"></div>
    <div class="row"><span style="color:#8b949e">Block entries</span><span class="$(if($newsBlock){"neg"}else{"pos"})">$(if($newsBlock){"YES (score $sc <= $newsBlockTh)"}else{"No"})</span></div>
    <div class="row"><span style="color:#8b949e">Boost entry (skip dip)</span><span class="$(if($newsBoost){"pos"}else{"neu"})">$(if($newsBoost){"YES"}else{"No (need $newsBoostTh+)"})</span></div>
    <div class="row"><span style="color:#8b949e">Reasoning</span></div>
    <div style="font-size:.73rem;color:#8b949e;padding:4px 0">$(if($news -and $news.reasoning){ $news.reasoning.ToString().Substring(0,[Math]::Min(140,$news.reasoning.ToString().Length)) }else{"N/A"})</div>
"@
    )
  </div>

  <!-- RUN HISTORY -->
  <div class="card">
    <h2>&#9889; Recent Bot Runs</h2>
    $(
    if ($runs.Count -gt 0) {
        ($runs | ForEach-Object {
            $dt   = if($_.startedAt){ $_.startedAt.ToString().Substring(0,16).Replace("T"," ") + " UTC" } else { "" }
            $dot  = if($_.status -eq "in_progress"){"dot-run"}elseif($_.conclusion -eq "success"){"dot-ok"}else{"dot-fail"}
            $conc = if($_.conclusion){"$($_.conclusion)"}elseif($_.status){"$($_.status)"}else{""}
            $tagc = if($conc -eq "success"){"tag-ok"}elseif($conc -eq "failure"){"tag-fail"}else{"tag-neu"}
            $ev   = if($_.event -eq "schedule"){"[cron]"}else{"[manual]"}
            "<div class='run-row'><div><span class='dot $dot'></span><span style='color:#8b949e'>$dt</span></div><span style='color:#484f58;font-size:.7rem;margin:0 6px'>$ev</span><span class='tag $tagc'>$($conc.ToUpper())</span></div>"
        }) -join ""
    } else {
        "<span style='color:#484f58'>No run data available</span>"
    }
    )
  </div>
</div>

<div style="text-align:center;color:#484f58;font-size:.7rem;margin-top:16px">
  Price auto-refreshes every 10s &nbsp;|&nbsp; Dashboard generated $genTime &nbsp;|&nbsp; BTC Dip Ladder Bot v2
</div>

<script>
const PAPER = $paperTrading;
const AVG_ENTRY  = $avgEntry;
const TOTAL_QTY  = $totalQty;
const IN_POS     = $($inPosition.ToString().ToLower());

document.getElementById('mode-badge').textContent = PAPER ? 'PAPER' : 'LIVE';
if(PAPER) document.getElementById('mode-badge').className = 'badge badge-paper';

async function fetchPrice() {
  try {
    const r = await fetch('https://api.binance.us/api/v3/ticker/price?symbol=BTCUSD');
    const d = await r.json();
    const p = parseFloat(d.price);
    const fmt = v => v.toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2});

    document.getElementById('live-price').textContent = '$' + fmt(p);

    if (IN_POS && AVG_ENTRY > 0 && TOTAL_QTY > 0) {
      const pnlPct = ((p - AVG_ENTRY) / AVG_ENTRY) * 100;
      const pnlUsd = (p - AVG_ENTRY) * TOTAL_QTY;
      const sign   = pnlPct >= 0 ? '+' : '';
      const el     = document.getElementById('live-pnl');
      if (el) {
        el.textContent = sign + pnlPct.toFixed(2) + '%  ($' + (pnlUsd >= 0 ? '+' : '') + pnlUsd.toFixed(2) + ')';
        el.className   = 'pnl-big ' + (pnlPct >= 0 ? 'pos' : 'neg');
      }
    }

    const now = new Date().toISOString().replace('T',' ').slice(0,16) + ' UTC';
    const el2 = document.getElementById('last-refresh');
    if(el2) el2.textContent = 'Live  ' + now;
  } catch(e){}
}

fetchPrice();
setInterval(fetchPrice, 10000);
</script>
</body>
</html>
"@

[System.IO.File]::WriteAllText($OutFile, $html, [System.Text.Encoding]::UTF8)
Write-Host "Dashboard written: $OutFile"

if (-not $GenerateOnly) {
    Write-Host "Opening in browser..."
    Start-Process $OutFile
}
