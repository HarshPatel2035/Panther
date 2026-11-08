#!/bin/bash
# Installs Panther. Needs your admin password once:   scripts/build.sh && sudo scripts/install.sh
#
# Installs:
#   /Library/PrivilegedHelperTools/com.panther.daemon   root daemon (the only thing that touches SleepDisabled)
#   /Library/LaunchDaemons/com.panther.daemon.plist     launchd job: KeepAlive, Mach service com.panther.daemon
#   /usr/local/bin/panther                              CLI
#   /Applications/Panther.app                           menu bar app
# No sudoers rule. pantherd accepts XPC only from the exact panther CLI and Panther.app installed here
# (both cdhashes pinned).
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=com.panther.daemon
DAEMON=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
CLI=/usr/local/bin/panther
APP=/Applications/Panther.app
LOGDIR=/Library/Logs/Panther

[ "$(id -u)" -eq 0 ] || { echo "install.sh: run with sudo: sudo scripts/install.sh"; exit 1; }
for f in build/release/pantherd build/release/panther build/release/Panther.app/Contents/MacOS/Panther; do
    [ -f "$f" ] && [ ! -L "$f" ] || { echo "install.sh: $f missing. Run scripts/build.sh first (without sudo)."; exit 1; }
done

# Copy into a root-owned staging folder first, then verify and install *that* copy, so nothing can swap
# the files in the user-writable build folder between the check and the install.
STAGE="$(mktemp -d /tmp/panther-install.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
chmod 0700 "$STAGE"
cp build/release/pantherd build/release/panther "$STAGE/"
# --noextattr etc.: drop Finder/iCloud metadata (the Desktop is often iCloud-synced, and those
# attributes make strict signature checks fail with "resource fork, Finder information ... not allowed").
ditto --norsrc --noextattr --noqtn --noacl build/release/Panther.app "$STAGE/Panther.app"
chown -R root:wheel "$STAGE"
chmod 0755 "$STAGE/pantherd" "$STAGE/panther"
chmod -R go-w "$STAGE/Panther.app"
for f in "$STAGE/pantherd" "$STAGE/panther"; do
    codesign --verify --strict "$f" || { echo "install.sh: $f signature doesn't verify; rebuild"; exit 1; }
done
codesign --verify --strict --deep "$STAGE/Panther.app" || { echo "install.sh: Panther.app signature doesn't verify; rebuild"; exit 1; }
[ "$(codesign -dv "$STAGE/Panther.app" 2>&1 | awk -F= '/^Identifier=/{print $2}')" = "com.panther.app" ] \
    || { echo "install.sh: Panther.app has the wrong signing identifier"; exit 1; }
[ "$(codesign -dv "$STAGE/pantherd" 2>&1 | awk -F= '/^Identifier=/{print $2}')" = "com.panther.daemon" ] \
    || { echo "install.sh: pantherd has the wrong signing identifier"; exit 1; }
[ "$(codesign -dv "$STAGE/panther" 2>&1 | awk -F= '/^Identifier=/{print $2}')" = "com.panther.cli" ] \
    || { echo "install.sh: panther has the wrong signing identifier"; exit 1; }
echo "Installing pantherd with cdhash $(codesign -dvvv "$STAGE/pantherd" 2>&1 | awk -F= '/^CDHash=/{print $2}')"
echo "  (compare with the cdhash scripts/build.sh printed)"

if [ -e /etc/sudoers.d/insomnia ] || launchctl print "gui/${SUDO_UID:-501}/com.insomnia.backstop" >/dev/null 2>&1; then
    echo "WARNING: Insomnia is still installed. Both tools change SleepDisabled; uninstall Insomnia soon."
fi

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "Stopping the running pantherd (any active session ends, sleep is restored)..."
    launchctl bootout "system/$LABEL" || true
    sleep 1
fi

echo "Installing binaries..."
mkdir -p /Library/PrivilegedHelperTools /usr/local/bin "$LOGDIR"
install -o root -g wheel -m 0755 "$STAGE/pantherd" "$DAEMON"
install -o root -g wheel -m 0755 "$STAGE/panther" "$CLI"
pkill -x Panther 2>/dev/null || true          # quit an older menu bar app before replacing it
rm -rf "$APP"
ditto --norsrc --noextattr --noqtn --noacl "$STAGE/Panther.app" "$APP"
chmod 0755 "$LOGDIR"

cdhash() { codesign -dvvv "$1" 2>&1 | awk -F= '/^CDHash=/{print $2}'; }
CLI_CDHASH="$(cdhash "$CLI")"
APP_CDHASH="$(cdhash "$APP")"
for h in "$CLI_CDHASH" "$APP_CDHASH"; do
    [[ "$h" =~ ^[0-9a-f]{40}$ ]] || { echo "install.sh: could not read a client cdhash"; exit 1; }
done
REQUIREMENT="cdhash H\"$CLI_CDHASH\" or cdhash H\"$APP_CDHASH\""

echo "Writing $PLIST (clients pinned to: $REQUIREMENT)..."
TMP="$STAGE/$LABEL.plist"
plutil -create xml1 "$TMP"
plutil -insert Label -string "$LABEL" "$TMP"
plutil -insert ProgramArguments -array "$TMP"
plutil -insert ProgramArguments.0 -string "$DAEMON" "$TMP"
plutil -insert ProgramArguments.1 -string "--client-requirement" "$TMP"
plutil -insert ProgramArguments.2 -string "$REQUIREMENT" "$TMP"
plutil -insert MachServices -dictionary "$TMP"
plutil -insert "MachServices.${LABEL//./\\.}" -bool true "$TMP"   # dots escaped: plutil reads them as a key path
plutil -insert RunAtLoad -bool true "$TMP"
plutil -insert KeepAlive -bool true "$TMP"
plutil -insert ProcessType -string Interactive "$TMP"
plutil -insert StandardErrorPath -string "$LOGDIR/pantherd.log" "$TMP"
plutil -lint "$TMP" >/dev/null
install -o root -g wheel -m 0644 "$TMP" "$PLIST"

launchctl enable "system/$LABEL"
launchctl bootstrap system "$PLIST"
sleep 1

# Register with Launch Services so Finder, Spotlight and the Apps view know the new copy.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true

# Start the menu bar app for the logged-in user (also when doctor only has warnings).
sudo -u "${SUDO_USER:-$(stat -f %Su /dev/console)}" open "$APP" || true

echo
if sudo -u "${SUDO_USER:-$(stat -f %Su /dev/console)}" "$CLI" doctor; then
    echo
    echo "Panther is installed. Look for the paw print in your menu bar."
    echo "Terminal users:  panther run -- <command>"
else
    echo
    echo "Installed, but doctor found problems. Log: $LOGDIR/pantherd.log"
    exit 1
fi
