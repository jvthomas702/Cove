# Cove guide

Everything Cove does, in more detail than the [README](../README.md).

## Matte appearance

Cove uses a consistent **black theme** across the island, AI workspace, Settings and image editor, including when macOS uses Light appearance. Older white-theme preferences fall back to black. Home keeps music, sports, activity and AI setup side by side; on smaller displays the tile row scrolls horizontally. Click **Play-by-play →** to open Gamecast with plays, drives, stats and followed games. **Devices** opens Sound, Displays, Wi-Fi and AirDrop settings. **Connect AI**, available on every tab, opens the connection screen for Claude Code, Codex, ChatGPT desktop and browser chats. The AI tile shows observed task status, including work that needs your attention.

The island is near-black and square along the top, flush with the screen edge like the notch it grows from; only its bottom corners curve (on a display without a notch it floats as a rounded pill). The Home music tile is liquid glass: the album art, blurred, glows through a frosted pane whose color drifts while music plays, with round glass controls and a solid white play button. Buttons everywhere default to the matching **Glass** look; **Settings → General → Buttons** still offers Outline, Glow and Tinted.

Everything moves on springs, like the iPhone's Dynamic Island: the island stretches open with a little give, its content comes into focus out of a soft blur, lists and tiles build in one row after another, tabs slide toward the one you picked, and scores, timers and battery levels roll to their new numbers. Turn on **Reduce motion** in System Settings → Accessibility → Display and Cove switches to short cross-fades.

## Simple navigation

The labeled **Home**, **AI**, **Calendar**, **Sports** and **Files** tabs open their views directly. The island remembers your selected tab when you close it. **Settings → General → Home widget** chooses Calendar, Music, Focus or Sports for the dashboard; Calendar and Focus put their content in the context tile. Team logos and provider colors identify teams; blue marks active controls and live status.

Open the **Sports** tab and choose **NBA**, **NFL** or **College football**: every game shows as a score card, grouped Live, Upcoming and Final, in each team's colors. Click a game. This pins its score to the notch and its latest play to Home. When the game ends it unpins itself (or, with a favorite team playing later, moves on to that game); a game you pin after it's over stays until you pick another, so you can read its plays. The Sports tab shows all returned plays, newest first, with game clock, quarter filters, drives and game stats. Selected games and leagues survive a restart.

College football shows games with at least one **Top 25** team by default; turn off **Top 25** to browse all FBS games. NBA shows the day's slate, while NFL and college football show the current week's slate. Live selected games refresh about every 10 seconds; other states and followed scoreboards refresh every minute. ESPN provides the data, so coverage and delays vary. If a request fails, Cove keeps the last data and indicates that updates have paused. These public feed endpoints are not a documented API contract and may change.

## AI work from apps and browser tabs

Open the **AI** tab. Live AI work can temporarily replace a sports score beside the notch, then return to it when the work finishes; turn this off with **Show live AI work beside the notch**. The AI workspace shows a large Nori beside the selected session, observed phases down the left, live detail in the main card, and colored agent pills on the right. Click a pill to inspect that session; Open returns to its app or terminal. Clicking an AI activity in the matte dashboard opens this workspace. Phase history stays in memory, is bounded to 24 phases per session, and coalesces streaming reply updates. Only reported steps are shown. Turn off **Show Nori** to use agent glyphs instead.

Use the prompt box at the bottom of **AI** to start a new task. Choose **Codex**, **Claude Code** or **Claude (cloud)**, choose a project folder and type the request. **Claude (cloud)** runs `claude --cloud <task>` in that folder, which starts a session on claude.ai for the folder's GitHub repo (push first: the cloud clones GitHub, not your checkout). **Start** opens that installed agent’s interactive session in Terminal, preserving its login, project context and approval controls. Connected hooks report activity back to Cove. Drafts stay in memory while you switch tabs. This starts a new session; it does not send a message into an existing tracked chat. Codex follows the [official interactive CLI workflow](https://learn.chatgpt.com/docs/codex/cli).

- **ChatGPT desktop app:** turn on **Settings → Connections → ChatGPT desktop → Follow ChatGPT**, and grant Cove **Accessibility** in Permissions. Keep the chat window open. Cove reads only window titles and generation/composer button metadata; it does not read the app’s chat database, text-field contents, screenshots or hidden reasoning. Two consistent observations are required to start or finish work. If controls cannot be read, Cove reports that status rather than claiming a reply finished. Desktop tracking is a best-effort observer of visible windows; it cannot follow chats whose generation controls are not exposed, and UI updates may change those controls. Desktop completion opens the app to read the response rather than copying its contents.
- **Browser tabs:** use **Settings → Connections → Browser chat tabs → Set up** to install the bundled Cove extension in Chrome, Arc, Brave or Edge. After a Cove update, reload the unpacked extension and refresh already-open chat tabs. The extension reports ChatGPT, Claude and Gemini generation status, live visible reply excerpts and completion. Turn off **Include reply previews** in its popup to send status and character counts instead. These events go only to Cove’s loopback server. A reply you watched finish stays in the widget quietly; the popup’s notification toggle controls whether it also shows a banner.
- **Claude Code and Codex:** existing hooks/notify integration continues to appear in the same AI widget.

## Classes from D2L and Google Calendar

Paste each calendar's private link into **Settings → Classes → Calendar links**. Cove downloads them every 15 minutes; nothing needs setting up in the Calendar app.

- **D2L**: open **Calendar** in D2L, click **Subscribe** (under the calendar list), choose **All Courses** and copy the link.
- **Google Calendar**: open [Google Calendar settings](https://calendar.google.com/calendar/r/settings), click your calendar on the left, scroll to **Integrate calendar** and copy **Secret address in iCal format**. Repeat for each calendar you want.

Timed sessions show as classes; assignments and "Availability Ends" items from D2L or Canvas go in **Due soon**. These links are private (anyone with one can read the calendar), so Cove leaves them out of diagnostics.

Calendars already in the Mac's Calendar app (Google added under System Settings → Internet Accounts, iCloud, Exchange) are read too, if you allow calendar access.

## Talk to Claude with fn

Hold **fn** (🌐), say what you want, and let go. The island shows your words as you speak, then Claude's answer as it's written. Ask a question ("what's in my Downloads from today?", "explain this error") or give it a task ("rename the screenshots on my Desktop by date"). Hold fn again within five minutes to follow up in the same conversation. Esc while you're talking cancels, and a quick tap of fn does nothing, so fn+arrow and the other fn shortcuts keep working.

Cove runs Claude Code for you (`claude -p`, signed in with your account, so run `claude auth login` once) in the folder chosen in **Settings → AI agents → Talk to Claude**, your home folder unless you pick another. By default Claude can read files and answer but not change anything; when it needed to, **Continue in Terminal** opens the same conversation in Terminal with Claude's usual permission prompts. Turn on **Let Claude make changes** to let it edit files without asking. **Read answers aloud** speaks the reply.

The first time, macOS asks for the microphone and speech recognition; recognition runs on your Mac when your Mac supports it. Seeing fn while you're in other apps needs **Accessibility** (Settings → Permissions). Set System Settings → Keyboard → **Press 🌐 key to** → Do Nothing, so macOS doesn't open dictation or the emoji picker at the same time.

## Claude in the cloud

Sessions on claude.ai/code, in Claude projects and in routines run on Anthropic's machines, so Cove's hooks never hear from them. What does reach your Mac is GitHub: those sessions open pull requests that link back to the session. Cove watches for them and shows each one as a Claude activity: when it opens, while CI runs, when CI fails or passes, when it's ready for review and when it merges. Clicking it opens the session or project thread.

It signs in with the GitHub CLI (`brew install gh`, then `gh auth login`) and watches the repos you pushed to in the last two days, or the ones you list as `cloudRepos` in `~/.config/cove/config.json`. Turn it off in Settings → Connections. Cloud work that never opens a pull request (a question, a document) doesn't show up.

### Talking to a cloud session

Pick **Cloud** in the AI tab's composer to send a cloud session a follow-up. Sessions whose pull requests Cove has seen are listed already; add any other with the link button and a claude.ai/code link (or a bare `session_…` id). **Message** on a cloud activity in the AI tab picks its session for you. **Send** runs `claude -p --cloud <session> --output-format json` with your message on stdin. The message waits in the session until Claude reads it; Claude's reply shows on claude.ai and in the Claude app, and any new commits show up here through the pull request. The open button takes you to the session.

This needs Claude Code signed in to your claude.ai account (`claude auth login`) and your organization's cloud sessions turned on. Cove stores no token: it keeps the session list and your last few sent messages on this Mac. If the send fails (an archived session, a disabled policy), the composer says why and keeps your draft.

## Your agents on your phone

Turn on **Your phone** in Settings → Connections. Cove makes a private topic on [ntfy](https://ntfy.sh), a free push service, and shows it with a QR code. Install the free ntfy app on your phone (iOS or Android), tap +, and subscribe to that topic; or scan the code to open it in the phone's browser. No account, no server to run, and it works anywhere your phone has signal.

Your phone then buzzes when an agent needs you, when one finishes or fails, and when Claude asks permission. Every ping has a **Refresh** button that answers with the list of agents running right now and the last few that finished. By default it only buzzes while you're away from the Mac (screen locked, or no typing for `approvalIdleMinutes`).

Turn on **Answer Claude's permission prompts from the phone** to get Allow and Deny buttons. While you're away, permission prompts then wait for your phone (up to `approvalTimeout`) instead of going to a terminal nobody is looking at.

Pings travel through ntfy.sh in plain text, and anyone who knows the topic can read them and press the buttons, so treat the topic like a password (**New topic** replaces it). To keep them private, run your own ntfy server and set `phoneServer` (and `phoneToken` if it needs sign-in) in `~/.config/cove/config.json`. The Mac has to be awake for answers to reach it.

## External displays

Settings → General → **Show on** picks where the island lives. **Notch display** (the default) keeps it on the MacBook's notch and moves it to the main display when the lid is closed or no notch is connected. **Active display** follows the pointer: move to another screen and the island goes with it (an open island waits until it closes). On a display without a notch the island is a floating pill just below the top edge, the same size as on the notch. Plugging in, unplugging or rearranging displays re-places it automatically.

## GitHub Actions

Turn on **Settings → Connections → Watch my CI runs** to see your workflow runs live in the notch. It signs in with the GitHub CLI (`gh auth login`); Cove stores no token. On Home's activity tile, a failed run has a blue **Re-run** pill (re-runs just the failed jobs, or the whole run if none can be retried). A passed run shows **Run <name>** when the repo has a workflow with a `workflow_dispatch` trigger whose name or file mentions "deploy" or "release"; it starts that workflow on the run's branch. Progress and the result appear in place of the button. GitHub needs the token's `repo` scope for this (and `workflow` for some repos): if it says no, run `gh auth refresh -s repo,workflow`. Turn the buttons off with **Re-run and deploy buttons**.

## Dropping files on the notch

Drag any file onto the notch, open or closed. It opens with two targets: drop on **AirDrop** to pick a nearby device in the AirDrop window, or on **Keep** to put the file on the shelf. Dropping anywhere else on the island keeps it. Turn the targets off in Settings → Shelf → **AirDrop drop zone** to go back to dropping straight onto the shelf.

## Browsing and converting files

The **Files** tab has two views: **Shelf** and **Browse**. Browse shows the files on your Mac: Home, Desktop, Documents, Downloads, iCloud Drive and Applications on the left, the folder's contents on the right, a path bar to go back up, and **⋯** to sort by date, show hidden files or open the folder in Finder. Double-click a folder to go in and a file to open it in its default app. Click to select, ⌘- or ⇧-click to select more, and drag any row into another app. Type in **Search files** to filter the folder; two letters or more also search your home folder with Spotlight. Right-click a file to show it in Finder, keep it on the shelf, copy it or its path.

**Convert** (in the selection bar, on a file's right-click menu, or **Convert all** on the shelf) turns:

- images (JPEG, PNG, HEIC, TIFF…) into one PDF, a page per image in the order they're listed, upright even for phone photos;
- images and PDFs together into one combined PDF;
- an image into JPEG, PNG, HEIC or TIFF (transparent areas turn white in JPEG);
- each page of a PDF into a PNG or JPEG.

The result is saved next to the original with a new name, so nothing is overwritten (files kept inside Cove's own storage, like shelf screenshots, go to Downloads instead). It also lands on the shelf, and the banner opens it. Everything happens on your Mac.

## Quick timers

Click the **timer** button at the left of the island's header. Home's second tile turns into the timer: tap **5 min**, **10 min** or **25 min**, or type a length and press Return. Plain numbers are minutes (`3`), and `90s`, `1h 15m`, `1.5h` and `1:15:00` work too. A clock time such as `12:30`, `9:05pm` or `7pm` counts down to the next time it comes round. While it runs, the time left (`12:34`) and a thin blue ring show beside the notch, and Home has **Pause** and **Cancel**. At zero a banner drops down with Nori celebrating and the Glass chime (if sounds are on). One timer runs at a time; starting another replaces it. The end time is saved, so a timer keeps going across a restart, and one that ran out while Cove was closed rings when it opens. Choosing **Focus** as the Home widget keeps the timer tile on Home. Turn the feature off with **Settings → General → Quick timers**.

## Screenshots

New screenshots go to the shelf as soon as macOS saves them. macOS's floating thumbnail holds each screenshot for about 5 seconds first; turn on **Instant screenshots** in Settings → Shelf to skip it. Cove watches whatever folder your screenshots go to (⌘⇧5 → Options), and can move them off the Desktop into Pictures › Screenshots.

Captures arrive **quietly by default**, without a banner or tab switch. Enable **Show a banner for new screenshots** in Settings → Shelf if you want a thumbnail popup. Existing files, captures with missing creation dates, and captures renamed or moved after delivery do not create repeat popups. Folder permission status appears in Settings → Permissions.

## ESPN-style Gamecast

The Sports panel grows to give the full feed room. Plays keeps all plays returned by ESPN, rather than the newest 100; filter by quarter/overtime or scoring and use Latest play to return to the top. Reading older plays keeps a scroll anchor while updates arrive. NBA plays show scoring values and participant names resolved from the game roster. Football shows down-and-distance, field position, yardage, penalties/turnovers, and expandable drive summaries. Stats includes quarter scores, team comparisons and game leaders. ESPN ↗ opens the complete Gamecast.

Live detail checks every 10 seconds, independently of the slower scoreboard refresh. The timestamp and paused/delayed state describe feed freshness; provider data can still lag. Failed requests retain the last successful plays, drives and stats. These are public, undocumented ESPN JSON feeds, so no claim is made of official push updates or guaranteed coverage.

## Favorites, multi-game scores and pinning

In **Settings → Sports → Favorite teams**, search NBA, NFL and FBS teams and click their stars. Auto-follow selects a live favorite when no active game is selected, then an upcoming favorite; it respects an active game you selected manually. Favorite college teams stay visible with Top 25 enabled. Use **Follow game** in the game chooser to add individual matchups. The compact score strip switches between followed games across leagues. Start and score alerts are optional and off initially.

Click the closed island or a tab to keep it open while you work. Hover opens it temporarily with a short delay; leaving gives you 0.65 seconds to return. Native menus keep the island open while you use them. Unpin restores hover behavior; the close button closes and unpins it. Tab controls stay beside the physical notch when the panel changes width. The island uses a damped spring for resizing and a short fade for content changes; Reduce Motion removes the spring.

## Screenshot preview, annotation and undo

Double-click a shelf image to preview it in Cove. Rename changes only the saved shelf copy. Pen and text annotations save as a new PNG at the original pixel dimensions; Copy includes the annotated result. Undo mark reverses the last annotation. The shelf's Undo restores the last removal or Clear, including after restarting Cove. Originals remain in their original screenshot folder. The most recent removed copies stay in the shelf's internal Trash until restored or replaced by another removal.

## AI task overview

Open the **AI** tab to see the selected reply alongside an overview of tracked app and browser work. Use the All, Live or Done buttons, choose a task, and jump back to its app or tab. The selected task and its details always follow the active filter. Empty filters offer Show all tasks. Completed tasks stay for ten minutes. Browser setup and desktop Accessibility requirements still apply; reply previews remain a browser-extension preference.

## App updates

Packaged Cove embeds Sparkle, with daily checks and automatic installation enabled by default for new installations. Signed downloads and the feed live in the [Cove-updates repository](https://github.com/jvthomas702/Cove-updates). Check manually from Cove's menu or **Settings → About**. Signed archives and the signed feed must validate before installation. See [signed-update publishing](docs/UPDATES.md) for release setup. Existing updater-enabled installations update in place; use Check for Updates instead of downloading another app. Versions predating the updater require one initial replacement.

## Live Codex activity

Codex's legacy completion notifier does not report ongoing work. For start, tool progress, approval waits and completion, use the [live lifecycle connection](docs/CODEX-LIVE.md). Preview it with `python3 scripts/connect-codex-live.py`, then install with `--install` and review/trust the new definitions through Codex `/hooks`. It sends only coarse activity metadata to local Cove and preserves existing hooks. It doesn't need Accessibility.

## Reply from the banner

A finished Claude Code session's done banner shows a **Reply…** field with a blue send button. Sending opens Terminal in the session's folder and runs `claude --resume <session> -- "<your reply>"`, so the conversation continues interactively with its normal permissions. Codex CLI completions (the notify hook, which reports a thread id) get `codex resume` the same way; Codex desktop chats don't show the field. The banner waits while the pointer is on it or you're typing. Turn it off in **Settings → AI agents → Reply from banners**.

## Today's agent recap

The **AI** tab shows a **Today** list under the selected task once a Claude Code or Codex run finishes: the project (or chat) name, the agent, how long it ran, how many files it changed, when it finished, and a green check or red cross. Files changed counts distinct files touched by Claude Code's Edit, Write and MultiEdit tools, as seen by Cove's PreToolUse hook (so an edit you then deny still counts); Codex doesn't report tool use, so its rows have no file count. Click a row to jump back to the terminal or app it ran in, just like its banner. The list survives restarts and starts over at midnight; it's saved as `AgentRecap.json` in Cove's Application Support folder. Turn it off in **Settings → AI agents → Today's agent recap**.
