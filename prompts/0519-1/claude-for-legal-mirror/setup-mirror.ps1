# ============================================================================
# setup-mirror.ps1  —  VPS one-time initialization
# ----------------------------------------------------------------------------
# Run this ONCE on the Windows VPS (as Administrator). Subsequent updates are
# handled by sync-claude-for-legal.ps1 via the daily scheduled task.
#
# What it does:
#   1. Verifies Git for Windows is installed.
#   2. Creates VPS dirs:
#        C:\caddy\git\claude-for-legal-ZH.git    (bare mirror)
#        C:\caddy\dist\claude-for-legal-ZH\      (static distribution root)
#        C:\caddy\dist\claude-for-legal-ZH\tree  (working tree at HEAD)
#        C:\caddy\dist\claude-for-legal-ZH\releases (versioned tarballs)
#        C:\caddy\logs\sync-claude-for-legal     (sync logs)
#   3. git clone --mirror upstream -> bare repo.
#   4. git update-server-info -> enable dumb HTTP clone.
#   5. Checkout HEAD into tree/ for direct /plugin marketplace add of folder.
#   6. Pack first tarball releases/v{YYYYMMDD}.tar.gz + latest.tar.gz copy.
# ============================================================================

$ErrorActionPreference = 'Stop'

# ---- Config -----------------------------------------------------------------
$Upstream     = 'https://github.com/CSlawyer1985/claude-for-legal-ZH.git'
$BareRoot     = 'C:\caddy\git'
$BarePath     = Join-Path $BareRoot 'claude-for-legal-ZH.git'
$DistRoot     = 'C:\caddy\dist\claude-for-legal-ZH'
$TreePath     = Join-Path $DistRoot 'tree'
$ReleasePath  = Join-Path $DistRoot 'releases'
$LogRoot      = 'C:\caddy\logs\sync-claude-for-legal'
# -----------------------------------------------------------------------------

function Write-Step([string]$msg) {
    Write-Host "[setup] $msg" -ForegroundColor Cyan
}

# 1. Git check
Write-Step '1/6 verifying git'
$gitVer = & git --version 2>$null
if (-not $gitVer) {
    Write-Host '[ERROR] git not found. Install Git for Windows: https://git-scm.com/download/win' -ForegroundColor Red
    exit 1
}
Write-Host "   $gitVer"

# 2. Create dirs
Write-Step '2/6 creating directories'
foreach ($p in @($BareRoot, $DistRoot, $ReleasePath, $LogRoot)) {
    if (-not (Test-Path $p)) {
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        Write-Host "   created $p"
    } else {
        Write-Host "   exists  $p"
    }
}

# 3. Clone bare mirror
Write-Step '3/6 cloning bare mirror'
if (Test-Path $BarePath) {
    Write-Host "   bare repo already exists, skipping clone"
} else {
    git clone --mirror $Upstream $BarePath
    if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
}

# 4. Enable dumb HTTP
Write-Step '4/6 enabling dumb HTTP (update-server-info)'
Push-Location $BarePath
try {
    git --bare update-server-info
    # Allow anonymous read over HTTP (required by some clients)
    git config http.receivepack false
    git config http.uploadpack true
} finally {
    Pop-Location
}

# 5. Checkout working tree
Write-Step '5/6 checking out working tree'
if (Test-Path $TreePath) {
    Write-Host "   tree already exists, refreshing"
    Push-Location $TreePath
    try {
        git fetch origin
        git reset --hard origin/main
    } finally {
        Pop-Location
    }
} else {
    git clone $BarePath $TreePath
    if ($LASTEXITCODE -ne 0) { throw "git clone tree failed" }
}

# 6. Pack first tarball
Write-Step '6/6 packing initial tarball'
$stamp     = Get-Date -Format 'yyyyMMdd'
$tarName   = "claude-for-legal-ZH-$stamp.tar.gz"
$tarFull   = Join-Path $ReleasePath $tarName
$latestTar = Join-Path $ReleasePath 'latest.tar.gz'

# Use git archive (cleanest — excludes .git)
Push-Location $TreePath
try {
    git archive --format=tar.gz --prefix="claude-for-legal-ZH/" -o $tarFull HEAD
    if ($LASTEXITCODE -ne 0) { throw "git archive failed" }
} finally {
    Pop-Location
}

Copy-Item -Force $tarFull $latestTar

Write-Host ''
Write-Host '=== SETUP COMPLETE ===' -ForegroundColor Green
Write-Host "Bare repo : $BarePath"
Write-Host "Tree      : $TreePath"
Write-Host "Tarball   : $tarFull"
Write-Host "Latest    : $latestTar"
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Merge Caddyfile-additions.txt into C:\caddy\Caddyfile, then'
Write-Host '       curl -X POST http://127.0.0.1:2019/load -H "Content-Type: text/caddyfile" --data-binary @C:\caddy\Caddyfile'
Write-Host '     (or use the Caddy admin reload command of your choice).'
Write-Host '  2. Run register-task.ps1 to install the daily sync schedule.'
Write-Host '  3. Test from any client:'
Write-Host '       git clone https://files.uuhfn.cloud/git/claude-for-legal-ZH.git'
Write-Host '       curl -I https://files.uuhfn.cloud/claude-for-legal-ZH/releases/latest.tar.gz'
