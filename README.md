# DVS PTPv2 Unlock

Unlocks PTPv2 and leader (grandmaster) mode on the Dante Virtual Soundcard —
with a double-click, on macOS and Windows.

[![build](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)

> **Disclaimer — community project, not supported by Audinate.**
> This is an independent, unofficial community effort. It is **not affiliated
> with, endorsed by, or supported by Audinate**, and it uses undocumented
> options of the Dante Virtual Soundcard. Do not ask Audinate support for help
> with it. Use at your own risk: it replaces a file inside the DVS installation
> and may stop working — or break DVS — with any DVS update. It may also affect
> your warranty or support entitlement. Deactivate it and restore the original
> `ptp` before contacting Audinate about any DVS issue. Dante and Dante Virtual
> Soundcard are trademarks of Audinate Pty Ltd.


## What it does

DVS's `ptp` service can do more than the app normally exposes. This tool puts a
small wrapper in place of the `ptp` binary; the wrapper then calls the real one
with the **same arguments except for the options you turn on**:

- **PTPv2 support** — adds `-y2=-2` and mirrors the `-m1=` interface to `-m2=`.
- **Leader mode** — drops the `-s` (slave-only) flag so DVS can become the PTP
  leader / grandmaster.

Both options are read at **runtime** from a small config file
(`dvs-ptpv2-unlock.conf`), so once installed you can change them at any time —
**no editing source, no recompiling, no reinstalling.**

The original `ptp` is kept as `ptp-original` and restored when you deactivate.


## macOS: download and double-click

1. Download **`dvs-ptpv2-unlock-macos.zip`** from the [Releases](../../releases)
   page and unzip it. It contains a **prebuilt universal binary** (Apple Silicon
   + Intel), so you need **no compiler and no Terminal**.
2. Double-click **`DVS PTPv2 Unlock.app`** and pick from the menu:
   - **Activate** / **Deactivate** the wrapper
   - **Edit options** — tick PTPv2 and/or leader mode
   - **Show status** — see below
3. Enter your password once when macOS asks. The change is applied and the
   **PTP service is restarted for you** — no manual DVS restart needed.

> **First launch:** the app isn't from the App Store, so macOS blocks it once.
> Right-click **`DVS PTPv2 Unlock.app`** → **Open** → **Open**. Only needed once.
>
> If macOS still refuses (quarantine flag on downloaded archives), clear it once:
> ```
> xattr -dr com.apple.quarantine "DVS PTPv2 Unlock.app"
> ```

`dvs-ptpv2-unlock.command` is the same control panel without the app wrapper —
double-click it directly if you prefer. Run from a plain `git clone` (no prebuilt
binary), it compiles for you, which needs the Command Line Tools
(`xcode-select --install`).


## Windows: download and double-click

1. Download **`dvs-ptpv2-unlock-windows.zip`** from the [Releases](../../releases)
   page and unzip it. It contains a **prebuilt `dvs-ptpv2-unlock.exe`**, so you
   need no compiler.
2. Double-click **`DVS PTPv2 Unlock.cmd`**. Windows asks for administrator
   rights (UAC) once, then the same menu opens: **Activate** / **Deactivate**,
   **Edit options**, **Show status**.
3. Each change is applied and the **Dante Virtual Soundcard service is stopped
   and restarted for you** — required on Windows, because a running `.exe` is
   locked and cannot be replaced while in use.

Both `C:\Program Files\...` and `C:\Program Files (x86)\...` installations are
detected automatically.

> The `.cmd` only launches `dvs-ptpv2-unlock.ps1` with the execution policy
> bypassed for that single run; nothing on your system is changed permanently.


## Show status

**Show status** reports two things, so you can tell intent from reality:

- **Configured (desired)** — what `dvs-ptpv2-unlock.conf` asks for.
- **Live (what DVS runs now)** — read from the **running** PTP process, so it
  answers "is PTPv2 actually enabled right now?" even before anything is
  installed.

```
Wrapper : installed
Configured (desired):      PTPv2: enabled, Leader mode: disabled
Live (what DVS runs now):  PTPv2 enabled, leader mode disabled
```

If those two disagree, DVS hasn't picked up the change yet — or a DVS update
reverted the wrapper (see the note below).


## Changing options later

Use **Edit options** in the control panel (it applies the change and restarts the
PTP service). Or edit `dvs-ptpv2-unlock.conf` in the DVS folder by hand and
restart DVS yourself. Values accept `1/0`, `true/false`, `yes/no`, `on/off`:

```
leader = 1
ptpv2  = 1
```

> **After a DVS update:** the updater replaces `ptp` with Audinate's original and
> silently reverts the wrapper. Open the control panel and activate again.
> **Show status** tells you if this has happened.


## Command-line install (macOS, Makefile)

    Targets:

	h|help		shows this help
	b|build		compiles dvs-ptpv2-unlock
	c|clean		removes the built binary
	status		shows if the wrapper is installed and current options
	dir		echoes the DVS directory

    The following targets require sudo:

	install		installs the PTP wrapper (and default config)
	uninstall	restores the original ptp

1. Open **Terminal** and `cd` into this folder.
2. `make build` — compiles `dvs-ptpv2-unlock`.
3. `sudo make install` — backs up `ptp` to `ptp-original`, installs the wrapper
   and a default `dvs-ptpv2-unlock.conf`. The backup step is **skipped if
   `ptp-original` already exists**, so running install twice can never overwrite
   the real original.
4. Edit `dvs-ptpv2-unlock.conf` (see above) and restart DVS.
5. `sudo make uninstall` — restores the original `ptp`.
6. `make status` — check what's installed and configured.


## Building it yourself

**macOS** — universal binary plus the launcher app:

```
cc -arch arm64 -arch x86_64 -o dvs-ptpv2-unlock dvs-ptpv2-unlock.c && ./build-app.sh
```

`build-app.sh` bundles the control script, config, and binary *inside* the app
and re-signs it (ad-hoc), which keeps it working under macOS App Translocation.

**Windows** — if you have no compiler, the
[mingw installer](https://github.com/Vuniverse0/mingwInstaller/releases/) works:

```
gcc -DWIN32 -O2 -o dvs-ptpv2-unlock.exe dvs-ptpv2-unlock.c
```

Every push is built for macOS and Windows in CI, and the Windows job runs an
end-to-end test suite (`tests/windows-test.ps1`) that exercises the real binary
and the control-panel functions against a temporary DVS folder.


## Manual installation (either OS)

In the DVS application folder (macOS
`/Library/Application Support/Audinate/DanteVirtualSoundcard`, Windows
`C:\Program Files\Audinate\Dante Virtual Soundcard`): rename the original `ptp`
to `ptp-original`, put the compiled `dvs-ptpv2-unlock` in its place as `ptp`, and
drop a `dvs-ptpv2-unlock.conf` next to it.

On Windows the files carry an `.exe` extension (`ptp.exe`, `ptp-original.exe`),
and DVS must be stopped first — a running executable cannot be replaced.


## Compile-time defaults (optional)

The config file is the normal way to set options. For a binary that behaves a
certain way even **without** a config file, uncomment the defaults at the top of
`dvs-ptpv2-unlock.c`:

```
// #define DEFAULT_ALLOW_LEADER 1
// #define DEFAULT_ENABLE_PTPV2 1
```


## How it works

The wrapper `exec`s (macOS) or spawns (Windows) the original `ptp` binary with
the argument list it was given, minus `-s` when leader mode is on, plus
`-y2=-2 -m2=<iface>` when PTPv2 is on. It adds no daemon, changes no system
settings, and touches nothing outside the DVS application folder.
