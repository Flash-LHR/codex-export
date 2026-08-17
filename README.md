# Codex Export

Codex Export is a small native macOS menu-bar companion for exporting selected Codex conversation text as one PNG. It runs as an accessory application, so it does not show a Dock icon or replace the normal Codex launch flow.

## What it does

- Lists local Codex tasks through the Codex App Server
- Opens the newest task by default, then uses a fixed-height history browser
  instead of an ever-growing menu
- Browses older active tasks with cursor pagination; search shows visible-title
  matches first, then adds conversation-text matches below them
- Includes only user text and completed final Codex answers
- Selects the latest question-and-answer turn by default
- Shows the newest turn first, then silently fills in the latest five turns
- Opens the message list at the bottom and keeps the newest turn visible while
  that recent-history window is filled; manual scrolling releases the pin
- Supports individual selection, Shift range selection, and Select All
- Renders GitHub-flavored Markdown with real grid tables and offline KaTeX
  typesetting for inline and display formulas
- Copies or saves a fixed-width 1080px image only after the user clicks the corresponding action
- Always produces one PNG, including ultra-tall selections
- Checks a configured public GitHub Release feed in the background and can
  install authenticated stable updates automatically while the app is idle
- Keeps all conversation processing local
- Uses one compact bottom action bar for refresh, launch-at-login, automatic
  updates, GitHub, quit, save, and copy

Images, attachments, tool calls, reasoning, commentary, system messages, and task metadata are not included in the exported image.

Markdown and formulas are rendered entirely from resources bundled with the
app. Message HTML is disabled, and the renderer does not load remote images,
fonts, scripts, or styles.

Formula delimiters include `$...$`, `$$...$$`, `\\(...\\)`, and
`\\[...\\]`. GFM table alignment, wrapped cells, inline formatting, and
literal pipes inside inline code are preserved.

Opening a task paints its newest turn first, then fills in up to four more
recent turns in the background. When you scroll upward, the app uses the
viewport size and actual scroll speed to fetch the next small page roughly two
to four screens before the loaded history runs out. One near-top request is
remembered while another page is still loading, so a fast wheel or trackpad
gesture is not lost. Choosing
**全选** explicitly reads the remaining history before it selects everything,
so ordinary one-turn exports never wait for the full task.
Reopening the menu refreshes a lightweight recent-task index and defaults to
the newest task. Clicking the task field switches the same popover into a
single-layer task browser: search and a fixed-height result list replace the
conversation controls instead of opening a nested dialog. Archived tasks are
excluded. Result rows show only task titles. A query first filters the lightweight
local task-title index using the same sanitized titles shown in the interface,
then adds full-text conversation matches below the title matches without
exposing the matching prompt in the list. Duplicate results appear only once.
While the search field is editing, both Command-A and Control-A select all text.
Scrolling down fetches older task summaries or the next page of content
matches. Cached messages remain immediately usable when the newest task is
unchanged. Reopening the popover automatically refreshes the recent task index;
if that refresh fails, the error state offers an explicit retry without blocking
an already loaded selection.

The renderer keeps the original typography and layout. It first asks WebKit for
a compact vector PDF representation, then rasterizes that representation in
2,048-row bands and streams the rows into one PNG. No full-height bitmap is ever
allocated, and internal PDF pages are joined without visible seams. The current
single-image height limit is 200,000px, matching macOS image-viewer compatibility.

## Requirements

- macOS 13 or later
- Apple Silicon
- Codex/ChatGPT desktop app or a local `codex` executable

## Install and use

1. Move `Codex Export.app` into `/Applications`.
2. Because the local development build is ad-hoc signed rather than notarized,
   first launch it with **Control-click → Open**. If macOS still blocks it, allow
   it once in **System Settings → Privacy & Security**.
3. Continue launching Codex normally. Codex Export runs independently as a
   menu-bar utility and never replaces the Codex launcher. Opening Codex Export
   explicitly shows its panel; login launch remains quiet in the menu bar.
4. Choose a task, select the messages to include, then click **复制** or
   **保存**. Saved PNG images go to `~/Downloads/Codex Exports`.

The newest turn is selected and shown at the bottom, then Codex Export silently
fills in the most recent five turns without jumping to the top. Once you scroll
manually, the list stops pinning itself so your reading position is preserved.
Older visible messages remain available for manual selection; continue
scrolling upward to load earlier history automatically.

## Package layout

- `CodexExportCore`: App Server client/transport, transcript normalization, and the
  single offline PNG-rendering pipeline
- `CodexExportFeature`: export state, task/message selection, and popover UI;
  system effects enter through injected protocols
- `CodexExportApp`: the small AppKit composition root plus macOS adapters for
  the menu bar, login item, clipboard, Downloads, and application lifecycle
- `Resources/Info.plist`: application-bundle metadata, including `LSUIElement`
- `VERSION`: the single source for the app version and build number
- `scripts/build-app.sh`: release build and local `.app` packaging
- `scripts/package-release.sh`: allowlisted binary/source release packaging
- `.github/workflows/release.yml`: tag-driven tests, packaging, manifest
  signing, and GitHub Release publication

## Development

Building from source requires Xcode Command Line Tools with Swift 5.9 or later.

Inspect the package manifest:

```sh
swift package dump-package
```

Once the application and core sources are present, build a runnable app bundle:

```sh
./scripts/build-app.sh
open "dist/Codex Export.app" --args --show-popover
```

The build script creates `dist/Codex Export.app` and applies an ad-hoc signature
for local development. Opening the app explicitly shows the panel; its menu-bar
icon remains available afterward. Saved images go to `~/Downloads/Codex Exports`.

Running `swift run CodexExportApp` from the repository root is also supported
for development; it reads the renderer from `Resources/WebRenderer`. Use
`CODEX_EXPORT_RENDERER_RESOURCES` to supply that directory from another working
directory. Create release folders and ZIP files with:

```sh
OUTPUT_ROOT=/path/to/output ./scripts/package-release.sh
```

The packaging script copies an explicit source allowlist, so `.build`, `dist`,
editor state, and other workspace artifacts cannot enter the source archive.

## Automatic updates

Automatic installation is enabled by default after a release build is
configured with a public GitHub repository and an Ed25519 public key. The app
checks five seconds after launch and then every six hours, even when automatic
installation is switched off, so the Update tile can still turn yellow when a
new version exists. The switch controls download, replacement, and restart. The
app accepts only the latest stable Release, authenticates the exact manifest
bytes with the embedded public key, checks the ZIP SHA-256 and bundle identity,
downloads in the background, and waits until the popover is closed and no image
export is active. A detached installer acknowledges readiness before the old app
exits, atomically swaps the bundles, and keeps the old bundle until the new app
reports a healthy launch. Failed launch or validation swaps the old version back
and reopens it.

Generate an update signing key once:

```sh
swift scripts/generate-update-key.swift
```

Store `CODEX_EXPORT_UPDATE_PRIVATE_KEY` as a GitHub Actions secret and
`CODEX_EXPORT_UPDATE_PUBLIC_KEY` as a repository Actions variable. Never commit
the private key. A configured release build also requires:

```sh
export CODEX_EXPORT_UPDATE_REPOSITORY=Flash-LHR/codex-export
export CODEX_EXPORT_UPDATE_PUBLIC_KEY=...base64-public-key...
```

Creating signed update assets with `package-release.sh` additionally requires:

```sh
export CODEX_EXPORT_UPDATE_PRIVATE_KEY=...base64-private-key...
```

Pushing a tag that exactly matches `v$(MARKETING_VERSION)` runs the release
workflow. It publishes the binary/source ZIP files plus the signed
`Codex-Export-update.json` and `Codex-Export-update.sig` assets. Local builds
without this configuration remain runnable, but the Update and GitHub controls
are disabled rather than contacting an unknown repository.

The current release workflow intentionally follows the Codex Radar-style
ad-hoc signing model because no Apple Developer ID is configured. The signed
Ed25519 manifest authenticates update bytes, but the app is not Apple-notarized;
users may need the one-time Control-click → Open step described above.

## Privacy

Codex Export has no analytics and does not log conversation text. Conversation
history is requested only from the local Codex App Server. When updates are
configured, the app contacts the configured public GitHub repository to read
Release metadata. It downloads an authenticated update only while automatic
installation is enabled. No conversation content is included in those requests.

## License

The project source code is MIT licensed. Bundled renderer dependencies retain
their own licenses; see `THIRD_PARTY_NOTICES.md`.

The application and menu-bar icons use an original folded-glider mark. The
committed assets are sufficient for normal builds. Maintainers can regenerate
them with `scripts/generate-app-icon.py` and
`scripts/generate-status-icons.py` after installing Pillow; the generators do
not read or modify any third-party application assets.
