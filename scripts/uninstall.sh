#!/bin/bash
# Removes Panther and makes sure sleep is back to normal.
#   sudo scripts/uninstall.sh            removes the daemon, LaunchDaemon and CLI
#   sudo scripts/uninstall.sh --purge    also removes the journal and logs
set -uo pipefail

LABEL=com.panther.daemon
DAEMON=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
CLI=/usr/local/bin/panther

[ "$(id -u)" -eq 0 ] || { echo "uninstall.sh: run with sudo"; exit 1; }

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "Stopping pantherd (it restores sleep on the way out)..."
    launchctl bootout "system/$LABEL" || true
    for _ in 1 2 3 4 5; do launchctl print "system/$LABEL" >/dev/null 2>&1 || break; sleep 1; done
    if launchctl print "system/$LABEL" >/dev/null 2>&1; then
        echo "uninstall.sh: pantherd is still running; not removing it. Try again, or reboot first."
        exit 1
    fi
fi

# Belt and braces: replay the journal once more in case the daemon was killed rather than stopped.
if [ -x "$DAEMON" ]; then
    "$DAEMON" --restore-only || echo "WARNING: pantherd --restore-only reported a problem"
fi

# Never remove the only thing that can fix it while sleep is still disabled.
if pmset -g | grep -qE 'SleepDisabled[[:space:]]+1'; then
    echo "SleepDisabled is still 1; resetting it with pmset..."
    pmset -a disablesleep 0
    if pmset -g | grep -qE 'SleepDisabled[[:space:]]+1'; then
        echo "uninstall.sh: SleepDisabled is still 1. Nothing was removed. Run: sudo pmset -a disablesleep 0"
        exit 1
    fi
fi

pkill -x Panther 2>/dev/null || true
rm -f "$PLIST" "$DAEMON" "$CLI"
rm -rf /Applications/Panther.app
if [ "${1:-}" = "--purge" ]; then
    rm -rf "/Library/Application Support/Panther" /Library/Logs/Panther
fi

echo
pmset -g | grep SleepDisabled
echo "Panther removed.$([ "${1:-}" = "--purge" ] && echo " Journal and logs deleted.")"
