param(
    [string]$EventsJsPath = "$env:USERPROFILE\events.js",
    [string]$DoujinUrl = "https://www.doujin.com.tw/events/alist",
    [string]$TaeUrl = "https://taiwanadultexpo.com/",
    [string]$TreUrl = "https://adultexpo.com.tw/",
    [string]$LogPath = "$env:USERPROFILE\.local\share\opencode\logs\doujin-sync.log",
    [switch]$Simulate,
    [switch]$AdultOnly
)

# ── Setup ──
$LogDir = Split-Path $LogPath -Parent
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp $Message" | Out-File -FilePath $LogPath -Append -Encoding utf8
    Write-Host "$timestamp $Message"
}

function Get-Tokens {
    param([string]$s)
    $result = @()
    $cjkMatches = [regex]::Matches($s, "[\u4e00-\u9fff\u3400-\u4dbf]{2,}")
    foreach ($m in $cjkMatches) { $result += $m.Value.ToLower() }
    $alnumMatches = [regex]::Matches($s, "[A-Za-z0-9]{2,}")
    foreach ($m in $alnumMatches) { $result += $m.Value.ToLower() }
    return $result | Select-Object -Unique
}

function Get-MatchScore {
    param([string[]]$tokensA, [string[]]$tokensB)
    if ($tokensA.Count -eq 0 -or $tokensB.Count -eq 0) { return 0 }
    $intersection = @($tokensA | Where-Object { $_ -in $tokensB })
    $minCount = [Math]::Min($tokensA.Count, $tokensB.Count)
    if ($minCount -eq 0) { return 0 }
    return [double]$intersection.Count / $minCount
}

function Batch-Insert {
    param([string]$FilePath, [string[]]$Entries)
    $content = Get-Content -Path $FilePath -Raw -Encoding utf8
    if ($Entries.Count -eq 0) { return $true }
    $adultPos = $content.LastIndexOf("adult:")
    if ($adultPos -lt 0) { Write-Log "ERROR: Cannot find 'adult:' section in $FilePath"; return $false }
    $searchPos = $adultPos - 1
    $lastEventPos = $content.LastIndexOf("},", $searchPos, [System.StringComparison]::Ordinal)
    if ($lastEventPos -lt 0) { Write-Log "ERROR: Cannot find last event entry in $FilePath"; return $false }
    $before = $content.Substring(0, $lastEventPos + 1)
    $after = $content.Substring($lastEventPos + 1)
    $insertBlock = ""
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $insertBlock += ",`n" + $Entries[$i]
    }
    Copy-Item -Path $FilePath -Destination "$FilePath.doujin-backup" -Force
    [System.IO.File]::WriteAllText($FilePath, $before + $insertBlock + $after, [System.Text.Encoding]::UTF8)
    Write-Log "Updated $FilePath ($($Entries.Count) event(s))"
    return $true
}

function Update-AdultEvent {
    param([string]$EventId, [string]$Url, [string]$NamePattern, [string]$LogLabel)
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15
        $body = $resp.Content
        Write-Log "  Fetched $LogLabel ($($body.Length) chars)"
        $dateMatch = [regex]::Match($body, '(20\d\d)\s*[年/\-]\s*(\d{1,2})\s*[月/\-]\s*(\d{1,2})\s*[日]?')
        if (-not $dateMatch.Success) {
            $dateMatch = [regex]::Match($body, '(\d{1,2})\s*[月/\-]\s*(\d{1,2}),?\s*(20\d\d)')
        }
        if (-not $dateMatch.Success) {
            Write-Log "  No date found on $LogLabel page"
            return
        }
        Write-Log "  $LogLabel page date: $($dateMatch.Value)"
    } catch {
        Write-Log "  WARN: Could not fetch $($LogLabel): $_"
    }
}

function Search-NewAdultEvent {
    param([string]$Keyword, [string]$LogLabel)
    try {
        $encKeyword = [System.Uri]::EscapeDataString($Keyword)
        $feedUrl = "https://news.google.com/rss/search?q=$encKeyword&hl=zh-TW&gl=TW&ceid=TW:zh-Hant"
        $resp = Invoke-WebRequest -Uri $feedUrl -UseBasicParsing -TimeoutSec 15
        [xml]$xml = $resp.Content
        $rawItems = $xml.SelectNodes("/rss/channel/item")
        if (-not $rawItems -or $rawItems.Count -eq 0) {
            Write-Log "  $($LogLabel): no results"; return
        }
        Write-Log "  $($LogLabel): $($rawItems.Count) news items"

        $content = Get-Content -Path $EventsJsPath -Raw -Encoding utf8
        if (-not $content) { Write-Log "  WARN: cannot read events.js"; return }
        $adultMatch = [regex]::Match($content, "adult:\s*\[(.*?)\]")
        $existingAdultNames = @()
        if ($adultMatch.Success) {
            foreach ($nm in [regex]::Matches($adultMatch.Groups[1].Value, "name:'([^']+)'")) {
                $existingAdultNames += $nm.Groups[1].Value
            }
        }

        $newCandidates = @()
        foreach ($itemNode in $rawItems) {
            $title = if ($itemNode.title) { $itemNode.title -replace '\s+', ' ' } else { continue }
            $pubDate = if ($itemNode.pubDate) { $itemNode.pubDate } else { "" }
            $link = if ($itemNode.link) { $itemNode.link } else { "" }
            $isKnown = $false
            foreach ($en in $existingAdultNames) {
                if ($title -match [regex]::Escape($en)) { $isKnown = $true; break }
                $enBigrams = @([regex]::Matches($en, "[\u4e00-\u9fff]{2,}").Value)
                $titleBigrams = @([regex]::Matches($title, "[\u4e00-\u9fff]{2,}").Value)
                $overlap = 0
                foreach ($eb in $enBigrams) {
                    foreach ($tb in $titleBigrams) {
                        if ($eb -eq $tb) { $overlap++ }
                    }
                }
                if ($overlap -ge 3) { $isKnown = $true; break }
            }
            if (-not $isKnown) {
                $newCandidates += @{ title=$title; pubDate=$pubDate; link=$link }
            }
        }

        if ($newCandidates.Count -gt 0) {
            Write-Log "  >>> $($LogLabel): $($newCandidates.Count) potential new event(s)!"
            foreach ($c in $newCandidates) {
                $safeTitle = $c.title -replace "'", ""
                Write-Log "    [$($c.pubDate)] $safeTitle"
                Write-Log "      $($c.link)"
            }
        } else {
            Write-Log "  $($LogLabel): all matched existing"
        }
    } catch {
        Write-Log "  WARN: $($LogLabel) search failed: $_"
    }
}

# ── Entry point ──
Write-Log "=== Starting doujin calendar sync === (AdultOnly=$AdultOnly)"

if (-not (Test-Path $EventsJsPath)) {
    Write-Log "ERROR: File not found - $EventsJsPath"
    exit 1
}

# ══════════════════════════════════════════════
# ACG sync (skip if -AdultOnly)
# ══════════════════════════════════════════════
if (-not $AdultOnly) {

try {
    $response = Invoke-WebRequest -Uri $DoujinUrl -UseBasicParsing -TimeoutSec 30
    $html = $response.Content
} catch {
    Write-Log "ERROR fetching doujin calendar: $_"; exit 1
}

$events = @()
$articlePattern = '<article class="event_smi_info"[^>]*>(.*?)</article>'
$articleMatches = [regex]::Matches($html, $articlePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

foreach ($match in $articleMatches) {
    $ah = $match.Value
    $di = if (($m = [regex]::Match($ah, "/events/info/(\d+)")).Success) { $m.Groups[1].Value } else { "" }
    $et = if (($m = [regex]::Match($ah, '<span class="etype1">([^<]+)</span>')).Success) { $m.Groups[1].Value.Trim() } else { "" }
    $nm = if (($m = [regex]::Match($ah, 'itemprop="name">([^<]+)</a>')).Success) { $m.Groups[1].Value.Trim() } else { "" }
    $sd = if (($m = [regex]::Match($ah, 'datetime="([^"]+)"')).Success) { $m.Groups[1].Value } else { "" }
    $ed = if (($m = [regex]::Match($ah, 'itemprop="endDate" content="([^"]+)"')).Success) { $m.Groups[1].Value } else { $sd }
    $ve = if (($m = [regex]::Match($ah, 'itemprop="location"[^>]*>.*?<span itemprop="name">([^<]+)</span>')).Success) { $m.Groups[1].Value.Trim() } else { "" }
    $fe = if (($m = [regex]::Match($ah, "入場費用[：:]\s*([^<]+)")).Success) { $m.Groups[1].Value.Trim() } else { "" }
    $de = if (($m = [regex]::Match($ah, 'itemprop="description">([^<]+)</span>')).Success) { $m.Groups[1].Value.Trim() } else { "" }
    $og = if (($m = [regex]::Match($ah, '<span itemprop="organizer"[^>]*>.*?<span itemprop="name">([^<]+)</span>')).Success) { $m.Groups[1].Value.Trim() } else { "" }
    if ($nm -ne "") {
        $events += @{ doujinId=$di; etype=$et; name=$nm; startDate=$sd; endDate=$ed; venue=$ve; fee=$fe; desc=$de; organizer=$og }
    }
}

Write-Log "Parsed $($events.Count) events from doujin calendar"

$existingContent = Get-Content -Path $EventsJsPath -Raw -Encoding utf8
$existingNames = @{}
foreach ($nm in [regex]::Matches($existingContent, "name:'([^']+)'")) {
    $existingNames[$nm.Groups[1].Value] = $true
}

$existingTokenSets = @{}
foreach ($en in $existingNames.Keys) {
    $existingTokenSets[$en] = Get-Tokens $en
}

$newEvents = @()
foreach ($ev in $events) {
    $doujinTokens = Get-Tokens $ev.name
    $found = $false
    foreach ($exKey in $existingTokenSets.Keys) {
        $exTokens = $existingTokenSets[$exKey]
        $score = Get-MatchScore -tokensA $doujinTokens -tokensB $exTokens
        $scoreRev = Get-MatchScore -tokensA $exTokens -tokensB $doujinTokens
        if ($score -ge 0.4 -or $scoreRev -ge 0.4) { $found = $true; break }
    }
    if (-not $found) { $newEvents += $ev }
}

Write-Log "$($newEvents.Count)/$($events.Count) new ACG events"

if ($Simulate) {
    Write-Log "SIMULATE: ACG insert skipped"
    $ok = $true
} else {
    # Build entries and insert
    $nextId = 1
    $max = 0
    foreach ($im in [regex]::Matches($existingContent, "id:'(\d+)'")) {
        $val = [int]$im.Groups[1].Value
        if ($val -gt $max) { $max = $val }
    }
    $nextId = $max + 1

    $newEntries = @()
    $idCounter = $nextId
    $tag1 = "同人創作"
    $tag2 = "綜合同人誌即賣會"

    foreach ($ev in $newEvents) {
        $entryType = "同人誌即賣會"
        $tags = @($tag1, $tag2)
        $nl = $ev.name.ToLower()
        $dl = $ev.desc.ToLower()
        $et = $ev.etype.ToLower()

        if ($et -eq "綜合") {
            $exhibitionKeywords = @("漫人祭", "動漫祭", "ccf", "動漫盛典", "國際動漫")
            $marketKeywords = @("市集", "巴哈", "黑雪狐", "大蘿蔔", "漫漫玩", "二手")
            $isExhibition = $false; $isMarket = $false
            foreach ($kw in $exhibitionKeywords) { if ($nl.Contains($kw)) { $isExhibition = $true; break } }
            if (-not $isExhibition) {
                foreach ($kw in $marketKeywords) { if ($nl.Contains($kw)) { $isMarket = $true; break } }
            }
            if ($isExhibition) {
                $entryType = "動漫展"
                $tags = @("大型展覽", "綜合動漫展")
            } elseif ($isMarket) {
                $entryType = "市集"
                if ($nl.Contains("黑雪狐") -or $nl.Contains("巴哈") -or $nl.Contains("二手")) {
                    $tags = @("市集/消費", "二手ACG市集")
                } else { $tags = @("市集/消費", "文創市集") }
            }
        } elseif ($et -eq "only") {
            if ($dl.Contains("獨立遊戲")) { $entryType = "其他"; $tags = @("遊戲/互動", "獨立遊戲展") }
            elseif ($dl.Contains("隨舞") -or $dl.Contains("舞台表演")) { $entryType = "其他"; $tags = @("音樂/表演") }
            elseif ($dl.Contains("音樂遊戲")) { $entryType = "其他"; $tags = @("遊戲/互動") }
            else { $tags = @($tag1) }
        } else { $tags = @($tag1) }

        $feeFormatted = "未定"
        if ($ev.fee -ne "") {
            $fc = $ev.fee -replace "[\s]", ""
            if ($fc -match "^\d+") { $feeFormatted = "NT`$$($Matches[0])" }
            elseif ($fc -match "免費" -or $fc -match "free") { $feeFormatted = "免費" }
        }

        $date = $ev.startDate
        $notes = ""
        if ($ev.startDate -match '(\d{4})-(\d{2})-(\d{2})') {
            $y=[int]$Matches[1]; $m=[int]$Matches[2]; $d=[int]$Matches[3]
            $dow = (Get-Date "$y-$m-$d").DayOfWeek.ToString().Substring(0,3)
            if ($ev.startDate -ne $ev.endDate -and $ev.endDate -match '(\d{4})-(\d{2})-(\d{2})') {
                $em=[int]$Matches[2]; $ed=[int]$Matches[3]
                $dow2 = (Get-Date $ev.endDate).DayOfWeek.ToString().Substring(0,3)
                $notes += "• 活動兩天 $m/$d($dow)~$em/$ed($dow2)"
            } else { $notes += "• 單日活動 $m/$d($dow)" }
        }

        if ($feeFormatted -eq "未定") {
            $notes += "`n• 入場費用未定"
        } else { $notes += "`n• 入場費用 $feeFormatted" }
        if ($ev.venue -ne "") { $notes += "`n• $($ev.venue)" }
        if ($ev.organizer -ne "") { $notes += "`n• 主辦：$($ev.organizer)" }

        $tagsStr = "['" + ($tags -join "','") + "']"
        $nameEsc = $ev.name -replace "'", "\'"
        $descEsc = "$($ev.name) at $($ev.venue)." -replace "'", "\'"
        $notesEsc = $notes -replace "'", "\'"
        $venueEsc = $ev.venue -replace "'", "\'"

        $newEntries += "      { id:'$idCounter', name:'$nameEsc', type:'$entryType', fee:'$feeFormatted', date:'$date', time:'10:00', location:'$venueEsc', desc:'$descEsc', notes:'$notesEsc', image:'', link:'', tags:$tagsStr }"
        $idCounter++
    }

    if ($newEntries.Count -gt 0) {
        $ok = Batch-Insert -FilePath $EventsJsPath -Entries $newEntries
        Write-Log "ACG: $($newEntries.Count) event(s) added"
    } else {
        $ok = $true
        Write-Log "ACG: 0 new events"
    }
}

} # end -not $AdultOnly

# ══════════════════════════════════════════════
# Adult source check (always runs)
# ══════════════════════════════════════════════
Write-Log "--- Checking adult event sources ---"
Update-AdultEvent -EventId "a11" -Url $TaeUrl -NamePattern "TAE" -LogLabel "TAE"
Update-AdultEvent -EventId "a12" -Url $TreUrl -NamePattern "TRE" -LogLabel "TRE"

Write-Log "--- Searching news for new adult events ---"
Search-NewAdultEvent -Keyword "台灣 成人 展 2026" -LogLabel "成人展"
Search-NewAdultEvent -Keyword "台灣 R18 同人 販售會 2026" -LogLabel "R18同人"
Search-NewAdultEvent -Keyword "台灣 成人創作 市集 2026" -LogLabel "成人創作"
Search-NewAdultEvent -Keyword "台灣 寫真集 展銷 2026" -LogLabel "寫真集"

Write-Log "=== Sync complete ==="
if ($newEntries -and $newEntries.Count -gt 0) { Write-Log "Added $($newEntries.Count) ACG event(s) to events.js" }
if (-not $ok) { Write-Log "ERROR: Failed to update events.js" }
if (-not $AdultOnly) { Write-Log "Backup saved as $EventsJsPath.doujin-backup" }
