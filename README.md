# dad.workspace-rules

Pin apps to workspaces. A new window of a listed app opens directly on its
assigned workspace, every time.

## What it does

Open the panel, pick an app from the dropdown, pick a workspace, press **Add
rule**. From then on:

- new windows of that app are moved to the workspace the moment they open;
- windows already open are relocated immediately, including on shell reload;
- removing the rule restores normal placement.

Enforcement is a Hyprland dispatch (`hl.dsp.window.move`) rather than a
`windowrulev2`, so it is driven by the live window list and survives a Hyprland
config reload.

## Install

```bash
omarchy plugin add https://github.com/duncio/dad.workspace-rules
omarchy plugin enable dad.workspace-rules
```

Then move it where you want it:

```bash
omarchy bar move dad.workspace-rules --section left
```

## Using it

| Control | Effect |
|---|---|
| App dropdown | Every `.desktop` entry on the system, searchable, sorted by name |
| Always open on | Workspaces 1–10 |
| Add rule | Stores the rule for the selected app and workspace |
| Rules list | Each row shows `App → ws N`; click a row to remove it |

The script prints the **entire** rules array after every change, so the panel
updates from one round trip rather than assuming its own optimistic state. Rules
are keyed by `appId`, so re-adding an app replaces its workspace instead of
stacking a second rule for it.

## How it works

```
                     ┌─ openwindow event ─┐
                     │                    ▼
rules.json ◄─ script ─┴─► BarWidget.qml ─► Hyprland.dispatch(move)
             (python)      (match class)      └─ 600 ms later: sweep
                            ▲
                            └── hyprctl clients -j   (existing windows)
```

**Matching is by Hyprland window class**, which is why the plugin stores a
`class` next to each app. The class is resolved from the desktop entry, in
order:

1. `StartupWMClass`, if it is not one of the `@@`-prefixed placeholder values
   that some entries ship instead;
2. the basename of the first word of `Exec`.

If neither yields anything usable, the app cannot be ruled on and the panel says
so in red rather than adding a rule that would never match.

**Two paths catch a window.** The `openwindow` Hyprland event fires first and
moves the window straight away. Because some apps set their own workspace *after*
mapping, a 600 ms timer then re-sweeps every client via `hyprctl clients -j` and
moves anything still on the wrong workspace. Apps that fight this on a timer will
keep losing.

**Commands are queued, not parallel.** One `Process` with a FIFO queue, so rapid
clicks cannot interleave writes to `rules.json`.

## Files

| File | Role |
|---|---|
| `manifest.json` | Registers the plugin; declares it a bar widget with a `defaultWorkspace` setting |
| `BarWidget.qml` | The panel, the app list, class resolution, and Hyprland enforcement |
| `scripts/workspace-rules` | Python: loads, writes, and prints rules as JSON |
| `rules.json` | The rules themselves |

`rules.json` is plain JSON and is meant to be edited by hand:

```json
[
  {
    "appId": "chromium",
    "label": "Chromium",
    "class": "chromium",
    "workspace": 1
  }
]
```

It is versioned with the plugin, so your rules survive a reinstall — but that
also means the rules in this repository are the ones a fresh install starts
with. Delete the file's contents for a clean slate.

## Settings

Configured in `~/.config/omarchy/shell.json`, editable from Omarchy Settings.

| Setting | Default | Effect |
|---|---|---|
| `defaultWorkspace` | `3` | Workspace pre-selected in the dropdown |

## CLI

```bash
scripts/workspace-rules get
scripts/workspace-rules add <appId> <label> <class> <workspace>
scripts/workspace-rules remove <appId>
scripts/workspace-rules clear
```

Every command prints the full rules array as JSON on stdout.

## Troubleshooting

**A rule was added but windows still open elsewhere.** Compare the stored class
against what Hyprland reports:

```bash
hyprctl clients -j | grep -o '"class":[^,]*'
```

If they differ, the desktop entry's `StartupWMClass` is wrong or absent. Edit the
rule's `class` in `rules.json`, or delete and re-add it.

**"No window class is known for this app."** Neither `StartupWMClass` nor `Exec`
gave a usable value. Common for AppImages and hand-written `.desktop` files.
Add a `StartupWMClass` line, or set the class by hand in `rules.json`.

**A window opens on the right workspace, then jumps back.** The app is choosing
its own workspace after mapping. The 600 ms sweep usually wins; if it does not,
the app is not compatible with being moved.

**Dialogs and utility windows move too.** A File chooser or an about window
shares the app's class, so it is subject to the same rule. This is inherent to
class-based matching.

**Changes are not picked up.** `rules.json` is read when the panel loads and on
every change made through the panel. An external edit needs a reload:

```
omarchy-shell shell rescanPlugins
```