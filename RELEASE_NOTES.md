## Install

1. Download **Cove.zip** below and double-click it.
2. Drag **Cove.app** into **Applications** and open it.
3. macOS says it can't verify the developer (Cove isn't notarized). Click **Done**, then open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
4. Cove opens its settings on the Permissions page. Allow what you want, then use **Connections** to hook up Claude Code, Codex, the browser extension and the terminal tools.

Building from source (`./scripts/install.sh`) signs Cove with a local certificate so macOS keeps its permissions across updates.

## What's new in 1.0.2

- **Calendar links**: paste your D2L subscribe link and Google Calendar's secret iCal address in Settings → Features, and your classes and due dates show up, with no Calendar app setup or calendar permission needed
- Recurring classes, moved or cancelled sessions, holidays and daylight saving time are all handled
- The Schedule tab tells you what's missing (and takes you to the fix) instead of just looking empty
- Settings catches the usual wrong link (the calendar's web page instead of its feed) before you save it

## What's new in 1.0.1

- Classes show up even if you allowed calendar access after Cove started (no restart needed)
- D2L and Canvas feeds: timed classes show as classes, assignments as due dates
- Settings → Features → Calendar shows which calendars Cove sees and your next class
- Pip is bigger and bolder beside the notch, and shows your next class time while napping

## Everything in Cove 1.0

- Pip, an animated buddy that naps beside the notch and reacts when agents work, finish, fail or need you
- Approve Claude Code permission prompts from the notch
- Live activities for Claude Code, Codex and long commands (`cove-run`)
- Browser extension: pings when ChatGPT, Claude or Gemini finishes in a background tab
- Classes happening now and up next, heads-up banners with Join links, and due dates from D2L or Canvas calendars and Reminders
- Screenshots land on the shelf the moment they're saved, with a draggable thumbnail
- Settings window with live permission status and one-click connections
- Volume and brightness meter, Now Playing tinted by album art, focus timer, battery alerts
