# Phase 0 — Reverse-engineering findings

Date: 2026-11-07 · MacBook Air M2 (Mac14,2) · macOS 27.0.1 (26A434)

Status legend: ✅ confirmed on this Mac · 🟡 confirmed up to "needs root", final check in `spikes/run-root-tests.sh` · ❌ ruled out

## Summary

| # | Question | Answer | Status |
|---|---|---|---|
| 1 | How does `pmset disablesleep` work? | `IOPMSetSystemPowerSetting(CFSTR("SleepDisabled"), kCFBooleanTrue/False)`, read back with `IOPMCopySystemPowerSettings()`. Works as root (`0x0`, read back 1, pmset agrees); unprivileged it returns `0xe00002c1` | ✅ |
| 2 | How do we sleep the Mac at session end (Insomnia #94)? | `IOPMSleepSystem(IOPMFindPowerManagement(kIOMainPortDefault))`, the call behind `pmset sleepnow` | 🟡 (spike built, not run: it really sleeps the Mac) |
| 3 | Can we fake a lid close for tests? | Yes. pmset's hidden `clamshell 0/1` verb sets property `IOPMTestClamshellClose` / `IOPMTestClamshellOpen` on `IOPMrootDomain` via `IORegistryEntrySetCFProperty`. Unprivileged: `0xe00002e2` (`kIOReturnNotPermitted`). **Refused even as root** (`0xe00002e2`): needs a development kernel | ❌ |
| 4 | Lid and display state | `IOPMrootDomain` → `AppleClamshellState` (lid) and `AppleClamshellCausesSleep` (reads `No` regardless of `SleepDisabled`, so not used). External displays: `CGGetOnlineDisplayList` + `CGDisplayIsBuiltin` | ✅ |
| 5 | Turn the built-in panel off | `DisplayServicesGetBrightness(id, float*)` / `DisplayServicesSetBrightness(id, float)` work (read 0.647). `DisplayServices*PowerMode` exists but **`HasPowerMode` = 0 on the built-in panel**, so it's not usable. Second option: `SLSDisplayManagerRequestDisplaysIdle` (SkyLight), which is what `pmset displaysleepnow` calls on macOS 27 (not `IORequestIdle`, which Insomnia used) | ✅ brightness · ❌ power mode · ❌ SkyLight idle (woke again the same second) |
| 6 | Heat signal | **Battery temperature is not exposed** on this Mac: no top-level `Temperature`; `AverageBattSkinTemp` = `AverageBattVirtualTemp` = 0. Use the public thermal-pressure notification `kOSThermalNotificationPressureLevelName` (read 1 = moderate during the test) plus `ProcessInfo.thermalState` | ✅ |
| 7 | Power draw (for "in a bag?") | `AppleSmartBattery` → `PowerTelemetryData.SystemLoad` in mW (read 8.90 W). Still to check: does it update live? | ✅ / 🟡 |

## Root test results (2026-11-07 13:45 UTC, `spikes/run-root-tests.sh`)

| Test | Result | Verdict |
|---|---|---|
| `IOPMSetSystemPowerSetting(SleepDisabled, 1)` as root | `0x00000000`, read back 1, `pmset -g` shows `SleepDisabled 1` | ✅ **Panther's core mechanism works. No pmset, no sudoers** |
| `IOPMSetSystemPowerSetting(SleepDisabled, 0)` as root | `0x00000000`, read back 0, and the exit trap restored it again | ✅ |
| `IOPMTestClamshellClose/Open` as root | `0xe00002e2` (`kIOReturnNotPermitted`) even as root; lid state unchanged | ❌ **Fake lid is not available on a production kernel.** pmset carries the code, but the kernel refuses it. Lid tests: fake `LidSensor` in unit tests + the manual real-lid checklist |
| `AppleClamshellCausesSleep` | `No` with `SleepDisabled` 0 *and* 1, lid open | ❌ Not a reliable "will the lid sleep the Mac?" signal while the lid is open. `panther doctor` uses `SleepDisabled` read-back instead |
| `pmset displaysleepnow` (SkyLight `SLSDisplayManagerRequestDisplaysIdle`) | power log: `Display is turned off` and `Display is turned on` both at 09:46:02 local time. WhatsApp was holding two `PreventUserIdleDisplaySleep` assertions | ❌ **Unreliable as the screen-off method:** any app holding a display assertion (WhatsApp, Chrome video, Slack calls) wakes the screen at once. Brightness 0 is the method; display idle is only a best-effort extra |
| `DisplayServicesSetBrightness(0)` then restore | read 0.000 during, 0.654 after | ✅ by the API's own read-back (visual check pending) |

## How each answer was found

**pmset** (`/usr/bin/pmset`, universal binary, arm64e slice):
- `nm -arch arm64e -u` lists the imports: `_IOPMSetSystemPowerSetting`, `_IOPMCopySystemPowerSettings`, `_IOPMSleepSystem`, `_IORegistryEntrySetCFProperty`, `_SLSDisplayManagerRequestDisplaysIdle`.
- `otool -arch arm64e -tV` disassembly: the argument parser compares `"clamshell"` at `0x100007b60`. The handler at `0x1000091b0` does `strtol(value)`, picks one of two CFStrings, and calls `0x10000dbb0`. That helper does `IOServiceGetMatchingService(IOServiceNameMatching("IOPMrootDomain"))` → `IORegistryEntrySetCFProperty`. Its error string is `"pmset: Error 0x%x setting clamshell close property"`. The same block also has `acattach` (fake charger plug/unplug: `IOPMTestACAttach`/`IOPMTestACDetach`) and `desktopmode`, which are useful for testing the battery rules later.

**DisplayServices** (a private framework that lives only in the dyld shared cache):
- `dyld_info -exports` lists 52 functions.
- The CLT `lldb` crashes on this Mac, so I wrote `tools/fndump.c`. It `dlopen`s the framework, strips the pointer-auth bits from the symbol, dumps its instructions, resolves `BL` targets with `dladdr`, and resolves `ADRP+ADD` constants to CFStrings. `otool` then disassembles the dump.
- Result: every getter or setter is `getDSClientQueued()` → an Objective-C message carrying a property key and the display ID. Keys: `DisplayServicesBrightness`, `DisplayServicesPowerMode`, `DisplayServicesPowerButtonEnabled`. `GetPowerMode` takes **one** argument and returns the value. `SetPowerMode(display, int mode)` boxes the mode as an NSNumber.

**REA:** not needed for these answers. Running it would also need Node ≥ 22.23.4 (this Mac has 22.14.0) and Ghidra (JDK 23 is already installed). Its `rea setup --dry-run` shows the plan without writing anything. For Claude Code it would add `mcpServers.rea` to `~/.claude.json` and a skill in `~/.claude/skills`, with backups. Keep REA for a target `fndump` can't handle, such as a full Objective-C class like CoreBrightness's keyboard backlight client.

## Changes to the architecture (applied to 02-architecture.md)

1. **Bag rule:** use thermal pressure ≥ heavy (2) for 10 min with lid closed + no display, or pressure "trapping"/"sleeping" at any time. Battery temperature is dropped. `SystemLoad` is logged as evidence and isn't trusted as a trigger until we verify it updates.
2. **Screen off:** brightness 0 is the method (and the keyboard backlight separately). Display-idle requests are undone at once by apps holding `PreventUserIdleDisplaySleep` (WhatsApp did in the test), and power mode is unsupported, so neither is relied on.
3. **Testing:** the fake lid is refused on this kernel, so lid logic is tested through a fake `LidSensor` plus the real-lid checklist. (`IOPMTestACAttach/Detach` is probably refused the same way; not relied on.)
4. **`panther doctor`** confirms the guard by reading `SleepDisabled` back through `IOPMCopySystemPowerSettings`.

## Phase 3 additions (2026-11-07)

**Keyboard backlight.** `CoreBrightness.framework` → Objective-C class `KeyboardBrightnessClient`. Methods were listed with `tools/objcdump.m`, which reads the Objective-C runtime:

| Method | Type encoding | Meaning |
|---|---|---|
| `copyKeyboardBacklightIDs` | `@16@0:8` | NSArray of keyboard IDs (UInt64); +1 retained |
| `isKeyboardBuiltIn:` | `B24@0:8Q16` | |
| `brightnessForKeyboard:` | `f24@0:8Q16` | 0…1 |
| `setBrightness:forKeyboard:` | `B28@0:8f16Q20` | returns success |
| `isAutoBrightnessEnabledForKeyboard:` / `enableAutoBrightness:forKeyboard:` | `B24…` / `B28@0:8B16Q20` | |

Verified with `spikes/keyboard.m`: set returns 1, and auto-brightness toggles and restores. Important: **auto-brightness has to be turned off while the lid is closed.** The covered light sensor reads "dark", and auto-brightness would turn the keyboard light *on*. Panther restores the auto setting itself, not only the level.

**Low Power Mode.** pmset writes it into the per-profile PM preferences (`IOPMSetPMPreferences`). On this Mac the key is `lowpowermode`. Strings in the binary also include `powermode` and `highpowermode`, and Insomnia #69 reports `powermode` on macOS 26.7.1. Panther runs `/usr/bin/pmset -b lowpowermode <0|1>` as root, falls back to `powermode`, and reads the result from `ProcessInfo.isLowPowerModeEnabled` instead of parsing pmset output.

**Live evidence for the screen problem** (Phase 2 build, 30-minute session, lid closed, 17:49): `lid_closed=1 screen=0.491 keyboard=0.000 lowpower=0`. With sleep disabled, the panel stays at 49% brightness inside the closed lid.

## Toolchain (resolved 2026-11-07)

The old Command Line Tools had a Swift compiler / SDK mismatch and a stale 2023 `module.modulemap`, so Swift couldn't import Foundation. After a clean reinstall: **Swift 6.4.2, macOS 27.2 SDK**, and `swift build` works.

One packaging gap remains: `swift test` can't find the Swift Testing macro plugin (`TestingMacros ... plugin not found`). Passing `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` fixes it, and `scripts/test.sh` does that.

## Files

- `spikes/common.h`, `sleepguard.c`, `sensors.c`, `sleepnow.c`, `clamshell.c`, `display.c`, `Makefile`: build with `make -C spikes`, binaries go to `build/`
- `spikes/run-root-tests.sh`: the root tests; it always restores `SleepDisabled=0` on exit
- `tools/fndump.c`: the small reverse-engineering helper
