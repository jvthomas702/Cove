# Cove

**A Dynamic Island for the MacBook notch, built for people who run AI agents, long jobs, and a full class schedule.**

Cove turns the space around the notch into a live surface. It tells you the moment Claude Code, Codex, ChatGPT or Claude finishes, lets you approve Claude Code's permission prompts without switching windows, counts down to your next class, catches every screenshot on a shelf you can drag from, and replaces the volume and brightness pop-ups. Nori, a small animated buddy, reacts to all of it.

Native Swift and SwiftUI, no dependencies, MIT licensed. Every commit is built, tested and run on a real Mac in CI, including screenshots of the live UI.

![Cove: the open island, a permission prompt, an agent banner, and compact states](docs/preview.png)

## What it does

| | |
|---|---|
| **Nori** | A small black buddy with glowing eyes that blends into the island and lights its rim in the status color. Naps beside the notch, reads along with your agents, hops with confetti when something finishes, waves an amber "!" when something needs you, and droops when something fails. |
| **Approve from the notch** | When Claude Code asks permission, the island drops down with exactly what it wants to do (the command, or a red and green diff) and **Allow**, **Always allow**, **Deny** and **Answer in terminal**. |
| **Agent pings** | Claude Code and Codex sessions show as live activities with what they're doing right now, then a banner with the final message. Click to jump back to the terminal. |
| **Reply from the banner** | When a Claude Code or Codex session finishes, its done banner has a small **Reply…** field. Send continues that same session in Terminal (`claude --resume` / `codex resume`), so you stay in control. |
| **AI work** | Follow ChatGPT desktop activity, ChatGPT/Claude/Gemini browser replies, Claude Code and Codex. Live status, elapsed time and browser reply previews appear in the AI tab. |
| **Classes and due dates** | "CPE 3000 Lecture, 50 min left" beside the notch, a heads-up before each class with a Join button for Zoom, Meet or Teams, and a Due soon list from your D2L or Canvas calendar and Reminders. |
| **Sports** | Choose an NBA, NFL or college football game to pin its score beside the notch and follow its latest plays. College football defaults to games featuring a Top 25 team. |
| **Screenshot shelf** | Every screenshot lands on the shelf the moment it's saved, with a thumbnail you can drag straight out of the notch into a doc, Slack or a chat. |
| **Long commands** | `cove-run python train.py` shows a live timer and pings you with how long it took. Scripts can push progress rings. |
| **External displays** | Docked with the lid closed? The island moves to your main display, or set **Show on → Active display** to have it follow the pointer from screen to screen. Displays without a notch get a floating black pill instead of a fake notch. |
| **Camera and mic dot** | A green dot beside the notch while any app has a camera on, orange while one is using a microphone, like the iPhone. No permissions needed; turn it off in Settings → Features. |
| **Charging** | Plug in and a green battery fills to your current level beside the notch with the percentage, then folds away, like the iPhone. Follows Reduce Motion; turn it off in Settings → Features. |
| **And** | Notifications from other apps, Now Playing with album-art colors, a focus timer, a file shelf, battery alerts, and the volume and brightness meter. |

## Install

### Download (easiest)

1. Download **Cove.zip** from the [latest release](../../releases/latest) and double-click it.
2. Drag **Cove.app** into **Applications** and open it.
3. macOS says it can't verify the developer, because Cove isn't notarized by Apple. Click **Done**, open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.

Cove updates itself from then on. Every release is signed with the same certificate, so the permissions you grant stay granted across updates.

### Build from source

```bash
git clone https://github.com/jvthomas702/Cove.git
cd Cove
./scripts/install.sh
```

Needs macOS 14 or later and Xcode or the Command Line Tools (`xcode-select --install`). The installer signs Cove with a local certificate it creates once (macOS may ask to let `codesign` use it: click **Always Allow**), so macOS remembers Cove's permissions when you update.

## Set up

Cove opens **Settings** on first launch and turns on **Open Cove when you log in**, so it's back after a restart (turn it off on the Permissions or General page). Everything is a click from there:

- **Permissions**: shows what's allowed. Turn on only what you want: Calendars and Reminders for classes and due dates, Accessibility for the volume and brightness keys, Desktop folder for screenshots, Full Disk Access for notifications from other apps.
- **Connections**: connects Claude Code (adds hooks to `~/.claude/settings.json`, with a backup), Codex, the browser extension, and installs the `cove-run` and `cove-notify` terminal tools.
- **Features**: approvals mode, countdown timing, instant screenshots, notifications to highlight, and more.

Open Settings any time from the menu bar icon, or by opening Cove.app again.

### Matte appearance

Cove uses a consistent **black theme** across the island, AI workspace, Settings and image editor, including when macOS uses Light appearance. Older white-theme preferences fall back to black. Home keeps music, sports, activity and AI setup side by side; on smaller displays the tile row scrolls horizontally. Click **Play-by-play →** to open Gamecast with plays, drives, stats and followed games. **Devices** opens Sound, Displays, Wi-Fi and AirDrop settings. **Connect AI**, available on every tab, opens the connection screen for Claude Code, Codex, ChatGPT desktop and browser chats. The AI tile shows observed task status, including work that needs your attention.

### Simple navigation

The labeled **Home**, **AI**, **Calendar**, **Sports** and **Files** tabs open their views directly. The island remembers your selected tab when you close it. **Settings → General → Home widget** chooses Calendar, Music, Focus or Sports for the dashboard; Calendar and Focus put their content in the context tile. Team logos and provider colors identify teams; blue marks active controls and live status.

Open the **Sports** tab, choose **NBA**, **NFL** or **College football**, then click a game. This pins its score to the notch and its latest play to Home. The Sports tab shows all returned plays, newest first, with game clock, quarter filters, drives and game stats. Selected games and leagues survive a restart.

College football shows games with at least one **Top 25** team by default; turn off **Top 25** to browse all FBS games. NBA shows the day's slate, while NFL and college football show the current week's slate. Live selected games refresh about every 10 seconds; other states and followed scoreboards refresh every minute. ESPN provides the data, so coverage and delays vary. If a request fails, Cove keeps the last data and indicates that updates have paused. These public feed endpoints are not a documented API contract and may change.

### AI work from apps and browser tabs

Open the **AI** tab. Live AI work can temporarily replace a sports score beside the notch, then return to it when the work finishes; turn this off with **Show live AI work beside the notch**. The AI workspace takes visual cues from [Coucou](https://github.com/Louis-CFM/coucou): a large Nori beside the selected session, observed phases down the left, live detail in the main card, and colored agent pills on the right. Click a pill to inspect that session; Open returns to its app or terminal. Clicking an AI activity in the matte dashboard opens this workspace. Nori is drawn with Cove’s own native shapes; no Coucou character assets or sounds are bundled. Phase history stays in memory, is bounded to 24 phases per session, and coalesces streaming reply updates. Only reported steps are shown. Turn off **Show Nori** to use agent glyphs instead.


Use the prompt box at the bottom of **AI** to start a new task. Choose **Codex** or **Claude Code**, choose a project folder and type the request. **Start** opens that installed agent’s interactive session in Terminal, preserving its login, project context and approval controls. Connected hooks report activity back to Cove. Drafts stay in memory while you switch tabs. This starts a new session; it does not send a message into an existing tracked chat. Codex follows the [official interactive CLI workflow](https://learn.chatgpt.com/docs/codex/cli).

- **ChatGPT desktop app:** turn on **Settings → Connections → ChatGPT desktop → Follow ChatGPT**, and grant Cove **Accessibility** in Permissions. Keep the chat window open. Cove reads only window titles and generation/composer button metadata; it does not read the app’s chat database, text-field contents, screenshots or hidden reasoning. Two consistent observations are required to start or finish work. If controls cannot be read, Cove reports that status rather than claiming a reply finished. Desktop tracking is a best-effort observer of visible windows; it cannot follow chats whose generation controls are not exposed, and UI updates may change those controls. Desktop completion opens the app to read the response rather than copying its contents.
- **Browser tabs:** use **Settings → Connections → Browser chat tabs → Set up** to install the bundled Cove extension in Chrome, Arc, Brave or Edge. After a Cove update, reload the unpacked extension and refresh already-open chat tabs. The extension reports ChatGPT, Claude and Gemini generation status, live visible reply excerpts and completion. Turn off **Include reply previews** in its popup to send status and character counts instead. These events go only to Cove’s loopback server. A reply you watched finish stays in the widget quietly; the popup’s notification toggle controls whether it also shows a banner.
- **Claude Code and Codex:** existing hooks/notify integration continues to appear in the same AI widget.

### Classes from D2L and Google Calendar

Paste each calendar's private link into **Settings → Features → Calendar links**. Cove downloads them every 15 minutes; nothing needs setting up in the Calendar app.

- **D2L**: open **Calendar** in D2L, click **Subscribe** (under the calendar list), choose **All Courses** and copy the link.
- **Google Calendar**: open [Google Calendar settings](https://calendar.google.com/calendar/r/settings), click your calendar on the left, scroll to **Integrate calendar** and copy **Secret address in iCal format**. Repeat for each calendar you want.

Timed sessions show as classes; assignments and "Availability Ends" items from D2L or Canvas go in **Due soon**. These links are private (anyone with one can read the calendar), so Cove leaves them out of diagnostics.

Calendars already in the Mac's Calendar app (Google added under System Settings → Internet Accounts, iCloud, Exchange) are read too, if you allow calendar access.

### Claude in the cloud

Sessions on claude.ai/code, in Claude projects and in routines run on Anthropic's machines, so Cove's hooks never hear from them. What does reach your Mac is GitHub: those sessions open pull requests that link back to the session. Cove watches for them and shows each one as a Claude activity: when it opens, while CI runs, when CI fails or passes, when it's ready for review and when it merges. Clicking it opens the session or project thread.

It signs in with the GitHub CLI (`brew install gh`, then `gh auth login`) and watches the repos you pushed to in the last two days, or the ones you list as `cloudRepos` in `~/.config/cove/config.json`. Turn it off in Settings → Connections. Cloud work that never opens a pull request (a question, a document) doesn't show up.

### Your agents on your phone

Turn on **Your phone** in Settings → Connections. Cove makes a private topic on [ntfy](https://ntfy.sh), a free push service, and shows it with a QR code. Install the free ntfy app on your phone (iOS or Android), tap +, and subscribe to that topic; or scan the code to open it in the phone's browser. No account, no server to run, and it works anywhere your phone has signal.

Your phone then buzzes when an agent needs you, when one finishes or fails, and when Claude asks permission. Every ping has a **Refresh** button that answers with the list of agents running right now and the last few that finished. By default it only buzzes while you're away from the Mac (screen locked, or no typing for `approvalIdleMinutes`).

Turn on **Answer Claude's permission prompts from the phone** to get Allow and Deny buttons. While you're away, permission prompts then wait for your phone (up to `approvalTimeout`) instead of going to a terminal nobody is looking at.

Pings travel through ntfy.sh in plain text, and anyone who knows the topic can read them and press the buttons, so treat the topic like a password (**New topic** replaces it). To keep them private, run your own ntfy server and set `phoneServer` (and `phoneToken` if it needs sign-in) in `~/.config/cove/config.json`. The Mac has to be awake for answers to reach it.

### External displays

Settings → General → **Show on** picks where the island lives. **Notch display** (the default) keeps it on the MacBook's notch and moves it to the main display when the lid is closed or no notch is connected. **Active display** follows the pointer: move to another screen and the island goes with it (an open island waits until it closes). On a display without a notch the island is a floating pill just below the top edge, the same size as on the notch. Plugging in, unplugging or rearranging displays re-places it automatically.

### Screenshots

New screenshots go to the shelf as soon as macOS saves them. macOS's floating thumbnail holds each screenshot for about 5 seconds first; turn on **Instant screenshots** in Settings → Features to skip it. Cove watches whatever folder your screenshots go to (⌘⇧5 → Options), and can move them off the Desktop into Pictures › Screenshots.

Captures arrive **quietly by default**, without a banner or tab switch. Enable **Show a banner for new screenshots** in Settings → Features if you want a thumbnail popup. Existing files, captures with missing creation dates, and captures renamed or moved after delivery do not create repeat popups. Folder permission status appears in Settings → Permissions.

## Terminal and API

```bash
cove-run python train.py --epochs 50          # live timer, then a ping
cove-run --name "Swarm sim" -- ros2 launch swarm sim.launch.py
cove-notify "Coffee's ready"
cove-notify --kind attention "Robot 3 lost localization" "Battery at 12%"
cove-notify --id sweep --kind running --progress 0.4 "HDC sweep" "dim=10000, 4/10"
```

From Python, `examples/cove_progress.py` pushes a progress ring with one line per epoch.

Cove listens on `127.0.0.1:7777` (this Mac only). It accepts requests from local programs and browser extensions, and refuses requests from web pages, so a site you visit can't post to your notch.

| Method | Path | Body |
|---|---|---|
| `GET` | `/health` | |
| `POST` | `/event` | `{"title": "…", "body": "…", "kind": "info", "id": "…", "progress": 0.4, "source": "command", "sticky": false}` |
| `POST` | `/hook/claude` | Claude Code hook JSON |
| `POST` | `/hook/claude/permission` | PermissionRequest JSON, held open until you decide |
| `POST` | `/hook/codex` | Codex notify JSON |

`kind` is `info`, `running`, `done`, `error`, `attention` or `clear`. Events with the same `id` update one live activity.

## How it's built

```
Sources/Cove/
├── AppDelegate.swift            lifecycle, menu bar, routing, applying settings
├── IslandModel.swift            all island state: activities, banners, approvals, calendar, shelf
├── NotchWindow.swift            borderless panel above the menu bar, sized to the island
├── Views/                       island shape and states, Nori, settings window, design tokens
└── Services/
    ├── EventServer.swift        HTTP server on 127.0.0.1 (Network.framework)
    ├── AgentBridge.swift        Claude Code hooks, permission prompts, Codex
    ├── CloudSessions.swift      pull requests from Claude cloud sessions, via GitHub
    ├── PhoneRelay.swift         agent pings to your phone and answers back, via ntfy
    ├── Integrations.swift       permissions, hooks, CLI tools, browser extension setup
    ├── CalendarMonitor.swift    EventKit classes and reminders
    ├── ICSFeeds.swift           calendar links (D2L, Canvas, Google iCal): download and parse
    ├── ScreenshotWatcher.swift  FSEvents on the screenshot folder, plus Spotlight
    ├── NotificationMirror.swift Notification Center's database (read only)
    ├── NowPlayingMonitor.swift  Music and Spotify
    ├── SystemControls.swift     volume, brightness, media keys
    ├── MediaUseMonitor.swift    camera and microphone in use (privacy dot)
    └── BatteryMonitor.swift     power source changes
extension/                       browser extension (Manifest V3)
bin/                             cove-run, cove-notify and hook scripts (bundled into the app)
Tests/                           unit tests (swift test)
```

CI (`.github/workflows/build.yml`) builds, runs the tests, packages and verifies the app, launches it with a debug-only API to walk through every state, checks the server's security rules and the screenshot pipeline end to end, measures idle CPU, and takes screenshots of the real UI. Tagging `vX.Y.Z` publishes a release.

## Known limitations

- Notification mirroring reads Notification Center's private database and may need an update after a major macOS release. Everything else keeps working if it breaks.
- Brightness control uses a private framework and only covers the built-in display.
- Now Playing covers Music and Spotify, not audio in browser tabs.
- The browser extension doesn't support Safari.

## License

MIT © 2026 Jason Thomas

### Native UI testing

Run `./scripts/ui-test-host.sh` to open an isolated native test app with the production Cove views and recorded sports feeds. It uses its own preferences and starts no screenshot watcher, calendar, notification reader, or desktop AI monitor. Use each labeled tab, Connect AI, the Devices menu, game selection, the Offline control, and Quiet screenshot to check visible behavior. The fixture summary adapts to the selected fixture team pair; these are repeatable scenarios, not current game data.

With full Xcode installed, run:

```sh
UI_PROJECT="$(python3 scripts/ui-test-xcode.py)"
xcodebuild test -project "$UI_PROJECT" -scheme CoveUI -destination 'platform=macOS' -resultBundlePath ui-tests.xcresult
```

CI runs these XCUITest flows and publishes the result bundle with failure screenshots. Team logos load from provider metadata, use fixed dimensions and a memory cache, and fall back to abbreviations when unavailable. Native popup menu tracking keeps the island open while choosing outside its bounds.

### ESPN-style Gamecast

The Sports panel grows to give the full feed room. Plays keeps all plays returned by ESPN, rather than the newest 100; filter by quarter/overtime or scoring and use Latest play to return to the top. Reading older plays keeps a scroll anchor while updates arrive. NBA plays show scoring values and participant names resolved from the game roster. Football shows down-and-distance, field position, yardage, penalties/turnovers, and expandable drive summaries. Stats includes quarter scores, team comparisons and game leaders. ESPN ↗ opens the complete Gamecast.

Live detail checks every 10 seconds, independently of the slower scoreboard refresh. The timestamp and paused/delayed state describe feed freshness; provider data can still lag. Failed requests retain the last successful plays, drives and stats. These are public, undocumented ESPN JSON feeds, so no claim is made of official push updates or guaranteed coverage.


### Favorites, multi-game scores and pinning

In **Settings → Features → Favorite teams**, search NBA, NFL and FBS teams and click their stars. Auto-follow selects a live favorite when no active game is selected, then an upcoming favorite; it respects an active game you selected manually. Favorite college teams stay visible with Top 25 enabled. Use **Follow game** in the game chooser to add individual matchups. The compact score strip switches between followed games across leagues. Start and score alerts are optional and off initially.

Click the closed island or a tab to keep it open while you work. Hover opens it temporarily with a short delay; leaving gives you 0.65 seconds to return. Native menus keep the island open while you use them. Unpin restores hover behavior; the close button closes and unpins it. Tab controls stay beside the physical notch when the panel changes width. The island uses a damped spring for resizing and a short fade for content changes; Reduce Motion removes the spring.

### Screenshot preview, annotation and undo

Double-click a shelf image to preview it in Cove. Rename changes only the saved shelf copy. Pen and text annotations save as a new PNG at the original pixel dimensions; Copy includes the annotated result. Undo mark reverses the last annotation. The shelf's Undo restores the last removal or Clear, including after restarting Cove. Originals remain in their original screenshot folder. The most recent removed copies stay in the shelf's internal Trash until restored or replaced by another removal.

### AI task overview

Open the **AI** tab to see the selected reply alongside an overview of tracked app and browser work. Use the All, Live or Done buttons, choose a task, and jump back to its app or tab. The selected task and its details always follow the active filter. Empty filters offer Show all tasks. Completed tasks stay for ten minutes. Browser setup and desktop Accessibility requirements still apply; reply previews remain a browser-extension preference.

### App updates

Packaged Cove embeds Sparkle, with daily checks and automatic installation enabled by default for new installations. Signed downloads and the feed live in the [Cove-updates repository](https://github.com/jvthomas702/Cove-updates). Check manually from Cove's menu or **Settings → About**. Signed archives and the signed feed must validate before installation. See [signed-update publishing](docs/UPDATES.md) for release setup. Existing updater-enabled installations update in place; use Check for Updates instead of downloading another app. Versions predating the updater require one initial replacement.

### Live Codex activity

Codex's legacy completion notifier does not report ongoing work. For start, tool progress, approval waits and completion, use the [live lifecycle connection](docs/CODEX-LIVE.md). Preview it with `python3 scripts/connect-codex-live.py`, then install with `--install` and review/trust the new definitions through Codex `/hooks`. It sends only coarse activity metadata to local Cove and preserves existing hooks. This connection works with the installed Cove 1.1 without replacing the app or requiring Accessibility.

### Reply from the banner

A finished Claude Code session's done banner shows a **Reply…** field with a blue send button. Sending opens Terminal in the session's folder and runs `claude --resume <session> -- "<your reply>"`, so the conversation continues interactively with its normal permissions. Codex CLI completions (the notify hook, which reports a thread id) get `codex resume` the same way; Codex desktop chats don't show the field. The banner waits while the pointer is on it or you're typing. Turn it off in **Settings → General → Reply from banners**.
