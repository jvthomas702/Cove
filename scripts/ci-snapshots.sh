#!/usr/bin/env bash
# CI only: launches the built Cove.app with its debug API, walks it through every state, and takes
# screenshots of the real UI into snapshots/. Also checks a few behaviors end to end.
set -uo pipefail

APP="build/Cove.app"
OUT="snapshots"
PORT=7777
API="http://127.0.0.1:$PORT"
mkdir -p "$OUT"
failures=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }

# Quiet config: nothing that would pop up a system permission prompt over the screenshots.
mkdir -p ~/.config/cove
cat > ~/.config/cove/config.json <<'JSON'
{ "calendar": false, "mirrorNotifications": false, "hud": "passive", "mediaApps": [], "sounds": false,
  "screenshotsToShelf": true, "bannerSeconds": 6 }
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
debug collapse; sleep 1

post /hook/claude '{"hook_event_name":"Stop","session_id":"ci","cwd":"/Users/you/hdc-classifier"}'
sleep 0.5; island 09-done-banner
debug collapse; sleep 1

debug approval; sleep 1.2; island 10-approval
debug deny-approvals; debug collapse; sleep 1

# A "screenshot" appears the way macOS writes one: hidden temp file, then renamed into place.
SHOT="$HOME/Desktop/Screenshot 2026-10-12 at 9.00.00 PM.png"
screencapture -x -R 0,0,640,400 "$HOME/Desktop/.tmp-shot.png"
mv "$HOME/Desktop/.tmp-shot.png" "$SHOT"
sleep 1.2; island 11-screenshot-banner
check "screenshot reached the shelf" "defaults read app.cove.island shelf 2>/dev/null | grep -q 'Screenshot 2026-10-12'"
debug expand/shelf; sleep 1; island 12-shelf
debug collapse; sleep 1

debug hud; sleep 0.3; island 13-hud
sleep 2; island 14-class-now

osascript -e 'quit app "Cove"' 2>/dev/null || pkill -x Cove
rm -f "$SHOT"
echo "failures: $failures"
exit "$failures"
