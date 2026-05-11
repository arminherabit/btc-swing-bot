# BTC Swing Bot Dashboard Generator
# Pulls latest state from GitHub, computes indicators, generates dashboard.html, opens in browser.

param([switch]$GenerateOnly)   # set by CI to skip git pull and browser open

$BaseUrl    = "https://api.binance.us"
$KlineUrl   = "$BaseUrl/api/v3/klines"
$Symbol     = "BTCUSD"
$KlineLimit = 100
$OutFile    = Join-Path $PSScriptRoot "dashboard.html"

# -- Pull latest state from GitHub (skip in CI) --
if (-not $GenerateOnly) {
    Write-Host "Pulling latest state from GitHub..."
    git -C $PSScriptRoot pull --quiet 2>&1 | Out-Null
}

# -- Load state files --
$StatePath  = Join-Path $PSScriptRoot "btc_state.json"
$NewsPath   = Join-Path $PSScriptRoot "btc_news_cache.json"
$CfgPath    = Join-Path $PSScriptRoot "btc_config.json"

$state = if (Test-Path $StatePath) { Get-Content $StatePath | ConvertFrom-Json } else { [pscustomobject]@{inPosition=$false;entryPrice=0;qty=0;target=0;stopLoss=0} }
$news  = if (Test-Path $NewsPath)  { Get-Content $NewsPath  | ConvertFrom-Json } else { $null }
$cfg   = if (Test-Path $CfgPath)   { Get-Content $CfgPath   | ConvertFrom-Json } else { $null }

# -- Indicator helpers --
function Get-EMAArray([double[]]$c,[int]$n){
    if($c.Count -lt $n){return $null}
    $k=2.0/($n+1);$arr=[double[]]::new($c.Count)
    $s=0.0;for($i=0;$i -lt $n;$i++){$s+=$c[$i]};$arr[$n-1]=$s/$n
    for($i=$n;$i -lt $c.Count;$i++){$arr[$i]=$c[$i]*$k+$arr[$i-1]*(1-$k)}
    return $arr
}
function Get-RSI([double[]]$c,[int]$p=14){
    if($c.Count -lt ($p+1)){return $null}
    $g=[double[]]::new($c.Count-1);$l=[double[]]::new($c.Count-1)
    for($i=1;$i -lt $c.Count;$i++){$d=$c[$i]-$c[$i-1];if($d -gt 0){$g[$i-1]=$d}else{$l[$i-1]=[Math]::Abs($d)}}
    $ag=0.0;$al=0.0
    for($i=0;$i -lt $p;$i++){$ag+=$g[$i];$al+=$l[$i]}
    $ag/=$p;$al/=$p
    for($i=$p;$i -lt $g.Count;$i++){$ag=($ag*($p-1)+$g[$i])/$p;$al=($al*($p-1)+$l[$i])/$p}
    if($al -eq 0){return 100.0}
    return [Math]::Round(100-(100/(1+$ag/$al)),2)
}
function Get-MACDCross([double[]]$c){
    $e12=Get-EMAArray $c 12;$e26=Get-EMAArray $c 26
    if($null -eq $e12 -or $null -eq $e26){return $false}
    $ml=[double[]]::new($c.Count)
    for($i=25;$i -lt $c.Count;$i++){$ml[$i]=$e12[$i]-$e26[$i]}
    [double[]]$vm=$ml[25..($c.Count-1)]
    $sigArr=Get-EMAArray $vm 9;if($null -eq $sigArr){return $false}
    [double]$mv=$vm[$vm.Count-1];[double]$sv=$sigArr[$sigArr.Count-1]
    [double]$mp=$vm[$vm.Count-2];[double]$sp=$sigArr[$sigArr.Count-2]
    return ($mv -gt $sv)
}

# -- Fetch indicators for one timeframe --
function Get-TFData([string]$interval) {
    try {
        $url  = $KlineUrl+"?symbol="+$Symbol+"&interval="+$interval+"&limit="+$KlineLimit
        $data = Invoke-RestMethod -Uri $url -UseBasicParsing
        [double[]]$closes=$data|ForEach-Object{[double]$_[4]}
        [double[]]$lows  =$data|ForEach-Object{[double]$_[3]}
        $close    = $closes[$closes.Count-1]
        $ema50Arr = Get-EMAArray $closes 50
        $ema50    = if($ema50Arr){$ema50Arr[$ema50Arr.Count-1]}else{0}
        $emaDist  = if($ema50 -gt 0){[Math]::Round([Math]::Abs($close-$ema50)/$ema50*100,2)}else{0}
        $nearEMA  = $emaDist -le 2.0
        $rsiArr   = @(); $rsiNow=0;$rsiPrev=0
        if($closes.Count -ge 15){
            $rsiNow  = Get-RSI $closes 14
            # re-compute on N-1
            [double[]]$c2=$closes[0..($closes.Count-2)]
            $rsiPrev = Get-RSI $c2 14
        }
        $rsiExit  = ($rsiPrev -lt 35) -and ($rsiNow -gt $rsiPrev) -and ($rsiNow -lt 55)
        $macdCross= Get-MACDCross $closes
        $conf=0;if($nearEMA){$conf++};if($rsiExit){$conf++};if($macdCross){$conf++}
        [double[]]$lowSlice=$lows[[Math]::Max(0,$lows.Count-20)..($lows.Count-1)]
        $swingLow = ($lowSlice|Measure-Object -Minimum).Minimum
        return [pscustomobject]@{
            Close=$close;EMA50=[Math]::Round($ema50,2);EMADist=$emaDist;NearEMA=$nearEMA
            RSI=$rsiNow;RSIPrev=$rsiPrev;RSIExit=$rsiExit;MACDCross=$macdCross
            Conf=$conf;SwingLow=[Math]::Round($swingLow,2)
        }
    } catch { return $null }
}

Write-Host "Fetching indicators..."
$d1d = Get-TFData "1d"
$d4h = Get-TFData "4h"

# -- Get last 10 bot runs via gh CLI --
$runs = @()
try {
    $env:PATH = $env:PATH + ";C:\Program Files\GitHub CLI"
    $rawRuns = gh run list --repo arminherabit/btc-swing-bot --limit 10 --json "databaseId,status,conclusion,startedAt,displayTitle" 2>$null | ConvertFrom-Json
    $runs = $rawRuns | ForEach-Object {
        [pscustomobject]@{
            id         = $_.databaseId
            status     = $_.status
            conclusion = $_.conclusion
            startedAt  = $_.startedAt
            title      = $_.displayTitle
        }
    }
} catch { }

# -- Get 24h price change --
$priceChange24h = 0
try {
    $ticker = Invoke-RestMethod -Uri "$BaseUrl/api/v3/ticker/24hr?symbol=$Symbol" -UseBasicParsing
    $priceChange24h = [Math]::Round([double]$ticker.priceChangePercent, 2)
} catch { }

# -- Prepare JSON blobs for embedding --
$stateJson = $state | ConvertTo-Json -Compress
$newsJson  = if($news){ $news | ConvertTo-Json -Compress -Depth 5 }else{"null"}
$d1dJson   = if($d1d) { $d1d  | ConvertTo-Json -Compress }else{"null"}
$d4hJson   = if($d4h) { $d4h  | ConvertTo-Json -Compress }else{"null"}
$runsJson  = $runs | ConvertTo-Json -Compress -Depth 3
$genTime   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")

# ============================================================
# Generate HTML
# ============================================================
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>BTC Swing Bot Dashboard</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:#0d1117;color:#c9d1d9;font-family:'Segoe UI',system-ui,sans-serif;min-height:100vh;padding:20px}
  h1{font-size:1.4rem;font-weight:600;color:#f0f6fc;letter-spacing:.5px}
  h2{font-size:.75rem;font-weight:600;text-transform:uppercase;letter-spacing:1px;color:#8b949e;margin-bottom:12px}
  .header{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px;padding-bottom:16px;border-bottom:1px solid #21262d}
  .header-right{text-align:right;font-size:.8rem;color:#8b949e}
  .badge{display:inline-block;padding:2px 10px;border-radius:20px;font-size:.7rem;font-weight:600;letter-spacing:.5px}
  .badge-live{background:#1a4731;color:#3fb950;border:1px solid #238636}
  .badge-paper{background:#271a0c;color:#d29922;border:1px solid #9e6a03}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px;margin-bottom:16px}
  .grid-wide{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:16px}
  .card{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:20px}
  .card-full{grid-column:1/-1}
  .price-big{font-size:2.6rem;font-weight:700;color:#f0f6fc;letter-spacing:-1px;font-variant-numeric:tabular-nums}
  .change-pos{color:#3fb950;font-size:1rem;font-weight:600}
  .change-neg{color:#f85149;font-size:1rem;font-weight:600}
  .change-neu{color:#8b949e;font-size:1rem}
  .label{font-size:.75rem;color:#8b949e;margin-bottom:4px}
  .value{font-size:1rem;font-weight:600;color:#f0f6fc}
  .value-sm{font-size:.85rem;color:#c9d1d9}
  .pnl-pos{color:#3fb950;font-weight:700;font-size:1.1rem}
  .pnl-neg{color:#f85149;font-weight:700;font-size:1.1rem}
  .pnl-neu{color:#8b949e;font-weight:700;font-size:1.1rem}
  .row{display:flex;justify-content:space-between;align-items:center;padding:6px 0;border-bottom:1px solid #21262d}
  .row:last-child{border-bottom:none}
  .check{display:inline-block;width:18px;height:18px;border-radius:50%;text-align:center;line-height:18px;font-size:.65rem;font-weight:700;margin-right:8px;flex-shrink:0}
  .check-ok{background:#1a4731;color:#3fb950}
  .check-no{background:#1c1c22;color:#484f58;border:1px solid #30363d}
  .sentiment-bar{height:8px;border-radius:4px;background:#21262d;margin:8px 0;overflow:hidden;position:relative}
  .sentiment-fill{height:100%;border-radius:4px;transition:width .5s}
  .score-num{font-size:2rem;font-weight:700}
  .gauge{display:flex;align-items:center;gap:12px;margin:8px 0}
  .run-row{display:flex;justify-content:space-between;align-items:center;padding:7px 0;border-bottom:1px solid #21262d;font-size:.8rem}
  .run-row:last-child{border-bottom:none}
  .dot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:6px}
  .dot-success{background:#3fb950}
  .dot-failure{background:#f85149}
  .dot-running{background:#d29922;animation:pulse 1s infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
  .tag{padding:2px 8px;border-radius:4px;font-size:.7rem;font-weight:600}
  .tag-bull{background:#1a4731;color:#3fb950}
  .tag-bear{background:#2d1c1c;color:#f85149}
  .tag-neu{background:#1c2128;color:#8b949e}
  .tag-watch{background:#1c2128;color:#58a6ff}
  .tag-open{background:#1a4731;color:#3fb950}
  .divider{height:1px;background:#21262d;margin:10px 0}
  .live-dot{width:8px;height:8px;border-radius:50%;background:#3fb950;display:inline-block;margin-right:6px;animation:pulse 1.5s infinite}
  .conf-pill{display:flex;gap:4px;margin-top:8px}
  .pill{width:28px;height:8px;border-radius:4px}
  .pill-on{background:#3fb950}
  .pill-off{background:#21262d}
  .refresh-btn{background:#21262d;border:1px solid #30363d;color:#8b949e;padding:4px 12px;border-radius:6px;cursor:pointer;font-size:.75rem}
  .refresh-btn:hover{background:#30363d;color:#c9d1d9}
  footer{text-align:center;color:#484f58;font-size:.72rem;margin-top:20px}
</style>
</head>
<body>

<div class="header">
  <div>
    <h1>&#8383; BTC/USD Swing Bot</h1>
    <span style="font-size:.78rem;color:#8b949e">github.com/arminherabit/btc-swing-bot</span>
  </div>
  <div class="header-right">
    <span class="badge badge-live" id="mode-badge">LIVE</span>
    <div style="margin-top:6px"><span class="live-dot"></span><span id="last-update">Generated $genTime UTC</span></div>
    <div style="margin-top:4px"><button class="refresh-btn" onclick="location.reload()">&#8635; Refresh</button></div>
  </div>
</div>

<div class="grid">

  <!-- PRICE CARD -->
  <div class="card">
    <h2>&#128200; Live Price</h2>
    <div class="price-big" id="price">&#8230;</div>
    <div style="margin-top:6px">
      <span id="change24h" class="change-neu">&#8230;</span>
      <span style="color:#484f58;font-size:.8rem;margin-left:6px">24h</span>
    </div>
    <div class="divider"></div>
    <div class="row">
      <span class="label">EMA50 (daily)</span>
      <span class="value-sm" id="ema50-val">&#8230;</span>
    </div>
    <div class="row">
      <span class="label">Distance to EMA50</span>
      <span class="value-sm" id="ema-dist">&#8230;</span>
    </div>
  </div>

  <!-- POSITION CARD -->
  <div class="card" id="position-card">
    <h2>&#127919; Position</h2>
    <div id="pos-content">loading...</div>
  </div>

  <!-- NEWS CARD -->
  <div class="card">
    <h2>&#128240; News Sentiment</h2>
    <div id="news-content">loading...</div>
  </div>

  <!-- TECHNICAL CARD -->
  <div class="card">
    <h2>&#128202; Technical Signals</h2>
    <div id="tech-content">loading...</div>
  </div>

</div>

<!-- RUNS TABLE -->
<div class="card">
  <h2>&#9889; Recent Bot Runs</h2>
  <div id="runs-content">loading...</div>
</div>

<footer style="margin-top:18px">
  Price auto-refreshes every 10 s &nbsp;|&nbsp; Dashboard generated $genTime UTC &nbsp;|&nbsp; BTC Swing Bot v1.0
</footer>

<script>
const STATE = $stateJson;
const NEWS  = $newsJson;
const D1D   = $d1dJson;
const D4H   = $d4hJson;
const RUNS  = $runsJson;
const CHANGE24H = $priceChange24h;
const PAPER_TRADING = false;

function fmt(n){ return n.toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2}); }
function fmtPct(n){ return (n>=0?'+':'')+n.toFixed(2)+'%'; }

// ---- MODE BADGE ----
document.getElementById('mode-badge').textContent = PAPER_TRADING ? 'PAPER' : 'LIVE';
if(PAPER_TRADING){ document.getElementById('mode-badge').className='badge badge-paper'; }

// ---- 24H CHANGE ----
const chEl = document.getElementById('change24h');
if(CHANGE24H > 0){ chEl.className='change-pos'; chEl.textContent = '+'+CHANGE24H.toFixed(2)+'%'; }
else if(CHANGE24H < 0){ chEl.className='change-neg'; chEl.textContent = CHANGE24H.toFixed(2)+'%'; }
else { chEl.textContent = '0.00%'; }

// ---- EMA ----
if(D1D){ document.getElementById('ema50-val').textContent = '$'+fmt(D1D.EMA50); document.getElementById('ema-dist').textContent = D1D.EMADist+'%'; }

// ---- POSITION ----
(function(){
  const el = document.getElementById('pos-content');
  if(!STATE || !STATE.inPosition){
    el.innerHTML = '<div style="color:#8b949e;font-size:1.5rem;font-weight:700;padding:10px 0">NOT IN POSITION</div><div style="color:#484f58;font-size:.8rem;margin-top:4px">Watching for swing entry signal</div>';
    return;
  }
  const entry = STATE.entryPrice;
  const qty   = STATE.qty;
  const stop  = STATE.stopLoss;
  const tgt   = STATE.target;
  el.innerHTML = `
    <div style="display:flex;justify-content:space-between;align-items:flex-start">
      <div>
        <div class="label">BTC held</div>
        <div class="value">${qty.toFixed(5)} BTC</div>
      </div>
      <span class="tag tag-open">OPEN</span>
    </div>
    <div class="divider"></div>
    <div class="row"><span class="label">Entry price</span><span class="value-sm">$${fmt(entry)}</span></div>
    <div class="row"><span class="label">Current price</span><span class="value-sm" id="pos-current">...</span></div>
    <div class="row"><span class="label">P&amp;L</span><span id="pos-pnl" class="pnl-neu">...</span></div>
    <div class="row"><span class="label">Stop-loss</span><span class="value-sm" style="color:#f85149">$${fmt(stop)}</span></div>
    <div class="row"><span class="label">Target (+15%)</span><span class="value-sm" style="color:#3fb950">$${fmt(tgt)}</span></div>
  `;
})();

// ---- NEWS ----
(function(){
  const el = document.getElementById('news-content');
  if(!NEWS){ el.innerHTML='<span style="color:#484f58">No news data</span>'; return; }
  const score = NEWS.score || 0;
  const maxAbs = 10;
  const pct    = Math.min(Math.abs(score)/maxAbs*100,100);
  const color  = score>=3?'#3fb950':score<=-3?'#f85149':'#d29922';
  const label  = score>=5?'STRONGLY BULLISH':score>=3?'BULLISH':score<=-5?'STRONGLY BEARISH':score<=-3?'BEARISH':'NEUTRAL';
  const recColor = NEWS.recommendation==='boost_size'?'#3fb950':NEWS.recommendation==='block_trade'?'#f85149':'#d29922';
  const headlines = Array.isArray(NEWS.key_items) ? NEWS.key_items.slice(0,3) : [];
  const hlHtml = headlines.map(h=>`<div style="font-size:.75rem;color:#8b949e;padding:3px 0;border-bottom:1px solid #21262d">&bull; ${h.length>80?h.slice(0,80)+'...':h}</div>`).join('');
  el.innerHTML = `
    <div class="gauge">
      <div class="score-num" style="color:${color}">${score>=0?'+':''}${score}</div>
      <div style="flex:1">
        <div style="color:${color};font-weight:700;font-size:.85rem">${label}</div>
        <div class="sentiment-bar"><div class="sentiment-fill" style="width:${pct}%;background:${color}"></div></div>
        <div style="color:${recColor};font-size:.72rem;font-weight:600;text-transform:uppercase;letter-spacing:.5px">${(NEWS.recommendation||'').replace('_',' ')}</div>
      </div>
    </div>
    <div class="divider"></div>
    ${hlHtml}
    <div style="font-size:.72rem;color:#484f58;margin-top:6px">${NEWS.article_count||0} articles analyzed</div>
  `;
})();

// ---- TECHNICAL ----
(function(){
  const el = document.getElementById('tech-content');
  if(!D1D||!D4H){ el.innerHTML='<span style="color:#484f58">No indicator data</span>'; return; }
  function checkHtml(ok,label,detail){
    return `<div class="row"><div style="display:flex;align-items:center"><span class="check ${ok?'check-ok':'check-no'}">${ok?'&#10003;':'&#9679;'}</span><span style="font-size:.82rem">${label}</span></div><span style="font-size:.75rem;color:#484f58">${detail}</span></div>`;
  }
  function pillsHtml(n){
    let h='<div class="conf-pill">';
    for(let i=0;i<3;i++) h+=`<div class="pill ${i<n?'pill-on':'pill-off'}"></div>`;
    return h+'</div>';
  }
  const c1 = D1D.Conf; const c4 = D4H.Conf;
  const entryReady = (c1===3 && c4>=2);
  el.innerHTML = `
    <div style="display:flex;justify-content:space-between;margin-bottom:10px">
      <div>
        <div class="label">Daily</div>
        <div style="font-weight:700;color:${c1===3?'#3fb950':c1===2?'#d29922':'#8b949e'}">${c1}/3 confirmed</div>
        ${pillsHtml(c1)}
      </div>
      <div>
        <div class="label">4-Hour</div>
        <div style="font-weight:700;color:${c4>=2?'#3fb950':c4===1?'#d29922':'#8b949e'}">${c4}/3 confirmed</div>
        ${pillsHtml(c4)}
      </div>
      <div style="text-align:right">
        <div class="label">Entry</div>
        <span class="tag ${entryReady?'tag-open':'tag-neu'}">${entryReady?'READY':'WATCHING'}</span>
      </div>
    </div>
    <div class="divider"></div>
    ${checkHtml(D1D.NearEMA,'Price within 2% of EMA50','Daily '+D1D.EMADist+'% away')}
    ${checkHtml(D1D.RSIExit,'RSI exiting oversold','RSI '+D1D.RSI+' (prev '+D1D.RSIPrev+')')}
    ${checkHtml(D1D.MACDCross,'MACD bullish crossover','Daily MACD')}
    ${checkHtml(D4H.Conf>=2,'4H confirms (2+ of 3)','4H score '+D4H.Conf+'/3')}
    <div class="divider"></div>
    <div class="row"><span class="label">Daily swing low (stop ref)</span><span class="value-sm" style="color:#f85149">$${fmt(D1D.SwingLow)}</span></div>
    <div class="row"><span class="label">RSI (daily)</span><span class="value-sm">${D1D.RSI}</span></div>
  `;
})();

// ---- RUNS TABLE ----
(function(){
  const el = document.getElementById('runs-content');
  if(!RUNS||!RUNS.length){ el.innerHTML='<span style="color:#484f58">No run data (gh CLI required)</span>'; return; }
  const rows = RUNS.map(r=>{
    const dt   = r.startedAt ? new Date(r.startedAt).toISOString().replace('T',' ').slice(0,16)+' UTC' : '';
    const dot  = r.status==='in_progress'?'dot-running':r.conclusion==='success'?'dot-success':'dot-failure';
    const conc = r.conclusion||r.status||'';
    return `<div class="run-row">
      <div><span class="dot ${dot}"></span><span style="color:#8b949e;margin-right:10px">${dt}</span></div>
      <div style="color:#c9d1d9;flex:1;padding:0 8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${r.title||''}</div>
      <span class="tag ${conc==='success'?'tag-bull':conc==='failure'?'tag-bear':'tag-neu'}">${conc.toUpperCase()}</span>
    </div>`;
  }).join('');
  el.innerHTML = rows;
})();

// ---- LIVE PRICE FETCHER ----
async function fetchPrice(){
  try {
    const r = await fetch('https://api.binance.us/api/v3/ticker/price?symbol=BTCUSD');
    const d = await r.json();
    const p = parseFloat(d.price);
    document.getElementById('price').textContent = '$'+fmt(p);

    // Update PnL if in position
    if(STATE && STATE.inPosition && STATE.entryPrice>0){
      const cur = document.getElementById('pos-current');
      const pnl = document.getElementById('pos-pnl');
      if(cur) cur.textContent = '$'+fmt(p);
      if(pnl){
        const pnlUsd = (p - STATE.entryPrice) * STATE.qty;
        const pnlPct = ((p - STATE.entryPrice) / STATE.entryPrice) * 100;
        pnl.textContent = (pnlPct>=0?'+':'')+pnlPct.toFixed(2)+'%  ($'+(pnlUsd>=0?'+':'')+pnlUsd.toFixed(2)+')';
        pnl.className = pnlUsd>=0?'pnl-pos':'pnl-neg';
      }
    }
  } catch(e){}
}

fetchPrice();
setInterval(fetchPrice, 10000);
</script>
</body>
</html>
"@

[System.IO.File]::WriteAllText($OutFile, $html, [System.Text.Encoding]::UTF8)
Write-Host "Dashboard written to: $OutFile"

if (-not $GenerateOnly) {
    Write-Host "Opening in browser..."
    Start-Process $OutFile
}
