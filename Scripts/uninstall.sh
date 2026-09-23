#!/bin/bash
set -euo pipefail
if [[ "$EUID" -ne 0 ]]; then
    printf 'Quit RunOnSleep first. This removes its helper and the copy in /Applications.\n'
    exec /usr/bin/sudo /bin/bash "$0" "$@"
fi
STATE='/Library/Application Support/RunOnSleep'
HELPER=/Library/PrivilegedHelperTools/com.runonsleep.helper
if /bin/launchctl print system/com.runonsleep.helper >/dev/null 2>&1; then
    /bin/launchctl bootout system/com.runonsleep.helper
fi
if [[ -x "$HELPER" && -f "$STATE/owner.json" ]]; then
    RECOVERED=0
    for attempt in 1 2 3 4 5; do
        if "$HELPER" --recover-only; then RECOVERED=1; break; fi
        /bin/sleep 1
    done
    if [[ "$RECOVERED" != 1 ]]; then
        echo 'Global state is unresolved. Helper is stopped; recovery files are retained.' >&2
        echo 'Review the recovery guide, resolve the global setting, then rerun this utility.' >&2
        exit 2
    fi
fi
/bin/rm -f /Library/LaunchDaemons/com.runonsleep.helper.plist "$HELPER"
/bin/rm -f /var/run/com.runonsleep.helper/control.sock
/bin/rmdir /var/run/com.runonsleep.helper 2>/dev/null || true
# Retain user verification records. Remove only known helper state after successful recovery.
/bin/rm -f "$STATE/owner.json" "$STATE/journal.json" "$STATE/journal.json.pending" "$STATE/helper.lock"
/bin/rmdir "$STATE" 2>/dev/null || true
if [[ -d /Applications/RunOnSleep.app ]]; then
    ID=$(/usr/bin/defaults read /Applications/RunOnSleep.app/Contents/Info CFBundleIdentifier 2>/dev/null || true)
    [[ "$ID" != com.runonsleep.app ]] || /bin/rm -rf /Applications/RunOnSleep.app
fi
/usr/sbin/pkgutil --forget com.runonsleep.helper.pkg >/dev/null 2>&1 || true
echo 'RunOnSleep helper removed. Existing external sleep settings were preserved.'
echo 'Remove any other copies of RunOnSleep.app manually; disable its login item in System Settings if present.'
