param(
    [string]$RepoPath = "$env:USERPROFILE\tw-acg-events-repo",
    [string]$SyncScript = "$env:USERPROFILE\check-doujin.ps1",
    [string]$GitHubToken = $env:GH_TOKEN,
    [string]$LogPath = "$env:USERPROFILE\.local\share\opencode\logs\tw-acg-sync.log"
)

$LogDir = Split-Path $LogPath -Parent
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts $Message" | Out-File -FilePath $LogPath -Append -Encoding utf8
    Write-Host "$ts $Message"
}

Write-Log "=== Auto Sync Start ==="

# Clone/pull repo
if (-not (Test-Path "$RepoPath\.git")) {
    New-Item -ItemType Directory -Path $RepoPath -Force | Out-Null
    git clone "https://x-access-token:$GitHubToken@github.com/Huayueyue029399/e42447a3566676f.git" $RepoPath 2>&1 | ForEach-Object { Write-Log "  $_" }
    if ($LASTEXITCODE -ne 0) { Write-Log "ERROR: git clone failed"; exit 1 }
} else {
    Set-Location $RepoPath
    git pull origin main 2>&1 | ForEach-Object { Write-Log "  $_" }
}

Set-Location $RepoPath

# Run sync script
Write-Log "Running check-doujin.ps1..."
& $SyncScript -EventsJsPath "$RepoPath\events.js" -LogPath $LogPath 2>&1 | ForEach-Object { Write-Log "  $_" }

# Commit & push if events.js changed
$status = git status --porcelain events.js
if ($status) {
    git config user.email "auto-sync@bot.local"
    git config user.name "Auto-Sync Bot"
    git add events.js
    git commit -m "auto: sync events data"
    git push 2>&1 | ForEach-Object { Write-Log "  $_" }
    Write-Log "Changes pushed to GitHub"
} else {
    Write-Log "No changes in events.js"
}

Write-Log "=== Auto Sync Complete ==="
