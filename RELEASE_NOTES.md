# Cove 1.1.0

- Pick favorite NBA, NFL and college football teams. Automatically follow the next favorite matchup and enable game-start or scoring alerts when you want them.
- Follow several games while one selected game keeps its full play-by-play, drives and stats. Favorite unranked college teams stay visible beside Top 25 games.
- Pin the notch open, unpin it, or close it explicitly. Tabs and controls stay anchored beside the notch as panel sizes change.
- Preview screenshots, draw or add text, save an annotated copy, rename saved copies, and undo shelf removals or Clear. Original files remain untouched.
- Browse connected AI tasks with filters, elapsed time, current previews and return-to-app/tab actions.
- Check for signed app updates from Cove. Automatic download/install is opt-in; update archives and feeds are verified before installation.

The existing quiet screenshot capture, persistent shelf, 200 bundled team logos, and ESPN Gamecast remain available.

## Upcoming changes

- Sports widgets use team colors in score accents, game cards and the compact notch display.
- AI work widget with live browser reply previews, elapsed time, retained completions and activity selection.
- Best-effort ChatGPT desktop monitoring through visible Accessibility controls, with clear permission and unavailable states.

- Choose the Home widget you want: Calendar, Music, Focus or Sports. Automatic hides inactive cards.
- NBA, NFL and college football game picker, pinned notch scores and a scrollable play-by-play feed. College football defaults to Top 25 matchups.
- Screenshots arrive quietly by default. Optional thumbnail banners remain available in Features.
- Old, renamed or moved screenshot files no longer cause repeat popups; denied folder access stays in Permissions.
- The island keeps your selected tab when you close and reopen it.

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

- Add team logos to sports cards, the score header, and the compact notch, with cached images and offline abbreviation fallbacks.
- Keep the island open while popup menus track outside its bounds; recheck actual pointer position after tracking-area resize events.
- Add a Home widget chooser and a scrollable widget column; correct failed AI task icons.
- Add an isolated native UI host and XCUITest coverage for tabs, widget choice, game selection, quiet screenshots, and offline recovery.

- Upgrade sports to an ESPN-style Gamecast with the complete available play feed, quarter/overtime and scoring filters, richer NBA player/scoring context, and football down-and-distance/field position/yardage.
- Add expandable football drives, quarter scores, team stats, game leaders and an ESPN Gamecast link.
- Grow the Sports panel, preserve a reading position, and poll live detail every 10 seconds independently of the slate. Show update age and keep rich data during connection failures.
- Add recorded NBA/NFL/CFB full-game regressions and native UI flows for quarter/scoring filters, stats and drives.
