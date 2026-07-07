# Craft Quick Capture

Native macOS menu bar app for capturing text and images into
[Craft](https://craft.do) documents. Lives in the menu bar; **⌥⌘Space** pops
up a small dark capture window, you type (or drop an image), pick a document,
hit ⌘↩, and it's in Craft.

No Electron, no dependencies — a single small Swift app that talks directly to
Craft's API.

## Setup

1. Build and install (needs only Xcode Command Line Tools):

   ```sh
   ./build.sh --install
   ```

2. On first launch the app asks for your **Craft MCP link** — a URL like
   `https://mcp.craft.do/links/…/mcp`. You create this in Craft's AI/Imagine
   settings for your space (it's the same link Craft gives you for connecting
   AI assistants). Treat it like a password: anyone with the link can read and
   write your Craft space. It's stored locally in
   `~/Library/Application Support/CraftQuickCapture/config.json` and never
   leaves your machine. Change it later via menu bar icon → Set Craft Connection…

3. Optional: menu bar icon → Launch at Login.

## Usage

### Ways to capture

| You want | Pick as destination | What happens |
|---|---|---|
| Text or an image on a page | Any **document** | Content is appended to the end of the page. Markdown renders: `# ` headings, `**bold**`, `- ` lists, blank line = new block. |
| A checkable task on a page | Any **document** | Start a line with `- [ ]` — it becomes a real Craft task block on that page. |
| A row in a table | A **collection** (table icon in the picker) | The popup becomes a form built from the table's schema — one field per column, dropdowns for single-select columns. ⌘↩ adds the row. Images can't go into table rows. |
| Something on today's daily note | **Today** (calendar icon, pinned at the top of the picker) | Appends to the calendar-integrated daily page. Typing `tomorrow` or `yesterday` finds those too. Combine with `- [ ]` for a task on today's agenda. |

Planned: capture straight to Craft's **Tasks inbox** with schedule/deadline dates
(the API supports it; the UI isn't built yet).

### Mechanics

- **⌥⌘Space** — toggle the capture popup (also available from the menu bar icon)
- Type text, and/or **drag an image** onto the window (or **⌘V** paste an image)
- Click the destination row to pick where it goes: recent destinations show
  first, typing searches every document title, folder name, and table in your
  space
- **↑/↓ + ↩** to pick a destination, **⌘↩** to save, **esc** to cancel
- The last-used destination stays selected for rapid repeat captures
- Hold ⌘ and drag the menu bar icon to reposition it (position persists)

## How it works

Plain JSON-RPC over HTTPS to Craft's MCP link endpoint — no SDK. The endpoint
is stateless, so each save is a single POST.

The document list is cached locally and refreshed in the background when the
popup opens (15-minute staleness window) or via menu bar → Refresh Documents,
so search is instant even with hundreds of documents.

### Images

Craft's API only ingests images it can fetch from a **public URL** — data URIs
are silently dropped. Dropped images are relayed through tmpfiles.org (60 min
retention; litterbox.catbox.moe as fallback). Craft copies the image to its own
CDN (`r.craft.do`) at save time, so the temp copy expiring doesn't matter.
Privacy note: the image is briefly on that third-party host at an unguessable
URL. If that bothers you, swap in your own host in `ImageUploader.swift`.

### Craft API quirks (confirmed empirically)

- Newlines in `--markdown` must be real newline characters. Escaped literal
  `\n` renders as literal text and disables markdown parsing.
- `documents list` pagination is cursor-based (`--cursor`, parsed from the
  "Next page:" trailer). `--offset` is accepted but ignored.
- A brand-new document can't receive `blocks add` for ~15–30 s after creation
  ("Document not found").
- Very small images (~100 bytes) are rejected with the same misleading
  "Document not found" error.

## Building

```sh
./build.sh            # build .build/bundle/CraftQuickCapture.app
./build.sh --install  # build, install to /Applications, relaunch
```

The app is ad-hoc signed, so it runs on your own machine. If you distribute a
built .app to others, macOS Gatekeeper will warn on first open (right-click →
Open); building from source avoids that.

Diagnostic: `CraftQuickCapture --selftest <pageId> [imagePath]` runs the save
pipeline from the CLI.

## Notes

- Change the shortcut via menu bar icon → **Settings…** — click the shortcut
  button, press a new combo (must include ⌘, ⌥, or ⌃; esc cancels recording).
  It re-registers immediately and persists. If macOS refuses the combo
  (another app already owns it), the previous shortcut stays active and
  Settings tells you — you can't end up with no working hotkey. "Reset to
  Default" restores ⌥⌘Space.
- The default ⌥⌘Space may conflict with the system "Show Finder search window"
  shortcut — disable that in System Settings → Keyboard → Keyboard Shortcuts →
  Spotlight, or just pick a different shortcut in Settings.

## License

MIT
