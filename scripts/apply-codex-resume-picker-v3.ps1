[CmdletBinding()]
param(
    [string]$CodexHome = "$env:USERPROFILE\.codex",
    [string]$GuardianRoot = "D:\Desktop\CREATOR SIX",
    [switch]$SkipWorkspaceTests,
    [switch]$RunConfirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$VersionMarker = "GuardianCodexResumePicker/2026-05-16-title-archive-v3"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$PickerSource = Join-Path $RepoRoot "scripts\codex-session-title-picker.js"
$GlobalPicker = Join-Path $CodexHome "tools\codex-resume-picker.js"
$GlobalBackupRoot = Join-Path $CodexHome "backups"
$GuardianPicker = Join-Path $GuardianRoot "apps\guardian\assets\tools\codex-resume-picker.js"
$GuardianRust = Join-Path $GuardianRoot "crates\guardian-repair\src\codex.rs"
$PackageScript = Join-Path $GuardianRoot "apps\guardian\scripts\package-release.ps1"

function Write-Step {
    param([string]$Message)
    Write-Host "[codex-picker-v3] $Message"
}

function Assert-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required file not found: $Path"
    }
}

function Backup-File {
    param(
        [string]$Path,
        [string]$BackupDirectory,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $name = [System.IO.Path]::GetFileName($Path)
    $backupPath = Join-Path $BackupDirectory "$name.$Label-$stamp.bak"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    Write-Step "Backup: $backupPath"
}

function Replace-Text {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Replacement
    )

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $updated = [regex]::Replace($text, $Pattern, $Replacement)
    if ($updated -ne $text) {
        [System.IO.File]::WriteAllText($Path, $updated, [System.Text.UTF8Encoding]::new($false))
        Write-Step "Updated marker in $Path"
    } else {
        Write-Step "Marker already current in $Path"
    }
}

Assert-File $PickerSource
Assert-File $GlobalPicker
Assert-File $GuardianPicker
Assert-File $GuardianRust
Assert-File $PackageScript

$pickerText = [System.IO.File]::ReadAllText($PickerSource, [System.Text.Encoding]::UTF8)
if (-not $pickerText.Contains($VersionMarker)) {
    throw "Picker source does not contain expected marker: $VersionMarker"
}

Backup-File -Path $GlobalPicker -BackupDirectory $GlobalBackupRoot -Label "pre-title-archive-v3"
Backup-File -Path $GuardianPicker -BackupDirectory (Split-Path -Parent $GuardianPicker) -Label "pre-title-archive-v3"
Backup-File -Path $GuardianRust -BackupDirectory (Join-Path $GuardianRoot "tmp") -Label "pre-title-archive-v3"

Copy-Item -LiteralPath $PickerSource -Destination $GlobalPicker -Force
Copy-Item -LiteralPath $PickerSource -Destination $GuardianPicker -Force
Write-Step "Installed v3 picker to global Codex tools and Guardian assets."

Replace-Text `
    -Path $GuardianRust `
    -Pattern 'const RESUME_PICKER_VERSION_MARKER: &str = "GuardianCodexResumePicker/[^"]+";' `
    -Replacement "const RESUME_PICKER_VERSION_MARKER: &str = `"$VersionMarker`";"

node --check $GlobalPicker
node --check $GuardianPicker

Write-Step "Verifying direct picker title output."
node $GlobalPicker --limit 3 --cwd "D:/Desktop/LawSaw"
node $GlobalPicker --limit 3 --cwd "D:/Desktop/Inkforge"
node $GlobalPicker --limit 3 --cwd "D:/Desktop/CREATOR FOUR"

Write-Step "Verifying Codex wrapper path."
Push-Location "D:\Desktop\LawSaw"
try {
    cmd /c "echo 999| codex resume"
} finally {
    Pop-Location
}

if (-not $SkipWorkspaceTests) {
    Push-Location $GuardianRoot
    try {
        cargo fmt --all --check
        cargo test -p guardian-repair
        cargo test --workspace
    } finally {
        Pop-Location
    }
}

Push-Location $GuardianRoot
try {
    & $PackageScript
    $distGuardian = Get-ChildItem -LiteralPath (Join-Path $GuardianRoot "dist") -Filter "guardian.exe" -Recurse -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $distGuardian) {
        throw "Packaged guardian.exe was not found under $GuardianRoot\dist"
    }

    Write-Step "Packaged guardian: $($distGuardian.FullName)"
    & $distGuardian.FullName --json repair codex --dry-run
    if ($RunConfirm) {
        & $distGuardian.FullName --json repair codex --confirm
        & $distGuardian.FullName --json repair codex --dry-run
    }
} finally {
    Pop-Location
}

Write-Step "Complete."
