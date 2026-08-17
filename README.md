# Codex Export

Codex Export is a native macOS menu-bar companion that turns selected Codex
conversation text into one clean PNG. It runs independently from Codex, stays
out of the Dock, and keeps conversation processing on your Mac.

[Download the latest release](https://github.com/Flash-LHR/codex-export/releases/latest)

## Highlights

- Browse and search your local Codex tasks
- Select individual messages, a Shift-click range, or the full conversation
- Start with the latest question-and-answer turn selected automatically
- Render Markdown, tables, inline code, and offline KaTeX formulas accurately
- Copy the result to the clipboard or save it to `~/Downloads/Codex Exports`
- Export even very long selections as one fixed-width 1080px PNG
- Launch quietly at login and update automatically in the background

Only user text and completed final Codex answers are exported. Images,
attachments, tool calls, reasoning, commentary, system messages, and task
metadata are excluded.

## Requirements

- macOS 13 or later
- Apple Silicon Mac
- The Codex/ChatGPT desktop app, or a local `codex` executable

## Install

1. Open the [latest Release](https://github.com/Flash-LHR/codex-export/releases/latest)
   and download `Codex-Export-<version>.zip` — not the Source archive.
2. Unzip it and move `Codex Export.app` into `/Applications`.
3. On the first launch, Control-click the app and choose **Open**. If macOS
   still blocks it, allow it once in **System Settings → Privacy & Security**.

The current build is not Apple-notarized, so macOS may require this one-time
confirmation for a newly downloaded installation.

## Use

1. Open Codex Export from Applications or click its paper-glider icon in the
   menu bar.
2. Choose a task. Search checks task titles first and then conversation text.
3. Select the messages you want. The newest user-and-assistant turn is selected
   by default; scroll upward to load older history.
4. Click **复制** to copy the PNG or **保存** to save it.

Choosing **全选** loads the remaining conversation history before selecting
everything. Ordinary exports do not wait for the entire task to load.

The footer also provides controls for refresh, launch at login, automatic
updates, GitHub, quit, save, and copy.

## Automatic updates

Automatic updates are enabled by default. Codex Export checks the latest stable
GitHub Release in the background and installs a newer authenticated build when
the popover is closed and no export is running. It keeps the previous app until
the new version launches successfully and restores the previous version if
validation or launch fails.

The Update button communicates its state:

- **Green:** automatic updates are enabled and the app is current
- **Yellow:** a newer version is available, whether automatic installation is
  enabled or not
- **Gray:** automatic installation is off, the update feed is unavailable, or
  the current version has not yet been confirmed

Clicking the Update button toggles automatic installation. Checks continue at a
low frequency while installation is off, so the button can still turn yellow
when a new version appears.

## Privacy

Codex Export has no analytics and does not log or upload conversation text.
Conversation history is requested only from the local Codex App Server.
Markdown, tables, and formulas are rendered from resources bundled with the
app; remote images, fonts, scripts, and styles are not loaded.

For update checks, the app contacts only the configured public GitHub Release
feed. Those requests contain no conversation content.

## Troubleshooting

- **macOS says the app cannot be opened:** Control-click the app, choose
  **Open**, or approve it in **Privacy & Security**.
- **No tasks appear:** make sure Codex/ChatGPT is installed or the `codex`
  executable is available, then click **刷新**.
- **The menu-bar icon is missing:** launch Codex Export again from Applications.
- **An update is not installing yet:** close the popover and let any active
  image export finish.

For bugs and feature requests, use
[GitHub Issues](https://github.com/Flash-LHR/codex-export/issues).

## License

Codex Export is MIT licensed. Bundled renderer dependencies retain their own
licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
