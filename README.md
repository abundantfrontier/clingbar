# ClingBar

**A sticky edge bar for macOS that keeps app switching on the current Space.**

macOS loves to yank you to another desktop when you click an app that already has windows elsewhere. ClingBar is the opposite: a thin, always-available bar that **raises or opens apps on the Space you’re on**, and leaves desktop switching to Mission Control.

> **ClingBar** is the app (edge chrome + menu bar).  
> The **Focus bar** is the strip of apps that only act on *this* Space.

---

## Why it exists

Multi-project setups often look like:

| Space | Work |
|-------|------|
| Desktop 1 | Email / calendar |
| Desktop 2 | Project A (editor + terminal) |
| Desktop 3 | Project B |

You want to hop between VS Code and Terminal **without** leaving Project A’s Space. The Dock and ⌘Tab don’t guarantee that. ClingBar does, by design.

---

## Features

| Feature | What it does |
|---------|----------------|
| **Sticky edge bar** | Survives Space switches (`canJoinAllSpaces` + `stationary`) |
| **Focus pins** | Click → raise / cycle windows **only on this Space** |
| **New window here** | Multi-window apps with nothing on this Space open a new window **here** (not jump) |
| **Current tasks** | Any app with a window on this Space appears on the bar (no pin required) |
| **Apps picker** | Search installed apps → **Open Here** once, or **Add to Focus Bar** for a lasting slot |
| **Spaces button** | Opens system **Mission Control** (same idea as F3) |
| **Single-window apps** | Stocks, System Settings, etc. only show on the Space where they’re open |
| **Single instance** | A second launch re-shows the existing bar; no duplicate process |
| **Presentations** | Floats over normal apps; not a full-screen auxiliary (stays off Keynote / PPT play mode) |
| **In-app help** | First-run panel + menu **How ClingBar Works…** |

### Focus bar slots

1. **Pins (lasting).** Defaults (VS Code, Terminal, …) plus anything you add. Stored in settings.
2. **Current tasks (temporary).** Apps that have a window **on this Space**, whether you opened them from ClingBar, the Dock, Spotlight, or another desktop. They leave the bar when they leave the Space. Right-click → **Add to Focus Bar** if you want them to stay.

### Layout

```
[ Apps ]  ·  focus apps / current tasks  ·  [ Spaces ]  ·  drag handle
```

- **Apps:** stay-here launcher + add pins  
- **Spaces:** Mission Control  
- **Drag handle:** move the bar to another edge (left / right / top / bottom)

---

## Requirements

- **macOS 14+** (developed against recent Xcode / macOS)
- **Accessibility** permission (raise specific windows, File → New Window menus)

Sandbox is **off** (required for window enumeration and Accessibility-driven activation).

---

## Install & run (from source)

```bash
git clone <your-repo-url> clingbar
cd clingbar
make run          # Debug build + launch
```

| Command | Result |
|---------|--------|
| `make build` | Debug build only |
| `make release` | Release build |
| `make clean` | Remove `build/` |
| `open ClingBar.xcodeproj` | Open in Xcode |

App product:

```text
build/Build/Products/Debug/ClingBar.app
```

For day-to-day use, open that folder in Finder and double-click **ClingBar.app** so the process isn’t tied to a terminal session.

---

## First launch

1. If Accessibility isn’t granted, ClingBar opens **System Settings → Privacy & Security → Accessibility** after a short delay (avoids a launch-time sheet that can garble the menu bar for accessory apps).
2. Enable **ClingBar**.
3. A short **How ClingBar Works** panel appears once (also under the menu bar icon anytime).
4. The bar appears on the **left** edge by default; the menu bar uses a small edge-bar glyph.

---

## How it works

### Stay on this Space

When you click a Focus app:

1. **Windows on this Space** → raise the right one, or cycle if you click again.  
2. **None here, multi-window app** (Terminal, browsers, editors, Finder, …) → open a **new window on this Space**.  
3. **None here, single-window app** already running elsewhere → slot is **hidden** (no dead click, no Space jump).  
4. **Not running** → launch on this Space.

ClingBar prefers **Accessibility raise** on a specific window over a blanket `activate()`. Full app activation often triggers:

> System Settings → Desktop & Dock →  
> *When switching to an application, switch to a Space with open windows for the application*

That preference is exactly what Focus mode is designed to avoid.

### What “current Space” means

Public APIs don’t expose Space IDs cleanly. ClingBar treats **on-screen standard windows** (`CGWindowListCopyWindowInfo` + `.optionOnScreenOnly`) as belonging to the focused Space.

### Finder

Finder is special: a plain activate or `open ~/` often jumps to an existing window on another desktop. ClingBar uses **new Finder window** scripting (and careful raise ordering) so “no folder window here” means **new window on this Space**.

### Single-window apps

There is no reliable macOS flag for “single-window app.” ClingBar uses:

- Known multi-window IDs (Terminal, browsers, editors, Finder, …)  
- A list of single-destination utilities (Stocks, Settings, Calculator, …)  
- Runtime window counts for show/hide  

Pins stay in settings; only the **slot** hides when the instance lives only on another Space.

### Multi-monitor

Today the bar is laid out against **`NSScreen.main`** (primary display). Extended desktop works, but there is no per-display bar yet (see Roadmap).

### Presentations

The panel is **`.floating`** but **not** `.fullScreenAuxiliary`, so it stays above normal windows without drawing over full-screen presentation Spaces.

---

## Menu bar

| Item | Action |
|------|--------|
| Show / Hide ClingBar | Toggle edge bar |
| Add Apps to Focus Bar… | Open Apps picker |
| Mission Control… | System Mission Control |
| Dock Edge | Left / Right / Top / Bottom |
| Auto-Hide | Collapse until mouse nears the edge |
| How ClingBar Works… | Help panel |
| Request Accessibility… | Open System Settings |
| Quit ClingBar | Exit |

A second open of **ClingBar.app** re-shows the existing instance instead of starting another.

---

## Default pins

On first launch, installed apps from this set are pinned:

VS Code, Cursor, Finder, Terminal, iTerm, Warp, Safari, Chrome, Arc, Brave.

Add more via **Apps → Add to Focus Bar**, or right-click a current-task slot.

---

## Settings

Persisted in UserDefaults (`clingbar.settings.v2`):

- Dock edge, auto-hide, show labels, bar thickness  
- Pinned Focus apps  
- Include unpinned on-Space apps (current tasks)  
- Missing-window policy (open new vs move from other Space)  
- Help first-run flag  

Some older fields (browser-tab pins, desk names) may still be stored for parked experimental features; they are not exposed in the product UI.

---

## Architecture

Native **AppKit** accessory app (`LSUIElement`). No SwiftUI shell, no SPM dependencies.

```text
ClingBar/
  Sources/
    ClingBarApp.swift              # @main, single-instance gate
    AppDelegate.swift              # Status item, lifecycle
    Models/
      SettingsStore, PinnedApp, DockEdge, …
      FocusBarVisibility           # When to show/hide pins
    Services/
      WindowInfo                   # CGWindow enumeration
      SpaceAwareActivator          # Stay-here raise / cycle / new window
      AppListService               # Pins + current tasks
      AppCatalogService            # Installed-app scan for Apps picker
      SpaceService / SpaceTransition / Place*   # Parked experimental paths
    UI/
      ClingBarPanelController      # Sticky NSPanel
      ClingBarContentView          # Apps · focus · Spaces
      AppsPickerController         # Open here / add pin
      HelpPanelController          # First-run + menu help
    Utilities/
      AccessibilityPermission, AppIconCache, SingleInstance
```

### Parked (not in the product UI)

Earlier work explored **custom Space switching** (private CGS/SkyLight), an in-app desktop list, cross-Space App Switcher, and browser-tab pins. That path was unstable on recent macOS betas (menu bar garble, windows following Spaces). The code remains for a later revisit; the shipping product uses **system Mission Control** only for desktop changes.

---

## Non-goals (current)

- Window tiling / snapping  
- Replacing Mission Control  
- Per-display Focus bars (roadmap)  
- Theming engine  
- Agent / project integration  
- Jumping Spaces from a Focus pin click  

---

## Roadmap

- [ ] Revisit custom Space switch / App Switcher when WindowServer behavior is stable  
- [ ] Hover window titles / optional previews  
- [ ] Global hotkeys (focus bar, number / letter jump)  
- [ ] Per-display edge / visibility  
- [ ] Drag-reorder pins  
- [ ] Notification badges when apps expose them  

---

## Development notes

- Prefer **manual launch** of `ClingBar.app` when testing Accessibility and Space behavior.  
- Accessibility is required for correct raise / new-window behavior.  
- Desktop & Dock “switch to Space with windows” can still affect any path that activates an app without a local window. Focus mode is built to minimize those paths.  
- Build artifacts live under `build/` (gitignored).

```bash
# Force first-run help again
defaults delete app.clingbar.ClingBar clingbar.didShowHelp.v1
```

---

## License

[MIT](LICENSE)

---

## Name

| Term | Meaning |
|------|---------|
| **ClingBar** | The application (sticky edge bar + menu bar control) |
| **Focus bar** | The app slots that only act on the current Space |
| **Current task** | Temporary slot for an app that has a window on this Space |
| **Pin** | Lasting Focus bar slot (defaults + “Add to Focus Bar”) |
