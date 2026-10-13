#!/usr/bin/env bash
# CI only: launches the built Cove.app with its debug API, walks it through every state, and takes
# screenshots of the real UI into snapshots/. Also checks a few behaviors end to end.
set -uo pipefail

APP="build/Cove.app"
OUT="$PWD/snapshots"
PORT=7777
API="http://127.0.0.1:$PORT"
mkdir -p "$OUT"
failures=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }

# Quiet config: nothing that would pop up a system permission prompt over the screenshots.
mkdir -p ~/.config/cove ~/Desktop
cat > ~/.config/cove/config.json <<'JSON'
{ "calendar": false, "mirrorNotifications": false, "assignmentCalendars": [], "hud": "passive", "mediaApps": [], "sounds": false,
  "screenshotsToShelf": true, "screenshotBanners": true, "sportsEnabled": false, "bannerSeconds": 6 }
JSON
defaults delete app.cove.island 2>/dev/null || true

BOUNDS="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null || echo "0, 0, 1920, 1080")"
WIDTH="$(echo "$BOUNDS" | awk -F', ' '{print $3}')"
echo "screen width: $WIDTH"
island() { screencapture -x -R "$((WIDTH / 2 - 380)),0,760,340" "$OUT/$1.png"; echo "snap $1"; }
full() { screencapture -x "$OUT/$1.png"; echo "snap $1"; }
post() { curl -s -m 3 -X POST -H 'Content-Type: application/json' --data-binary "$2" "$API$1" >/dev/null; }
debug() { curl -s -m 3 -X POST "$API/debug/$1" >/dev/null; }

open "$APP" --args --debug-api
for _ in $(seq 1 30); do curl -s -m 1 "$API/health" >/dev/null && break; sleep 0.5; done
check "server answers /health" "curl -s -m 2 $API/health | grep -q cove"
check "web pages are refused" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: https://evil.example' --data '{\"title\":\"x\"}' $API/event)\" = 403 ]"
check "extension origin is allowed" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: chrome-extension://abc' --data '{\"title\":\"x\",\"kind\":\"clear\",\"id\":\"x\"}' $API/event)\" = 200 ]"

sleep 1.2; island 01-welcome-banner
sleep 2; full 02-settings-permissions
debug settings/features; sleep 1; full 03-settings-features
debug settings/connections; sleep 1; full 04-settings-connections
debug close-settings; debug collapse; sleep 1.5
island 05-idle-pip

post /hook/claude '{"hook_event_name":"UserPromptSubmit","session_id":"ci","cwd":"/Users/you/hdc-classifier","prompt":"Add a confusion-matrix plot to eval.py"}'
post /hook/claude '{"hook_event_name":"PreToolUse","session_id":"ci","cwd":"/Users/you/hdc-classifier","tool_name":"Edit","tool_input":{"file_path":"/Users/you/hdc-classifier/eval.py"}}'
post /event '{"id":"train","title":"python train.py --dim 10000","body":"epoch 63/100","kind":"running","source":"command","progress":0.63}'
sleep 1; island 06-working

debug music; debug schedule; debug expand/home; sleep 1.2; island 07-expanded-home
debug expand/schedule; sleep 1; island 08-expanded-schedule

# Nothing connected: the Schedule tab says what to do instead of looking empty.
debug clear-schedule; debug expand/schedule; sleep 1; island 08b-schedule-connect
check "schedule tab asks to connect calendars" "curl -s -m 2 $API/debug/schedule-state | grep -q '\"events\":0'"

# Calendar links: serve feeds shaped like D2L's and Google's secret iCal address from this machine.
FEEDS="$HOME/cove-ci-feeds"
rm -rf "$FEEDS"; mkdir -p "$FEEDS"
python3 - "$FEEDS" <<'PY'
import datetime as dt, os, sys
from zoneinfo import ZoneInfo
root = sys.argv[1]
ny = ZoneInfo("America/New_York")
now = dt.datetime.now(ny).replace(second=0, microsecond=0)
def local(t): return t.strftime("%Y%m%dT%H%M%S")
def utc(t): return t.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
day = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
lecture = now - dt.timedelta(minutes=25)
lab = now + dt.timedelta(minutes=95)
series = lecture - dt.timedelta(days=21)
classes = f"""BEGIN:VCALENDAR
PRODID:-//Google Inc//Google Calendar 70.9054//EN
VERSION:2.0
X-WR-CALNAME:KSU Classes
X-WR-TIMEZONE:America/New_York
BEGIN:VEVENT
DTSTART;TZID=America/New_York:{local(series)}
DTEND;TZID=America/New_York:{local(series + dt.timedelta(minutes=75))}
RRULE:FREQ=WEEKLY;BYDAY={day[series.weekday()]}
UID:lecture@google.com
SUMMARY:CPE 3000 Lecture
LOCATION:Atrium 210
BEGIN:VALARM
TRIGGER:-PT10M
DESCRIPTION:Reminder
END:VALARM
END:VEVENT
BEGIN:VEVENT
DTSTART:{utc(lab)}
DTEND:{utc(lab + dt.timedelta(minutes=120))}
UID:lab@google.com
SUMMARY:Swarm robotics lab
LOCATION:ICSR Lab
DESCRIPTION:Join: https://kennesaw.zoom.us/j/555
END:VEVENT
END:VCALENDAR
"""
d2l = "\r\n".join([
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Desire2Learn Inc//D2L Calendar//EN", "X-WR-CALNAME:Student",
    "BEGIN:VEVENT", "UID:d2l-1", f"DTSTART:{utc(now + dt.timedelta(hours=20))}", f"DTEND:{utc(now + dt.timedelta(hours=20))}",
    "SUMMARY:Lab 5 Report - Due", "LOCATION:CPE 3000", "END:VEVENT",
    "BEGIN:VEVENT", "UID:d2l-2", f"DTSTART:{utc(now + dt.timedelta(days=3))}", f"DTEND:{utc(now + dt.timedelta(days=3))}",
    "SUMMARY:HW 7: Sequential circuits - Due", "END:VEVENT",
    "END:VCALENDAR", ""])
for path, text in [("d2l/le/calendar/feed/user/feed.ics", d2l), ("calendar/ical/classes/private-abc/basic.ics", classes)]:
    full = os.path.join(root, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    open(full, "w").write(text)
PY
debug add-feeds
for _ in $(seq 1 20); do curl -s -m 1 "$API/debug/schedule-state" | grep -q '"feeds":"ok' && break; sleep 0.5; done
curl -s -m 2 "$API/debug/schedule-state"; echo
check "calendar links load (classes and due dates)" "curl -s -m 2 $API/debug/schedule-state | grep -q '\"events\":2,\"due\":2,\"feeds\":\"ok:2,ok:2\"'"
debug expand/schedule; sleep 1; island 08c-schedule-from-links
debug expand/home; sleep 1; island 07b-home-from-links
debug collapse; debug settings/features; sleep 1.2; full 03b-settings-calendar-links
debug close-settings
debug collapse; sleep 1

post /hook/claude '{"hook_event_name":"Stop","session_id":"ci","cwd":"/Users/you/hdc-classifier"}'
sleep 0.5; island 09-done-banner
debug collapse; sleep 1

debug approval; sleep 1.2; island 10-approval
debug deny-approvals; debug collapse; sleep 1

# A "screenshot" appears the way macOS writes one: hidden temp file, then renamed into place.
SHOT="$HOME/Desktop/Screenshot 2026-10-12 at 9.00.00 PM.png"
screencapture -x -R 0,0,640,400 "$TMPDIR/fake-shot.png"
cp "$TMPDIR/fake-shot.png" "$HOME/Desktop/.tmp-shot.png"
mv "$HOME/Desktop/.tmp-shot.png" "$SHOT"
ls -la "$HOME/Desktop" | head
sleep 1.2; island 11-screenshot-banner
check "screenshot reached the shelf" "defaults read app.cove.island shelf 2>/dev/null | grep -q 'Screenshot 2026-10-12'"
debug expand/shelf; sleep 1; island 12-shelf
debug collapse; sleep 1

debug hud; sleep 0.3; island 13-hud
post /event '{"id":"train","title":"x","kind":"clear"}'
post /event '{"id":"claude:ci","title":"x","kind":"clear"}'
sleep 2; island 14-class-now

debug future-class; debug collapse; sleep 2; island 15-napping-next-class
zoom() { sips -c 60 420 --cropOffset 0 170 "$OUT/$1.png" --out "$OUT/$1-zoom.png" >/dev/null 2>&1 && sips -Z 1260 "$OUT/$1-zoom.png" >/dev/null 2>&1; }
zoom 15-napping-next-class; zoom 06-working

# Idle cost: Pip napping beside the notch, nothing else going on.
debug collapse; sleep 3
PID="$(pgrep -x Cove | head -1)"
if [ -n "$PID" ]; then
  total=0
  for _ in $(seq 1 10); do c="$(ps -p "$PID" -o %cpu= | tr -d ' ')"; total="$(echo "$total + $c" | bc)"; sleep 1; done
  avg="$(echo "scale=1; $total / 10" | bc)"
  echo "idle CPU: ${avg}% (average over 10 s)"
  echo "memory: $(ps -p "$PID" -o rss= | awk '{printf "%.0f MB", $1/1024}')"
  check "idle CPU under 5%" "[ \"\$(echo \"$avg < 5\" | bc)\" = 1 ]"
fi

osascript -e 'quit app "Cove"' 2>/dev/null || pkill -x Cove
rm -f "$SHOT"
echo "failures: $failures"
exit "$failures"
