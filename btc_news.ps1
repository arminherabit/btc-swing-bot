# BTC News Scraper + Claude Sentiment Analyzer
# Scrapes crypto RSS feeds, analyzes with Claude API, returns sentiment score -10..+10.
# Dot-sourced by btc_bot.ps1, or run standalone for a manual snapshot.

$AnthropicUrl   = "https://api.anthropic.com/v1/messages"
$AnthropicModel = "claude-haiku-4-5-20251001"
$CachePath      = Join-Path $PSScriptRoot "btc_news_cache.json"

$NewsSources = @(
    [pscustomobject]@{ Name="Cointelegraph";  Url="https://cointelegraph.com/rss" }
    [pscustomobject]@{ Name="Decrypt";        Url="https://decrypt.co/feed" }
    [pscustomobject]@{ Name="CryptoSlate";    Url="https://cryptoslate.com/feed/" }
    [pscustomobject]@{ Name="NewsBTC";        Url="https://www.newsbtc.com/feed/" }
    [pscustomobject]@{ Name="BitcoinMag";     Url="https://bitcoinmagazine.com/feed" }
    [pscustomobject]@{ Name="UToday";         Url="https://u.today/rss" }
)

# -- Fetch one RSS feed --
function Get-RSSItems([string]$url, [string]$name, [int]$max = 6) {
    $result = [System.Collections.Generic.List[pscustomobject]]::new()
    try {
        $wc      = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (compatible; BTCBot/1.0)")
        $raw     = $wc.DownloadString($url)
        [xml]$xml = $raw
        $items   = $xml.rss.channel.item | Select-Object -First $max
        foreach ($item in $items) {
            $title = if ($item.title."#cdata-section") { $item.title."#cdata-section" } else { "$($item.title)" }
            $desc  = if ($item.description."#cdata-section") { $item.description."#cdata-section" } else { "$($item.description)" }
            $desc  = [System.Text.RegularExpressions.Regex]::Replace($desc, "<[^>]+>", " ")
            $desc  = ($desc -replace "\s+", " ").Trim()
            if ($desc.Length -gt 180) { $desc = $desc.Substring(0, 180) + "..." }
            if ($title.Trim().Length -gt 0) {
                $result.Add([pscustomobject]@{
                    Source  = $name
                    Title   = $title.Trim()
                    Summary = $desc
                })
            }
        }
    } catch { }
    return $result
}

# -- Call Claude to analyze headlines --
function Invoke-ClaudeSentiment([string]$apiKey, [object[]]$articles) {
    $lines = ($articles | ForEach-Object { "[$($_.Source)] $($_.Title) -- $($_.Summary)" }) -join "`n"

    # Single prompt, no here-string so no backtick escaping issues
    $prompt = "You are a professional Bitcoin market analyst. Analyze these recent crypto news headlines and assess their likely impact on Bitcoin price over the next 1-7 days (swing trading timeframe).`n`nNEWS:`n" + $lines + "`n`nReturn ONLY a raw JSON object with NO markdown formatting, NO code fences, just the JSON:`n{`"score`": <integer -10 to +10>, `"sentiment`": `"<strongly_bearish|bearish|neutral|bullish|strongly_bullish>`", `"recommendation`": `"<block_trade|reduce_size|proceed|boost_size>`", `"key_items`": [`"<top headline 1>`", `"<top headline 2>`", `"<top headline 3>`"], `"reasoning`": `"<2 sentences on overall BTC impact>`", `"risks`": `"<biggest downside risk in 1 sentence>`"}`n`nScoring: -10 to -7 = crash catalyst, -6 to -3 = bearish, -2 to +2 = neutral, +3 to +6 = bullish, +7 to +10 = major bullish catalyst. Recommendation: block_trade if score<=-3, reduce_size if -2 to 0, proceed if +1 to +4, boost_size if >=+5."

    $bodyObj = [ordered]@{
        model      = $AnthropicModel
        max_tokens = 800
        messages   = @(@{ role = "user"; content = $prompt })
    }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(($bodyObj | ConvertTo-Json -Depth 10))

    try {
        $resp = Invoke-RestMethod -Uri $AnthropicUrl -Method POST `
            -Headers @{ "x-api-key" = $apiKey; "anthropic-version" = "2023-06-01"; "content-type" = "application/json" } `
            -Body $bodyBytes -UseBasicParsing
        $text = $resp.content[0].text.Trim()

        # Strip any code fences Claude might add despite instructions (single-quoted regex = no PS escaping)
        $text = $text -replace '(?s)^```[a-z]*\s*', '' -replace '\s*```$', ''
        $text = $text.Trim()

        # If response doesn't start with {, try to extract the JSON object
        if (-not $text.StartsWith("{")) {
            $match = [System.Text.RegularExpressions.Regex]::Match($text, '\{[\s\S]+\}')
            if ($match.Success) { $text = $match.Value }
        }

        return $text | ConvertFrom-Json
    } catch {
        return $null
    }
}

# -- Load cache if still fresh --
function Get-CachedNews([int]$maxAgeHours) {
    if (-not (Test-Path $CachePath)) { return $null }
    try {
        $cache = Get-Content $CachePath | ConvertFrom-Json
        $age   = (New-TimeSpan -Start ([datetime]$cache.timestamp) -End (Get-Date)).TotalHours
        if ($age -le $maxAgeHours) { return $cache }
    } catch { }
    return $null
}

# -- Main function called by the bot --
function Get-Newssentiment([string]$apiKey, [int]$cacheHours = 4) {

    $cached = Get-CachedNews $cacheHours
    if ($null -ne $cached) {
        return [pscustomobject]@{
            Score          = [int]$cached.score
            Sentiment      = "$($cached.sentiment)"
            Recommendation = "$($cached.recommendation)"
            KeyItems       = @($cached.key_items)
            Reasoning      = "$($cached.reasoning)"
            Risks          = "$($cached.risks)"
            FromCache      = $true
            CacheAge       = [Math]::Round((New-TimeSpan -Start ([datetime]$cached.timestamp) -End (Get-Date)).TotalHours, 1)
            ArticleCount   = [int]$cached.article_count
        }
    }

    # Scrape all feeds
    $all = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($src in $NewsSources) {
        $items = Get-RSSItems $src.Url $src.Name 6
        foreach ($i in $items) { $all.Add($i) }
    }

    $noKey = ($apiKey -eq "YOUR_ANTHROPIC_KEY_HERE" -or [string]::IsNullOrWhiteSpace($apiKey))

    if ($noKey -or $all.Count -eq 0) {
        $reason = if ($noKey) { "Set anthropic_api_key in btc_config.json to enable news analysis." } else { "No articles scraped." }
        return [pscustomobject]@{
            Score=0; Sentiment="neutral"; Recommendation="proceed"
            KeyItems=@($reason); Reasoning=$reason; Risks="N/A"
            FromCache=$false; CacheAge=0; ArticleCount=$all.Count
        }
    }

    $analysis = Invoke-ClaudeSentiment $apiKey $all.ToArray()

    if ($null -eq $analysis) {
        # Return neutral rather than blocking the bot on API failure
        return [pscustomobject]@{
            Score=0; Sentiment="neutral"; Recommendation="proceed"
            KeyItems=@("News analysis unavailable -- Claude API error"); Reasoning="API error, defaulting to neutral."; Risks="Unknown."
            FromCache=$false; CacheAge=0; ArticleCount=$all.Count
        }
    }

    # Save to cache
    [ordered]@{
        timestamp      = (Get-Date).ToUniversalTime().ToString("o")
        score          = $analysis.score
        sentiment      = $analysis.sentiment
        recommendation = $analysis.recommendation
        key_items      = $analysis.key_items
        reasoning      = $analysis.reasoning
        risks          = $analysis.risks
        article_count  = $all.Count
    } | ConvertTo-Json -Depth 5 | Set-Content $CachePath

    return [pscustomobject]@{
        Score          = [int]$analysis.score
        Sentiment      = "$($analysis.sentiment)"
        Recommendation = "$($analysis.recommendation)"
        KeyItems       = @($analysis.key_items)
        Reasoning      = "$($analysis.reasoning)"
        Risks          = "$($analysis.risks)"
        FromCache      = $false
        CacheAge       = 0
        ArticleCount   = $all.Count
    }
}

# -- Standalone mode (run directly, not dot-sourced) --
if ($MyInvocation.InvocationName -ne ".") {
    $cfg = Get-Content (Join-Path $PSScriptRoot "btc_config.json") | ConvertFrom-Json
    if ($cfg.anthropic_api_key -eq "FROM_ENV") { $cfg.anthropic_api_key = "$($env:ANTHROPIC_API_KEY)".Trim() }
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")

    Write-Host ""
    Write-Host ("="*68)
    Write-Host ("  BTC NEWS SENTIMENT  --  {0} UTC" -f $now)
    Write-Host ("="*68)
    Write-Host "  Scraping feeds and calling Claude..."

    $news = Get-Newssentiment $cfg.anthropic_api_key ([int]$cfg.news_cache_hours)

    $cacheNote = if ($news.FromCache) { "(cached, {0}h old)" -f $news.CacheAge } else { "(fresh)" }
    Write-Host ("  Articles analyzed: {0}  {1}" -f $news.ArticleCount, $cacheNote)
    Write-Host ""

    $bar = if ($news.Score -gt 0) { "+" * $news.Score } elseif ($news.Score -lt 0) { "-" * [Math]::Abs($news.Score) } else { "=" }
    Write-Host ("  Score:          {0,3}/10  [{1,-10}]  {2}" -f $news.Score, $bar, $news.Sentiment.ToUpper())
    Write-Host ("  Recommendation: {0}" -f $news.Recommendation.ToUpper())
    Write-Host ""
    Write-Host "  Key headlines:"
    foreach ($h in $news.KeyItems) { Write-Host ("    - {0}" -f $h) }
    Write-Host ""
    Write-Host ("  Analysis:  {0}" -f $news.Reasoning)
    Write-Host ("  Key risk:  {0}" -f $news.Risks)
    Write-Host ""
    Write-Host ("="*68)

    if     ($news.Score -le [int]$cfg.news_exit_threshold)  { Write-Host ("  ACTION: EMERGENCY EXIT -- strongly bearish news ({0})" -f $news.Score) }
    elseif ($news.Score -le [int]$cfg.news_block_threshold) { Write-Host ("  ACTION: BLOCK ENTRY -- bearish news ({0})" -f $news.Score) }
    elseif ($news.Score -ge [int]$cfg.news_boost_threshold) { Write-Host ("  ACTION: TAILWIND -- news supports entry ({0})" -f $news.Score) }
    else                                                     { Write-Host ("  ACTION: NEUTRAL -- technical signals decide ({0})" -f $news.Score) }
    Write-Host ""
}
