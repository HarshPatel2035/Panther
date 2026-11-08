#!/bin/bash
# Real closed-lid test: writes one timestamp per second for N seconds, then reports any gap > 3 s
# (a gap means the Mac slept). Run it through Panther:
#   panther run -- spikes/lid-test.sh 300
set -u
SECONDS_TO_RUN="${1:-300}"
LOG="$(dirname "$0")/../build/lid-test.log"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

echo "lid test: logging every second for $SECONDS_TO_RUN s to $LOG. Close the lid now, open it after ~3 min."
end=$(( $(date +%s) + SECONDS_TO_RUN ))
while [ "$(date +%s)" -lt "$end" ]; do
    date +%s >> "$LOG"
    sleep 1
done

prev=""
gaps=0
while read -r t; do
    if [ -n "$prev" ] && [ $(( t - prev )) -gt 3 ]; then
        echo "GAP: $(( t - prev )) s at $(date -r "$prev" +%T) -> $(date -r "$t" +%T)"
        gaps=$(( gaps + 1 ))
    fi
    prev="$t"
done < "$LOG"
echo "lid test done: $(wc -l < "$LOG" | tr -d ' ') samples, $gaps gap(s). $([ "$gaps" -eq 0 ] && echo PASS || echo FAIL)"
