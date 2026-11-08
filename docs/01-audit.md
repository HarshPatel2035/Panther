# Audit: Insomnia and REA

Date: 2026-11-07. Machine audited: MacBook Air M2 (Mac14,2), macOS 27.0.1 (26A434), Swift 6.2 (Command Line Tools only, no Xcode).

---

## Part 1 — Insomnia (krishhgg/Insomnia)

### What it is

A Swift menu bar app (about 16,300 lines of source, plus a large test suite) that keeps a MacBook awake with the lid closed for a timed session. MIT licensed, about 2k stars, created 2026-09-14, last stable release v0.1.0.

### The one trick everything rests on

macOS sleeps on the **lid-close event**. Normal keep-awake tools (`caffeinate`, Amphetamine without its helper, IOPM assertions) block *idle* sleep, but they do not block lid-close sleep, unless an external display and charger are connected.

The only supported switch that blocks lid-close sleep is the system power setting `SleepDisabled`:

```
sudo pmset -a disablesleep 1   # lid close no longer sleeps the Mac
sudo pmset -a disablesleep 0   # back to normal
```

Insomnia is mostly a safety wrapper around this one root-only setting, because the setting is **global and permanent until reset**. If the app dies with it set to 1, the Mac never sleeps on lid close again. Everything else in Insomnia is about undoing that safely.

### How Insomnia is built

| Layer | What it does | Key files |
|---|---|---|
| Sleep guard | Runs `sudo -n pmset -a disablesleep 1/0` through a **sudoers rule**, then reads the value back to confirm it | `Core/SleepGuard.swift` |
| Session manager | Timer, extend, end, reconcile after relaunch. **3,209 lines in one file** | `Core/SessionManager.swift` |
| Recovery journal | Writes every change to `state.json` *before* making it, so it can be undone | `Model/RuntimeState.swift`, `Store/Store.swift` |
| Backstop | A `launchd` user agent that runs `backstop.sh` **every 60 s** and undoes expired sessions if the app is gone | `scripts/backstop.sh`, `Core/LaunchdBackstop.swift` |
| Lid observer | IOKit notifications on `IOPMrootDomain`, key `AppleClamshellState` | `System/LidObserver.swift` |
| Lid actions | On close: panel and keyboard light to 0, freeze Slack/WhatsApp/Discord with `SIGSTOP`, mute audio, Low Power Mode. All undone on open | `Core/LidActions.swift`, `System/Freezer.swift`, `System/DisplayPower.swift`, `System/AudioControl.swift` |
| Safety floors | Low Power Mode below 40% battery, end below 10%, react to thermal state | `Core/FloorRules.swift`, `System/PowerMonitor.swift` |
| Extras | iPhone hotspot failover (1,105 lines), tmux "continue" nudge, Chrome throttling relaunch, App Nap overrides | `System/NetworkFailover.swift`, `System/TmuxNudge.swift`, … |
| UI | Custom SwiftUI drawn inside an `NSStatusItem` button (pills, hold-to-end ring, eye animation) | `UI/StatusItemController.swift` (864 lines) |

### What Insomnia does well (worth keeping as ideas)

1. **Journal before you change.** Write down what you are about to change, then change it, so recovery never has to guess.
2. **Read back after writing.** After setting `SleepDisabled`, read it back, because another tool can reset it.
3. **A session always has an end time.** It is never a plain on/off toggle.
4. **Only undo what you changed.** It only resumes processes it can prove it froze (PID + start time + boot session).
5. **The display stays lit under `disablesleep`.** Insomnia found that with sleep disabled, macOS no longer turns the built-in panel off on lid close. So the screen burns battery and heat inside a closed lid unless you turn it off yourself. This is a real, non-obvious finding.
6. Tests use fakes, so running them never touches real power settings.

### What is wrong with Insomnia

#### A. Evidence from *your* Mac

Insomnia v0.1.0 (build 1) is still installed:

- `~/Applications/Insomnia.app`
- launchd agent `com.insomnia.backstop` (loaded)
- sudoers rule `/etc/sudoers.d/insomnia`

Its log (`~/Library/Logs/Insomnia/insomnia.log`) shows:

- **Every session ended with `session end (quit)`.** Not one ended by the timer or the end button. That matches the macOS 27 bug below, where the end button doesn't work and Quit is the only way out.
- `notification authorization failed: Notifications are not allowed for this application`, on every launch. The ad-hoc signed app can't post notifications, so you never get its warnings.
- Low Power Mode switched on at 26% battery and off when you plugged in. That part worked.
- `SleepDisabled` is currently `0`, so your Mac is not stuck awake right now.

#### B. Known bugs (from its issue tracker, all affect macOS 27)

| # | Problem | Root cause |
|---|---|---|
| #60, #112, #128 | **End button does nothing**; clicks open the time fields | On macOS 27, clicks on a status item arrive at the item's *centre* on mouse-up. Insomnia's custom click and hold handling inside the status item can't work |
| #164 | **~48% of a CPU core** used while the countdown shows (v0.1.0) | SwiftUI redraws the status item every second. Fixed on `main`, but not in the stable release you have |
| #94 | **Mac stays awake for hours after the session ends** if the lid is still closed (battery 75% → 25%) | The lid-close event was swallowed while sleep was disabled. When the session ends no new event comes, and another app's idle assertion blocks idle sleep. Fix: call system sleep at session end when the lid is closed |
| #97 | Closed lid + external monitor: countdown frozen, apps frozen, audio muted while you are working | It treats "lid closed" as "nobody is using the Mac" and doesn't check for an external display |
| #123 | User can't tell whether the Mac really stayed awake | No clear evidence or diagnostics in the UI |
| #121, #103, #124 | Keyboard backlight restored to 0; mute skipped on some outputs; stale recovery error | Lots of fragile save-and-restore state for user-session tweaks |

#### C. Design problems

1. **Security: the sudoers rule.** It lets *any program running as your user* run `pmset -a disablesleep 1` with no password. Malware could keep your Mac awake in a bag. The README admits this.
2. **The safety net is a 60-second polling script.** If the app crashes, sleep stays disabled for up to a minute after the deadline. The backstop also can't restore audio or brightness, and it doesn't watch battery or heat. So the battery and heat safety only work while the UI app is alive.
3. **The UI process owns the dangerous state.** The thing most likely to crash (a SwiftUI app) is the thing responsible for undoing a global system setting.
4. **Too much scope for v0.1.** Hotspot failover, tmux nudging, Chrome relaunch, App Nap and Docker freezing each add state that must be undone. Most open bugs are in restore paths.
5. **Size.** `SessionManager.swift` is 3,209 lines, which makes it hard to change safely.
6. **No "awake until my program finishes" mode.** You asked for "run the program while the lid is closed". Insomnia only offers a timer, so you have to guess how long your job takes.

---

## Part 2 — REA (morluto/rea)

### What it is

"Reverse Engineer Anything": a TypeScript MCP server and CLI (`npx rea-agents`) that lets a coding agent inspect software **without its source code**. It works on native binaries (through Hopper, Ghidra, IDA or Kuna), Electron/JS apps, .NET, APKs, firmware, websites and network captures. It returns findings with evidence and limitations. MIT licensed.

### Where it fits for Panther (honest assessment)

REA's own skill file says to **skip REA for ordinary source-repository analysis**. Insomnia is open source, so we read its source directly, which is what Part 1 did. There's nothing to decompile there.

REA is useful where **Apple gives no source and no docs**, which is exactly the hard part of this project:

| Target (no source) | Question to answer | Why it matters for Panther |
|---|---|---|
| `/usr/bin/pmset` | Which API does `disablesleep` actually call? | Lets Panther's root daemon call the API directly instead of shelling out to `pmset` through sudo |
| `DisplayServices.framework`, `SkyLight.framework` | How does macOS really turn the built-in panel and keyboard backlight off? | The closed-lid screen-stays-lit problem. Insomnia's brightness-0 workaround is fragile (#121) |
| `powerd` behaviour | Which assertions block idle sleep after a session ends? | For the #94 fix: make sure the Mac sleeps at session end |

### First reverse-engineering pass (done, without installing REA)

Using `otool` / `nm` / `strings` on `/usr/bin/pmset` on your Mac:

- Imports `_IOPMSetSystemPowerSetting`, which is how `disablesleep` sets the `SleepDisabled` key. Panther's daemon can call this from IOKit directly, as root. No sudoers rule, no shell.
- Imports `_IOPMSleepSystem`, the API behind `pmset sleepnow`. That's the #94 fix.
- Links `DisplayServices.framework` and `SkyLight.framework`, which is likely how `displaysleepnow` and brightness are driven. This is the next RE target.
- Contains `IOPMTestClamshellClose` / `IOPMTestClamshellOpen` strings. pmset has a hidden way to **simulate a lid close**, which would let us test Panther without physically closing the lid. To be confirmed in Phase 0.

Deeper passes (decompiling the `disablesleep` code path and DisplayServices) need REA plus a native engine such as Ghidra. Installing that changes your agent configuration, so it's a decision for you (see questions in `02-architecture.md`).
