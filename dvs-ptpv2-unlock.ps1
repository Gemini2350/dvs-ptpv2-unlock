# DVS PTPv2 Unlock -- Windows control panel
#
# Double-click "DVS PTPv2 Unlock.cmd" (which launches this script). It opens a
# small menu to activate/deactivate the PTP wrapper and toggle its options
# (PTPv2, leader mode). It elevates via UAC once, applies the change, and
# restarts the Dante Virtual Soundcard so it takes effect.
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

function Get-ConfValue([string]$key) {
    if (-not (Test-Path $Conf)) { return $false }
    $line = Select-String -Path $Conf -Pattern "^\s*$key\s*=" -ErrorAction SilentlyContinue | Select-Object -Last 1
    if (-not $line) { return $false }
    $val = ($line.Line -split '=', 2)[1].Trim().ToLower()
    return @('1', 'y', 'yes', 'true', 'on') -contains $val
}

function Set-Conf([bool]$leader, [bool]$ptpv2) {
    $l = if ($leader) { 1 } else { 0 }
    $p = if ($ptpv2)  { 1 } else { 0 }
    @(
        '# DVS PTPv2 Unlock configuration (written by dvs-ptpv2-unlock.ps1)'
        "leader = $l"
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

function Invoke-Activate {
    if (-not (Test-Path $DvsDir)) { throw "Dante Virtual Soundcard not found at '$DvsDir'." }
    if (-not (Test-Path $Ptp) -and -not (Test-Installed)) { throw "No ptp.exe found in '$DvsDir'." }
    $bin = Get-Binary
    $svc = Suspend-Dvs
    try {
        # Back up the real ptp only if no backup exists, so a second activate can
        # never overwrite the original with the wrapper.
        if (-not (Test-Installed)) { Copy-Item $Ptp $Orig }
        Copy-FileWithRetry $bin $Ptp
        if (-not (Test-Path $Conf)) {
            Copy-Item (Join-Path $PSScriptRoot 'dvs-ptpv2-unlock.conf') $Conf
        }
    } finally {
        Resume-Dvs $svc
    }
    Write-Host "`nActivated and DVS restarted." -ForegroundColor Green
}

function Invoke-Deactivate {
    if (-not (Test-Installed)) { Write-Host "`nNot installed -- nothing to do." -ForegroundColor Yellow; return }
    $svc = Suspend-Dvs
    try {
        # Copy back first and only drop the backup once that succeeded, so a
        # failure here can never leave the system without a working ptp.exe.
        Copy-FileWithRetry $Orig $Ptp
        Remove-Item $Orig -Force -ErrorAction SilentlyContinue
    } finally {
        Resume-Dvs $svc
    }
    Write-Host "`nOriginal ptp restored and DVS restarted." -ForegroundColor Green
}

function Edit-Options {
    $curLeader = Get-ConfValue 'leader'
    $curPtpv2  = Get-ConfValue 'ptpv2'
    Write-Host ""
    $a = Read-Host "Enable PTPv2 support? (y/n) [$(if($curPtpv2){'y'}else{'n'})]"
    $b = Read-Host "Allow DVS to become leader? (y/n) [$(if($curLeader){'y'}else{'n'})]"
    $ptpv2  = if ($a -eq '') { $curPtpv2 }  else { $a -match '^(y|yes|1|on|true)$' }
    $leader = if ($b -eq '') { $curLeader } else { $b -match '^(y|yes|1|on|true)$' }
    Set-Conf -leader $leader -ptpv2 $ptpv2
    if (Test-Installed) {
        $svc = Suspend-Dvs
        Resume-Dvs $svc
        Write-Host "`nSaved (PTPv2 $(YesNo $ptpv2), leader mode $(YesNo $leader)) and DVS restarted." -ForegroundColor Green
    } else {
        Write-Host "`nSaved (PTPv2 $(YesNo $ptpv2), leader mode $(YesNo $leader)). They apply once you activate the wrapper." -ForegroundColor Green
    }
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
    $l = if ($cmd -match '\s-s\s') { 'disabled' } else { 'enabled' }   # DVS passes -s for slave-only
    return "PTPv2 $p, leader mode $l"
}

function YesNo([bool]$b) { if ($b) { 'enabled' } else { 'disabled' } }

function Show-Status {
    $state = if (Test-Installed) { 'installed' } else { 'not installed' }
    Write-Host ""
    Write-Host "Wrapper : $state"
    Write-Host "Configured (desired):   PTPv2: $(YesNo (Get-ConfValue 'ptpv2')), Leader mode: $(YesNo (Get-ConfValue 'leader'))"
    Write-Host "Live (what DVS runs now):  $(Get-LiveStatus)"
    Write-Host "config file: $Conf"
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
    $state = if (Test-Installed) { 'active' } else { 'not installed' }
    Write-Host ""
    Write-Host "===== DVS PTPv2 Unlock  (currently: $state) =====" -ForegroundColor Cyan
    Write-Host "  1) Activate wrapper"
    Write-Host "  2) Deactivate wrapper"
    Write-Host "  3) Edit options (PTPv2 / leader)"
    Write-Host "  4) Show status"
    Write-Host "  5) Quit"
    try {
        switch (Read-Host "Choose") {
            '1' { Invoke-Activate }
            '2' { Invoke-Deactivate }
            '3' { Edit-Options }
            '4' { Show-Status }
            '5' { $quit = $true }
            default { }
        }
    } catch {
        Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    }
}
