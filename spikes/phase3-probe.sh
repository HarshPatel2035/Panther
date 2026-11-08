#!/bin/bash
# Phase 3 evidence: every 5 s, log lid state, screen brightness, keyboard light and Low Power Mode.
#   spikes/phase3-probe.sh 240 > build/phase3-probe.log
set -u
cd "$(dirname "$0")/.." || exit 1
DURATION="${1:-240}"
end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
    lid=$(build/spike-sensors | awk -F': ' '/AppleClamshellState/{print $2}')
    screen=$(build/spike-display get 2>/dev/null | sed -n 's/.*brightness=\([0-9.]*\).*/\1/p')
    kb=$(build/spike-keyboard get | sed -n 's/.*brightness=\([0-9.]*\) auto=\([01]\).*/\1 auto=\2/p')
    lpm=$(pmset -g | awk '/lowpowermode/{print $2}')
    echo "$(date +%T) lid_closed=$lid screen=${screen:-n/a} keyboard=${kb:-n/a} lowpower=$lpm"
    sleep 5
done
