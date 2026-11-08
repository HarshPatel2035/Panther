#!/bin/bash
# Phase 0 root tests. Run from the project root:   sudo spikes/run-root-tests.sh
# Whatever happens (error, Ctrl-C), the trap puts SleepDisabled back to 0 and the fake lid back open.
# Results are appended to build/root-tests.log; paste that file back to Claude.
set -u
cd "$(dirname "$0")/.." || exit 1
[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo spikes/run-root-tests.sh"; exit 1; }
for b in sleepguard sensors clamshell display; do
    [ -x "build/spike-$b" ] || { echo "missing build/spike-$b, run: make -C spikes"; exit 1; }
done

LOG=build/root-tests.log
exec > >(tee -a "$LOG") 2>&1
restore() {
    echo "--- restore"
    build/spike-clamshell open >/dev/null 2>&1
    build/spike-sleepguard set 0
    pmset -g | grep -E 'SleepDisabled'
}
trap restore EXIT INT TERM

echo "=== Panther Phase 0 root tests $(date -u +%FT%TZ) on $(sw_vers -productVersion) $(sysctl -n hw.model)"

echo; echo "### 1. SleepDisabled through IOPMSetSystemPowerSetting (no pmset, no sudoers)"
build/spike-sleepguard get
build/spike-sleepguard set 1
echo "pmset agrees? ->"; pmset -g | grep -E 'SleepDisabled'
echo "kernel: AppleClamshellCausesSleep = $(ioreg -r -k AppleClamshellCausesSleep -d 1 | awk -F'= ' '/AppleClamshellCausesSleep/{print $2}')"

echo; echo "### 2. Simulated lid close (IOPMTestClamshellClose), with sleep disabled so it can't sleep"
build/spike-clamshell close
sleep 2
build/spike-sensors | grep -E 'lid|display|SleepDisabled'
build/spike-clamshell open
sleep 2
build/spike-sensors | grep -E 'lid'

echo; echo "### 3. Back to normal"
build/spike-sleepguard set 0

echo; echo "Done. Next, as your normal user (no sudo), try the two screen-off methods:"
echo "  build/spike-display try-brightness-off 5     # panel goes black for 5 s, then comes back"
echo "  pmset displaysleepnow                        # SkyLight display idle; move the mouse to wake"
