# DVS PTPv2 Unlock -- Windows control panel
#
# Double-click "DVS PTPv2 Unlock.cmd" (which launches this script). It offers one
# switch -- turn PTPv2 support on or off -- plus a status view. It elevates via
# UAC once, applies the change, and restarts the Dante Virtual Soundcard so it
# takes effect.
#
# Parameters exist for testing: -DvsDir points at a different install folder and
# -LoadOnly dot-sources the functions without elevating or showing the menu.

[CmdletBinding()]
param(
    [string]$DvsDir,
    [switch]$LoadOnly
)

$ErrorActionPreference = 'Stop'

# DVS can sit in either Program Files location depending on the installer.
$DvsDirCandidates = @(
    'C:\Program Files\Audinate\Dante Virtual Soundcard',
    'C:\Program Files (x86)\Audinate\Dante Virtual Soundcard'
)

function Find-DvsDir {
    foreach ($d in $DvsDirCandidates) { if (Test-Path $d) { return $d } }
    return $DvsDirCandidates[0]
}

function Use-DvsDir([string]$dir) {
    $script:DvsDir = $dir
    $script:Ptp    = Join-Path $dir 'ptp.exe'
    $script:Orig   = Join-Path $dir 'ptp-original.exe'
    $script:Conf   = Join-Path $dir 'dvs-ptpv2-unlock.conf'
}

# --- config -----------------------------------------------------------------

function Test-Installed { Test-Path $Orig }

# PTPv2 counts as enabled only when BOTH hold: the wrapper is in place AND the
# config asks for it. These used to be two separate menu entries, which let
# people install the wrapper and still get nothing, because the shipped config
# defaults to off. The single switch below always sets both together.
function Test-Enabled { (Test-Installed) -and (Get-ConfValue 'ptpv2') }

function Get-ConfValue([string]$key) {
    if (-not (Test-Path $Conf)) { return $false }
    $line = Select-String -Path $Conf -Pattern "^\s*$key\s*=" -ErrorAction SilentlyContinue | Select-Object -Last 1
    if (-not $line) { return $false }
    $val = ($line.Line -split '=', 2)[1].Trim().ToLower()
    return @('1', 'y', 'yes', 'true', 'on') -contains $val
}

function Set-Conf([bool]$ptpv2) {
    $p = if ($ptpv2)  { 1 } else { 0 }
    @(
        '# DVS PTPv2 Unlock configuration (written by dvs-ptpv2-unlock.ps1)'
        "ptpv2  = $p"
    ) | Set-Content -Path $Conf -Encoding ASCII
}

# Prefer the prebuilt exe shipped next to this script; compile only as fallback.
function Get-Binary {
    $local = Join-Path $PSScriptRoot 'dvs-ptpv2-unlock.exe'
    if (Test-Path $local) { return $local }
    $src = Join-Path $PSScriptRoot 'dvs-ptpv2-unlock.c'
    if (-not (Test-Path $src)) { throw "No dvs-ptpv2-unlock.exe and no source to build it. Please download a release." }
    $cc = (Get-Command gcc, cc, clang -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $cc) { throw "No prebuilt dvs-ptpv2-unlock.exe and no C compiler found. Download a release, or install MinGW." }
    & $cc.Source '-DWIN32' '-O2' '-o' $local $src
    return $local
}

# --- stopping / starting DVS ------------------------------------------------

function Get-DvsService {
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Dante Virtual Soundcard*' -or $_.Name -like '*Dante*' } |
        Select-Object -First 1
}

# Stop the real service (child) first, then the wrapper. The Windows wrapper
# runs the real ptp as a CHILD process (spawnv) instead of replacing itself, so
# killing only "ptp" would leave "ptp-original" behind and DVS would end up with
# two PTP instances after the restart.
function Stop-PtpProcesses {
    foreach ($n in 'ptp-original', 'ptp') {
        Get-Process -Name $n -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# Windows locks a running .exe: ptp.exe CANNOT be overwritten while it runs.
# Everything that swaps binaries must stop DVS first and start it again after.
function Suspend-Dvs {
    $svc = Get-DvsService
    if ($svc -and $svc.Status -eq 'Running') {
        Stop-Service -InputObject $svc -Force -ErrorAction SilentlyContinue
    }
    Stop-PtpProcesses
    return $svc
}

function Resume-Dvs($svc) {
    if ($svc) { Start-Service -InputObject $svc -ErrorAction SilentlyContinue }
}

# Replace a file that a just-terminated process may still hold briefly.
function Copy-FileWithRetry($src, $dst) {
    for ($i = 0; $i -lt 10; $i++) {
        try { Copy-Item $src $dst -Force; return }
        catch { Start-Sleep -Milliseconds 300 }
    }
    throw "Could not replace '$dst' -- it is still in use. Please quit the Dante Virtual Soundcard completely and try again."
}

# --- actions ----------------------------------------------------------------

function Invoke-Enable {
    if (-not (Test-Path $DvsDir)) { throw "Dante Virtual Soundcard not found at '$DvsDir'." }
    if (-not (Test-Path $Ptp) -and -not (Test-Installed)) { throw "No ptp.exe found in '$DvsDir'." }
    $bin = Get-Binary
    $svc = Suspend-Dvs
    try {
        # Back up the real ptp only if no backup exists, so enabling twice can
        # never overwrite the original with the wrapper.
        if (-not (Test-Installed)) { Copy-Item $Ptp $Orig }
        Copy-FileWithRetry $bin $Ptp
        Set-Conf -ptpv2 $true
    } finally {
        Resume-Dvs $svc
    }
    Write-Host "`nPTPv2 is now enabled. DVS was restarted." -ForegroundColor Green
}

function Invoke-Disable {
    if (-not (Test-Installed)) {
        Write-Host "`nPTPv2 is already disabled -- DVS's original ptp is in place." -ForegroundColor Yellow
        return
    }
    $svc = Suspend-Dvs
    try {
        # Copy back first and only drop the backup once that succeeded, so a
        # failure here can never leave the system without a working ptp.exe.
        Copy-FileWithRetry $Orig $Ptp
        Remove-Item $Orig -Force -ErrorAction SilentlyContinue
        # Keep the config in step, so nothing is left claiming PTPv2 is wanted.
        if (Test-Path $Conf) { Set-Conf -ptpv2 $false }
    } finally {
        Resume-Dvs $svc
    }
    Write-Host "`nPTPv2 is now disabled. DVS's original ptp was restored and DVS restarted." -ForegroundColor Green
}

# Report the EFFECTIVE state from the running process, independent of the config.
function Get-LiveStatus {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'ptp.exe' -or $_.Name -eq 'ptp-original.exe' })
    if ($procs.Count -eq 0) { return 'PTP service not running' }
    # The wrapper stays alive as ptp.exe holding DVS's ORIGINAL arguments and
    # runs the real service as ptp-original.exe with the modified ones, so the
    # child is the authoritative source. Reading the parent would report the
    # unmodified flags and wrongly claim PTPv2 is off.
    $proc = $procs | Where-Object { $_.Name -eq 'ptp-original.exe' } | Select-Object -First 1
    if (-not $proc) { $proc = $procs[0] }
    $cmd = " $($proc.CommandLine) "
    $p = if ($cmd -match '\s-y2')  { 'enabled' } else { 'disabled' }   # wrapper appends -y2=-2 for PTPv2
    return "PTPv2 $p"
}

function YesNo([bool]$b) { if ($b) { 'enabled' } else { 'disabled' } }

function Show-Status {
    Write-Host ""
    Write-Host "PTPv2: $(YesNo (Test-Enabled))" -ForegroundColor Cyan
    Write-Host "Details:"
    Write-Host "    Wrapper installed: $(if (Test-Installed) {'yes'} else {'no'})"
    Write-Host "    Config setting   : $(YesNo (Get-ConfValue 'ptpv2'))"
    Write-Host "    Running service  : $(Get-LiveStatus)"
    Write-Host "    Config file      : $Conf"
}

# --- startup ----------------------------------------------------------------

if ($DvsDir) { Use-DvsDir $DvsDir } else { Use-DvsDir (Find-DvsDir) }

if ($LoadOnly) { return }   # tests dot-source the functions and stop here

# Elevate to Administrator (needed to write into Program Files).
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host "Requesting administrator rights..."
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    exit
}

$quit = $false
while (-not $quit) {
    $enabled = Test-Enabled
    Write-Host ""
    Write-Host "===== DVS PTPv2 Unlock =====" -ForegroundColor Cyan
    Write-Host "PTPv2 is currently $(YesNo $enabled)."
    Write-Host ""
    Write-Host "  1) $(if ($enabled) {'Disable PTPv2'} else {'Enable PTPv2'})"
    Write-Host "  2) Show status"
    Write-Host "  3) Quit"
    try {
        switch (Read-Host "Choose") {
            '1' { if ($enabled) { Invoke-Disable } else { Invoke-Enable } }
            '2' { Show-Status }
            '3' { $quit = $true }
            default { }
        }
    } catch {
        Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    }
}
