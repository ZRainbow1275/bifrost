# ============================================================================
# sync-claude-for-legal.ps1  —  Daily upstream sync
# ----------------------------------------------------------------------------
# Triggered by the scheduled task at 02:00 every day.
#
# What it does:
#   1. git remote update inside the bare mirror.
#   2. Detect whether HEAD changed; if not, exit early (still log).
#   3. update-server-info so dumb HTTP clones see latest refs.
#   4. Hard-reset the working tree to origin/main.
#   5. Pack a versioned tarball releases/claude-for-legal-ZH-YYYYMMDD.tar.gz
#      and refresh latest.tar.gz.
#   6. Retain only the last 14 daily tarballs (configurable).
#   7. Append a structured log line to logs/YYYY-MM.log.
# ============================================================================

$ErrorActionPreference = 'Stop'

# ---- Config -----------------------------------------------------------------
$BarePath    = 'C:\caddy\git\claude-for-legal-ZH.git'
$DistRoot    = 'C:\caddy\dist\claude-for-legal-ZH'
$TreePath    = Join-Path $DistRoot 'tree'
$ReleasePath = Join-Path $DistRoot 'releases'
$LogRoot     = 'C:\caddy\logs\sync-claude-for-legal'
$RetainDays  = 14
$Branch      = 'main'
# -----------------------------------------------------------------------------

$startedAt = Get-Date
$stamp     = $startedAt.ToString('yyyyMMdd')
$logFile   = Join-Path $LogRoot ($startedAt.ToString('yyyy-MM') + '.log')

if (-not (Test-Path $LogRoot)) {
    New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
}

function Write-Log([string]$level, [string]$msg) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

try {
    # Sanity check
    if (-not (Test-Path $BarePath)) {
        throw "bare repo missing at $BarePath. Run setup-mirror.ps1 first."
    }

    Write-Log 'INFO' 'sync started'

    # 1. Fetch upstream
    Push-Location $BarePath
    try {
        $headBefore = git rev-parse "$Branch" 2>$null
        git remote update --prune 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git remote update failed" }
        $headAfter  = git rev-parse "$Branch" 2>$null

        # 3. update-server-info (even on no-op, refs may have been added)
        git --bare update-server-info
    } finally {
        Pop-Location
    }

    if ($headBefore -eq $headAfter) {
        Write-Log 'INFO' "no upstream change (HEAD=$headBefore). exit clean."
        exit 0
    }

    Write-Log 'INFO' "HEAD changed: $headBefore -> $headAfter"

    # 4. Update working tree
    Push-Location $TreePath
    try {
        git fetch origin 2>&1 | Out-Null
        git reset --hard "origin/$Branch" 2>&1 | Out-Null
        git clean -fdx 2>&1 | Out-Null
    } finally {
        Pop-Location
    }

    # 5. Pack tarball
    $tarName   = "claude-for-legal-ZH-$stamp.tar.gz"
    $tarFull   = Join-Path $ReleasePath $tarName
    $latestTar = Join-Path $ReleasePath 'latest.tar.gz'

    Push-Location $TreePath
    try {
        git archive --format=tar.gz --prefix="claude-for-legal-ZH/" -o $tarFull HEAD
        if ($LASTEXITCODE -ne 0) { throw "git archive failed" }
    } finally {
        Pop-Location
    }

    Copy-Item -Force $tarFull $latestTar

    # 6. Retention
    $cutoff = (Get-Date).AddDays(-$RetainDays)
    Get-ChildItem $ReleasePath -Filter 'claude-for-legal-ZH-*.tar.gz' |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            Remove-Item $_.FullName -Force
            Write-Log 'INFO' "retention: removed $($_.Name)"
        }

    $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
    Write-Log 'INFO' "sync done in ${elapsed}s. tarball=$tarName"
}
catch {
    Write-Log 'ERROR' $_.Exception.Message
    exit 1
}
