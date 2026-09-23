#!/bin/bash
# Evidence collection only: no power setting writes and no claimed verification.
set -euo pipefail
SOURCE="${1:-}"
[[ "$SOURCE" == charger || "$SOURCE" == battery ]] || { echo "Usage: $0 charger|battery [duration-seconds>=1800]" >&2; exit 1; }
DURATION="${2:-1800}"
[[ "$DURATION" =~ ^[0-9]+$ && "$DURATION" -ge 1800 && "$DURATION" -le 86400 ]] || exit 1
OUT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}runonsleep-${SOURCE}.XXXXXX")
printf 'Trial evidence: %s\nClose the lid only after starting RunOnSleep and your actual task.\n' "$OUT"
/usr/bin/sw_vers > "$OUT/system.txt"
/usr/sbin/sysctl hw.model >> "$OUT/system.txt"
/usr/bin/pmset -g assertions > "$OUT/assertions-before.txt"
START=$(/bin/date +%s)
while (( $(/bin/date +%s) - START < DURATION )); do
    /bin/date -u '+%Y-%m-%dT%H:%M:%SZ' >> "$OUT/heartbeat.txt"
    /usr/bin/pmset -g batt >> "$OUT/heartbeat.txt"
    /bin/sleep 5
done
/usr/bin/pmset -g assertions > "$OUT/assertions-after.txt"
/usr/bin/pmset -g log | /usr/bin/tail -n 3000 > "$OUT/power-log.txt"
printf 'Collected %s. Review timestamps against real task progress; this does not mark verification passed.\n' "$OUT"
