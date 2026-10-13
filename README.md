# Cove

**A Dynamic Island for the MacBook notch, built for people who run AI agents, long jobs, and a full class schedule.**

Cove turns the space around the notch into a live surface. It tells you the moment Claude Code, Codex, ChatGPT or Claude finishes, lets you approve Claude Code's permission prompts without switching windows, counts down to your next class, catches every screenshot on a shelf you can drag from, and replaces the volume and brightness pop-ups. Pip, a small animated buddy, reacts to all of it.

Native Swift and SwiftUI, no dependencies, MIT licensed. Every commit is built, tested and run on a real Mac in CI, including screenshots of the live UI.

![Cove: the open island, a permission prompt, an agent banner, and compact states](docs/preview.png)

## What it does

| | |
|---|---|
| **Pip** | Naps beside the notch, works along with your agents, hops with confetti when something finishes, waves an amber "!" when something needs you, and droops when something fails. |
| **Approve from the notch** | When Claude Code asks permission, the island drops down with exactly what it wants to do (the command, or a red and green diff) and **Allow**, **Always allow**, **Deny** and **Answer in terminal**. |
| **Agent pings** | Claude Code and Codex sessions show as live activities with what they're doing right now, then a banner with the final message. Click to jump back to the terminal. |
| **Browser chat tabs** | A small extension pings you when ChatGPT, Claude or Gemini finishes answering in a background tab (Chrome, Arc, Brave, Edge). |
| **Classes and due dates** | "CPE 3000 Lecture, 50 min left" beside the notch, a heads-up before each class with a Join button for Zoom, Meet or Teams, and a Due soon list from your D2L or Canvas calendar and Reminders. |
| **Screenshot shelf** | Every screenshot lands on the shelf the moment it's saved, with a thumbnail you can drag straight out of the notch into a doc, Slack or a chat. |
| **Long commands** | `cove-run python train.py` shows a live timer and pings you with how long it took. Scripts can push progress rings. |
| **And** | Notifications from other apps, Now Playing with album-art colors, a focus timer, a file shelf, battery alerts, and the volume and brightness meter. |

## Install

### Download (easiest)

1. Download **Cove.zip** from the [latest release](../../releases/latest) and double-click it.
2. Drag **Cove.app** into **Applications** and open it.
3. macOS says it can't verify the developer, because Cove isn't notarized by Apple. Click **Done**, open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.

### Build from source (keeps permissions across updates)

```bash
git clone https://github.com/jvthomas702/Cove.git
cd Cove
./scripts/install.sh
```

Needs macOS 14 or later and Xcode or the Command Line Tools (`xcode-select --install`). The installer signs Cove with a local certificate it creates once (macOS may ask to let `codesign` use it: click **Always Allow**), so macOS remembers Cove's permissions when you update.

## Set up

Cove opens **Settings** on first launch. Everything is a click from there:

- **Permissions**: shows what's allowed. Turn on only what you want: Calendars and Reminders for classes and due dates, Accessibility for the volume and brightness keys, Desktop folder for screenshots, Full Disk Access for notifications from other apps.
- **Connections**: connects Claude Code (adds hooks to `~/.claude/settings.json`, with a backup), Codex, the browser extension, and installs the `cove-run` and `cove-notify` terminal tools.
- **Features**: approvals mode, countdown timing, instant screenshots, notifications to highlight, and more.

Open Settings any time from the menu bar icon, or by opening Cove.app again.

### Classes from D2L and Google Calendar

Cove reads the Mac's Calendar app, so add both calendars there:

- **Google Calendar**: System Settings → Internet Accounts → Google, and turn on Calendars.
- **D2L assignments**: in D2L's Calendar, find **Subscribe** and copy the link. In the Calendar app choose **File → New Calendar Subscription**, paste it, name it `D2L`, and set auto-refresh to every 15 minutes. Calendars named D2L, Brightspace, Canvas or Gradescope are treated as due dates.

### Screenshots

New screenshots go to the shelf as soon as macOS saves them. macOS's floating thumbnail holds each screenshot for about 5 seconds first; turn on **Instant screenshots** in Settings → Features to skip it. Cove watches whatever folder your screenshots go to (⌘⇧5 → Options), and can move them off the Desktop into Pictures › Screenshots.

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
├── Views/                       island shape and states, Pip, settings window, design tokens
└── Services/
    ├── EventServer.swift        HTTP server on 127.0.0.1 (Network.framework)
    ├── AgentBridge.swift        Claude Code hooks, permission prompts, Codex
    ├── Integrations.swift       permissions, hooks, CLI tools, browser extension setup
    ├── CalendarMonitor.swift    EventKit classes and reminders
    ├── ScreenshotWatcher.swift  FSEvents on the screenshot folder, plus Spotlight
    ├── NotificationMirror.swift Notification Center's database (read only)
    ├── NowPlayingMonitor.swift  Music and Spotify
    ├── SystemControls.swift     volume, brightness, media keys
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
