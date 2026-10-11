# Windows behaviour tests -- run by CI on a real Windows runner.
#
# Part A exercises the compiled wrapper end to end: a stand-in "ptp-original.exe"
# prints the arguments it receives, so we can assert exactly what the wrapper
# forwards for a given config. Part B dot-sources the control panel and tests its
# functions against a throwaway DVS folder and real processes.

$ErrorActionPreference = 'Stop'
$script:fails = 0

function Assert-That($cond, $msg) {
    if ($cond) { Write-Host "  PASS  $msg" -ForegroundColor Green }
    else       { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:fails++ }
}

$repo = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path $repo 'dvs-ptpv2-unlock.exe'
$work = Join-Path $env:TEMP 'dvs-tests'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null

# --- build the stand-in ptp -------------------------------------------------
# Prints its arguments, exits with 7 (to prove the exit code is propagated), and
# stays alive when passed --hold (so process-inspection can be tested).
$fakeSrc = Join-Path $work 'fake-ptp.c'
@'
#include <stdio.h>
#include <string.h>
#include <windows.h>
int main(int argc, char **argv) {
    int i, hold = 0;
    printf("ARGS:");
    for (i = 1; i < argc; i++) {
        printf(" %s", argv[i]);
        if (strcmp(argv[i], "--hold") == 0) hold = 1;
    }
    printf("\n");
    fflush(stdout);
    if (hold) Sleep(30000);
    return 7;
}
'@ | Set-Content -Path $fakeSrc -Encoding ASCII
& gcc -O2 -o (Join-Path $work 'fake-ptp.exe') $fakeSrc
if ($LASTEXITCODE -ne 0) { throw "could not build the stand-in ptp" }
$fake = Join-Path $work 'fake-ptp.exe'

# --- Part A: the compiled wrapper ------------------------------------------
Write-Host "`n== Part A: wrapper argument rewriting ==" -ForegroundColor Cyan

$dvs  = 'C:\Program Files\Audinate\Dante Virtual Soundcard'
$dvs86 = 'C:\Program Files (x86)\Audinate\Dante Virtual Soundcard'
New-Item -ItemType Directory -Force -Path $dvs | Out-Null
Copy-Item $fake (Join-Path $dvs 'ptp-original.exe') -Force
$conf = Join-Path $dvs 'dvs-ptpv2-unlock.conf'

function Invoke-Wrapper([string[]]$wrapperArgs) {
    $out = & $exe @wrapperArgs 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

Set-Content $conf @('ptpv2 = 1') -Encoding ASCII
$r = Invoke-Wrapper @('-s', '-m1=en0', '-lf=C:\x\log')
Assert-That ($r.Out -match '\s-s(\s|$)')     "-s (slave-only) is always passed through untouched"
Assert-That ($r.Out -match '-y2=-2')         "ptpv2=1 appends -y2=-2"
Assert-That ($r.Out -match '-m2=en0')        "ptpv2=1 mirrors -m1=en0 to -m2=en0"
Assert-That ($r.Out -match '-m1=en0')        "original arguments are preserved"
Assert-That ($r.Code -eq 7)                  "child exit code is propagated (got $($r.Code))"

Set-Content $conf @('ptpv2 = 0') -Encoding ASCII
$r = Invoke-Wrapper @('-s', '-m1=en0')
Assert-That ($r.Out -match '\s-s(\s|$)')     "ptpv2=0 still passes -s through"
Assert-That ($r.Out -notmatch '-y2')         "ptpv2=0 does not add -y2"
Assert-That ($r.Out -notmatch '-m2=')        "ptpv2=0 does not add -m2"

Set-Content $conf @('ptpv2 = ON') -Encoding ASCII
$r = Invoke-Wrapper @('-s', '-m1=en0')
Assert-That ($r.Out -match '-y2=-2')         "config accepts 'ON' (case-insensitive)"

Set-Content $conf @('ptpv2 = 1') -Encoding ASCII
$r = Invoke-Wrapper @('-lf=C:\x\log')
Assert-That ($r.Out -notmatch '-m2=')        "without -m1 no empty -m2 is passed"

# Config missing entirely -> compiled defaults (both off), must still run.
Remove-Item $conf -Force
$r = Invoke-Wrapper @('-s', '-m1=en0')
Assert-That ($r.Out -notmatch '-y2')         "missing config falls back to the default (off)"
Assert-That ($r.Code -eq 7)                  "still starts the real ptp without a config"

# Fallback to the 32-bit install location.
Remove-Item (Join-Path $dvs 'ptp-original.exe') -Force
New-Item -ItemType Directory -Force -Path $dvs86 | Out-Null
Copy-Item $fake (Join-Path $dvs86 'ptp-original.exe') -Force
Set-Content (Join-Path $dvs86 'dvs-ptpv2-unlock.conf') @('ptpv2 = 1') -Encoding ASCII
$r = Invoke-Wrapper @('-s', '-m1=en0')
Assert-That ($r.Out -match '-y2=-2')         "falls back to 'Program Files (x86)' install"
Assert-That ($r.Code -eq 7)                  "runs the real ptp from the (x86) location"

# --- Part B: the control panel ---------------------------------------------
Write-Host "`n== Part B: control panel functions ==" -ForegroundColor Cyan

$fakeDvs = Join-Path $work 'fake-dvs'
New-Item -ItemType Directory -Force -Path $fakeDvs | Out-Null
Set-Content (Join-Path $fakeDvs 'ptp.exe') 'ORIGINAL-PTP' -Encoding ASCII

. (Join-Path $repo 'dvs-ptpv2-unlock.ps1') -DvsDir $fakeDvs -LoadOnly

Assert-That (-not (Test-Installed)) "reports 'not installed' on a clean folder"

Set-Conf -ptpv2 $false
Assert-That ((Get-ConfValue 'ptpv2') -eq $false) "config round-trip: ptpv2 off"
Set-Conf -ptpv2 $true
Assert-That ((Get-ConfValue 'ptpv2') -eq $true)  "config round-trip: ptpv2 on"

Set-Content $Conf @('ptpv2 = ON') -Encoding ASCII
Assert-That (Get-ConfValue 'ptpv2')  "reads 'ON'"
Set-Content $Conf @('ptpv2 = false') -Encoding ASCII
Assert-That (-not (Get-ConfValue 'ptpv2'))  "reads 'false'"

# One switch: both halves of "enabled" must be false in every partial state,
# otherwise the GUI would claim PTPv2 is on while nothing actually happens.
Set-Content $Conf @('ptpv2 = 1') -Encoding ASCII
Assert-That (-not (Test-Enabled)) "config on but wrapper missing counts as DISABLED"

Invoke-Enable
Assert-That (Test-Installed)                                  "enable creates the ptp-original backup"
Assert-That ((Get-Content $Orig -Raw) -match 'ORIGINAL-PTP')  "backup contains the genuine original"
Assert-That ((Get-Item $Ptp).Length -eq (Get-Item $exe).Length) "ptp.exe was replaced by the wrapper"
Assert-That (Get-ConfValue 'ptpv2')                           "enable also switches the config on"
Assert-That (Test-Enabled)                                    "enable reports PTPv2 as enabled"

Set-Conf -ptpv2 $false
Assert-That (-not (Test-Enabled)) "wrapper installed but config off counts as DISABLED"

Invoke-Enable   # running it twice must not destroy the original
Assert-That ((Get-Content $Orig -Raw) -match 'ORIGINAL-PTP')  "second enable does NOT clobber the original"
Assert-That (Test-Enabled)                                    "second enable repairs the config too"

Invoke-Disable
Assert-That (-not (Test-Installed))                           "disable removes the backup"
Assert-That ((Get-Content $Ptp -Raw) -match 'ORIGINAL-PTP')   "disable restores the genuine original"
Assert-That (-not (Get-ConfValue 'ptpv2'))                    "disable also switches the config off"
Assert-That (-not (Test-Enabled))                             "disable reports PTPv2 as disabled"

Invoke-Disable   # disabling twice is harmless
Assert-That ((Get-Content $Ptp -Raw) -match 'ORIGINAL-PTP')   "second disable leaves the original in place"

# Live status must read the CHILD process: on Windows the wrapper stays alive as
# ptp.exe with DVS's ORIGINAL arguments while the real service runs as
# ptp-original.exe with the modified ones.
Assert-That ((Get-LiveStatus) -eq 'PTP service not running') "live status when nothing runs"

$procDir = Join-Path $work 'procs'
New-Item -ItemType Directory -Force -Path $procDir | Out-Null
Copy-Item $fake (Join-Path $procDir 'ptp.exe') -Force
Copy-Item $fake (Join-Path $procDir 'ptp-original.exe') -Force
Start-Process (Join-Path $procDir 'ptp.exe')          -ArgumentList '-s','-m1=en0','--hold' -WindowStyle Hidden
Start-Process (Join-Path $procDir 'ptp-original.exe') -ArgumentList '-m1=en0','-y2=-2','-m2=en0','--hold' -WindowStyle Hidden
Start-Sleep -Seconds 3
$live = Get-LiveStatus
Write-Host "  live status = '$live'"
Assert-That ($live -match 'PTPv2 enabled')      "live status reads the child (would be 'disabled' if it read the parent)"
Stop-PtpProcesses
Start-Sleep -Seconds 1
Assert-That ((Get-Process -Name 'ptp','ptp-original' -ErrorAction SilentlyContinue).Count -eq 0) `
            "Stop-PtpProcesses stops BOTH the wrapper and the child"

# --- result ------------------------------------------------------------------
# Exit explicitly: the implicit exit code of a pwsh -command run depends on $?
# and $LASTEXITCODE of whatever ran last (the stand-in ptp deliberately exits 7),
# which would make a fully passing run look like a failure.
Write-Host ""
if ($script:fails -gt 0) { Write-Host "$($script:fails) test(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "all tests passed" -ForegroundColor Green
exit 0
