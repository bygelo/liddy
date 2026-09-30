#!/bin/zsh
# cpuwatch.sh <seconds> <pattern...> — CPU seconds consumed during the window.
WINDOW=$1; shift
typeset -A start
for pat in "$@"; do
  pid=$(pgrep -f "$pat" | head -1)
  [ -z "$pid" ] && continue
  start[$pat]=$(ps -o cputime= -p $pid | tr -d ' ')
done
sleep $WINDOW
for pat in "$@"; do
  pid=$(pgrep -f "$pat" | head -1)
  [ -z "$pid" ] && continue
  now=$(ps -o cputime= -p $pid | tr -d ' ')
  rss=$(ps -o rss= -p $pid | tr -d ' ')
  python3 - "$pat" "${start[$pat]}" "$now" "$WINDOW" "$rss" <<'PY'
import sys
def sec(t):
    t = t.replace('-', ':')
    part = [float(x) for x in t.split(':')]
    total = 0.0
    for p in part: total = total * 60 + p
    return total
name, a, b, window, rss = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), float(sys.argv[5])
used = sec(b) - sec(a)
print(f"{name[:28]:<30} {used:6.2f}s cpu  {used/window*100:6.2f}%  {rss/1024:7.1f} MB")
PY
done
