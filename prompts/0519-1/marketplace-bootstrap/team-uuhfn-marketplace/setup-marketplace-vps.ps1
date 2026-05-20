# ============================================================================
# setup-marketplace-vps.ps1  —  VPS 一次性部署：team-uuhfn marketplace
# ----------------------------------------------------------------------------
# 在 Windows VPS（uuhfn.cloud）上以管理员身份执行。
#
# 前置：
#   1. Caddy + files.uuhfn.cloud 已起（按 VPS-团队工具分发-教程.md）
#   2. Git for Windows 已装（git --version 能输出）
#   3. claude-for-legal-ZH 镜像已部署（按 claude-for-legal-mirror/DEPLOY.md）
#      → C:\caddy\git\claude-for-legal-ZH.git 存在且 update-server-info OK
#
# 这个脚本做的事：
#   1. 创建 C:\caddy\git\bifrost-internal-plugins.git（bare repo）
#   2. 从本地 working dir push 整个 team-uuhfn-marketplace/ 内容进去
#      （含 .claude-plugin/marketplace.json）
#   3. update-server-info 启用 dumb HTTP clone
#   4. 输出客户端 add 命令 + 验证步骤
#
# 用法：
#   把整个 team-uuhfn-marketplace/ 目录上传到 VPS 任一位置，比如
#     C:\caddy\scripts\team-uuhfn-marketplace\
#   然后：
#     cd C:\caddy\scripts\team-uuhfn-marketplace
#     PowerShell -ExecutionPolicy Bypass -File .\setup-marketplace-vps.ps1
#
# 幂等：可重跑。bare repo 已存在则仅 force-update refs。
# ============================================================================

# Note: 'Continue' (not 'Stop') because git writes informational progress to
# stderr (e.g. "To <repo>"), and with Stop + 2>&1 PowerShell mis-interprets that
# as a RemoteException. We rely on explicit $LASTEXITCODE checks for git calls
# and Fail() for PowerShell cmdlet failures.
$ErrorActionPreference = 'Continue'

# ---- Config -----------------------------------------------------------------
$BareRoot      = 'C:\caddy\git'
$MarketName    = 'bifrost-internal-plugins'   # bare repo 名（团队 add 的 URL 路径）
$BarePath      = Join-Path $BareRoot "$MarketName.git"
$SourceDir     = $PSScriptRoot                # 本脚本所在目录 = 完整 marketplace 源
$LogRoot       = 'C:\caddy\logs'
# -----------------------------------------------------------------------------

function Write-Step([string]$msg) {
    Write-Host "[setup-marketplace] $msg" -ForegroundColor Cyan
}

function Fail([string]$msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
    exit 1
}

# 1. 前置检查
Write-Step '1/8 verifying prerequisites'
$gitVer = & git --version 2>$null
if (-not $gitVer) { Fail 'git not found. Install Git for Windows first.' }
Write-Host "   $gitVer"

if (-not (Test-Path 'C:\caddy\git\claude-for-legal-ZH.git')) {
    Fail @"
claude-for-legal-ZH.git not found under C:\caddy\git\.
Deploy the upstream mirror first (prompts/0519-1/claude-for-legal-mirror/DEPLOY.md),
otherwise git-subdir sources will 404.
"@
}
Write-Host '   upstream mirror present: C:\caddy\git\claude-for-legal-ZH.git'

if (-not (Test-Path (Join-Path $SourceDir '.claude-plugin\marketplace.json'))) {
    Fail "marketplace.json missing under $SourceDir\.claude-plugin\. Are you running from the team-uuhfn-marketplace dir?"
}

# 2. 校验 marketplace.json 语法
Write-Step '2/8 validating marketplace.json'
$json = Get-Content (Join-Path $SourceDir '.claude-plugin\marketplace.json') -Raw
try {
    $parsed = $json | ConvertFrom-Json
    if (-not $parsed.plugins) { Fail 'marketplace.json missing plugins[]' }
    Write-Host ("   {0} plugins declared" -f $parsed.plugins.Count)
} catch {
    Fail "marketplace.json JSON syntax error: $($_.Exception.Message)"
}

# 3. 建 bare repo
Write-Step '3/8 init bare repo'
foreach ($p in @($BareRoot, $LogRoot)) {
    if (-not (Test-Path $p)) {
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
}

$bareCreated = $false
if (-not (Test-Path $BarePath)) {
    git init --bare $BarePath
    if ($LASTEXITCODE -ne 0) { Fail 'git init --bare failed' }
    $bareCreated = $true
    Write-Host "   created bare repo at $BarePath"
} else {
    Write-Host "   bare repo exists, will force-update refs"
}

# 4. 准备一个临时工作 clone，导入 SourceDir 内容
Write-Step '4/8 building temp working tree'
$tmpRoot = Join-Path $env:TEMP "marketplace-build-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

try {
    # 拷贝源到 tmp（排除潜在的 .git 噪声）
    Push-Location $SourceDir
    try {
        $items = Get-ChildItem -Force | Where-Object { $_.Name -notin '.git', 'node_modules', '.render-work' }
        foreach ($it in $items) {
            Copy-Item -Recurse -Force $it.FullName -Destination $tmpRoot
        }
    } finally {
        Pop-Location
    }

    # 5. tmp 内初始化 git + commit + push
    Write-Step '5/8 committing marketplace snapshot'
    Push-Location $tmpRoot
    try {
        git init -b main 2>&1 | Out-Null
        git config user.email 'marketplace-bot@uuhfn.cloud'
        git config user.name  'marketplace-bot'
        git add -A
        $commitMsg = "marketplace snapshot at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        git commit -m $commitMsg 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail 'git commit failed' }
        Write-Host "   committed"

        # 6. 推到 bare repo
        Write-Step '6/8 pushing to bare repo'
        git push --force $BarePath main 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail 'git push to bare repo failed' }
        Write-Host "   pushed main -> $BarePath"
    } finally {
        Pop-Location
    }
} finally {
    # 清理 tmp
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}

# 7. update-server-info + 配置只读 + 修 HEAD 指向 main
Write-Step '7/8 enabling dumb HTTP'
Push-Location $BarePath
try {
    # `git init --bare` defaults HEAD -> refs/heads/master, but we push `main`.
    # Without this, clients clone OK but get "remote HEAD refers to nonexistent ref"
    # and end up with no working tree checked out.
    git symbolic-ref HEAD refs/heads/main
    git --bare update-server-info
    git config http.receivepack false
    git config http.uploadpack true
} finally {
    Pop-Location
}
Write-Host '   dumb HTTP enabled (push disabled), HEAD -> refs/heads/main'

# 8. 验证
Write-Step '8/8 verifying via local Caddy loopback'
$probeUrl = "https://files.uuhfn.cloud/git/$MarketName.git/info/refs?service=git-upload-pack"
try {
    $resp = Invoke-WebRequest -Uri $probeUrl -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 8
    if ($resp.StatusCode -eq 200) {
        Write-Host "   GET $probeUrl -> 200 OK" -ForegroundColor Green
    } else {
        Write-Host "[WARN] probe returned $($resp.StatusCode). Caddy may need a reload or DNS may not have propagated." -ForegroundColor Yellow
    }
} catch {
    Write-Host "[WARN] probe failed: $($_.Exception.Message). Skip and verify manually." -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== SETUP COMPLETE ===' -ForegroundColor Green
Write-Host "Marketplace bare repo : $BarePath"
Write-Host "Public URL            : https://files.uuhfn.cloud/git/$MarketName.git"
Write-Host ''
Write-Host 'Team client one-shot commands:' -ForegroundColor Cyan
Write-Host "  /plugin marketplace add https://files.uuhfn.cloud/git/$MarketName.git"
Write-Host '  /plugin install commercial-legal@team-uuhfn'
Write-Host '  /plugin install corporate-legal@team-uuhfn'
Write-Host '  ...(12 plugins total, pick any)'
Write-Host ''
Write-Host 'Remote sanity check (run on a team member machine):'
Write-Host "  git ls-remote https://files.uuhfn.cloud/git/$MarketName.git"
Write-Host '  -> expect one line: <commit SHA>\trefs/heads/main'
Write-Host ''
Write-Host 'Future updates (e.g. after adding internal plugins):'
Write-Host '  re-run this script (idempotent force-push).'
