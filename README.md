# Snippets

Highlight text anywhere, tap **Shift twice**, and the text is saved as an item.
Browse, search, edit, title, add and delete items from a bar icon in omarchy-shell.

Every item is one Markdown file in `~/Documents/snippets/` (override with `SNIPPETS_DIR`):

```markdown
---
title: "Deploy checklist"
created: 2026-10-13T15:42:07-03:00
---
1. bump version
2. run tests
```

Files you drop in by hand, with or without front matter, show up too.

## Pieces

| Path | What |
|---|---|
| `daemon/` | `snip`, a Rust binary (~770 KB). `snip daemon` watches keyboards over evdev for a double Shift tap, then reads the primary selection (what's highlighted), so your clipboard is left alone. It reads the Wayland primary (`wl-paste --primary`) for native apps and the X11 PRIMARY for XWayland apps such as VS Code with `--ozone-platform=x11`, picked by asking Hyprland which window is focused. `list` / `save` / `delete` are the only code that touches the files. |
| `plugin/` | omarchy-shell bar widget (QML): a 448px popup with search, list, and an inline editor. All I/O goes through `snip`. |
| `dist/snip.service` | systemd user unit, started with the graphical session. |
| `dist/70-snippets-keyboard.rules` | udev rule giving the active seat user read access to keyboards. It's narrower than the `input` group and needs no relogin. |

## Install

```bash
./install.sh
# once, for double Shift:
sudo install -m644 dist/70-snippets-keyboard.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=input
```

`install.sh` builds `snip` into `~/.local/bin`, enables `snip.service`, copies the
plugin to `~/.config/omarchy/plugins/mvrcelo.snippets` and enables it. Rerun it after
changing anything here. If the bar doesn't pick up QML changes, run `omarchy-restart-shell`.

## Use

- **Bar icon**: left click toggles the panel. Right click opens a new item.
- **List**: type to search (title and body, all words must match). `↑/↓` move, `Enter` edits,
  `Ctrl+N` adds an item, `Ctrl+D` deletes (press twice to confirm), `Esc` clears the search, then closes.
- **Editor**: `Ctrl+S` or `Esc` saves and goes back. Clicking outside also saves. Cancel discards.

Optional Hyprland binds (`~/.config/hypr/bindings.conf`):

```
bind = SUPER SHIFT, V, exec, omarchy-shell snippets toggle
bind = SUPER SHIFT, N, exec, omarchy-shell snippets create
```

## Troubleshooting

- `journalctl --user -u snip -f` shows which keyboards the daemon is watching, and logs every
  capture with its source (`wayland` or `x11`).
- "Nothing selected": the app didn't set a primary selection. Most Wayland apps do on highlight.
