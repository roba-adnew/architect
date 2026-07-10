---
Status: Active
Created: 2026-07-09
Task: Hidden switcher status accuracy — stop force-setting "working" on interaction; idle/dash defaults; "hosting" for server terminals
---

# Switcher status: idle / working / hosting

## Goal

The hidden-terminal switcher (Cmd+Shift+J) should show what a terminal is
actually doing: "working" only while Claude is processing, "idle" when a
Claude session is at rest, "–" for terminals Claude never touched, "hosting"
when the terminal is serving something locally.

## Functional requirements

1. Remove the force-set of `.running` at the interaction call sites in
   `runtime.zig` (spawn, focus, click, hotkey, worktree switch/create/remove,
   cd). Status changes come only from Claude's notify-socket hooks:
   `start` → working, `awaiting_approval` → needs you, `done` → done.
2. Default session status becomes `.idle` (change `session_view_state.zig`
   default from `.running`).
3. "Done" stays sticky as the attention cue; focusing a "done" terminal
   acknowledges it down to "idle".
4. Track `claude_seen` per session view (set on any notify-socket status).
   `.idle` renders as "idle" when `claude_seen`, "–" when not.
5. Hosting detection (macOS): a terminal is "hosting" when a process in its
   pane's process tree holds a listening TCP socket. One
   `lsof -nP -iTCP -sTCP:LISTEN` + one `ps -axo pid,ppid` per poll covers all
   sessions; walk each listener's parent chain to a pane pid. tmux-aware:
   use the tmux pane pid (the real tree lives under the tmux server).
6. Poll only while the switcher is open — snapshot on open, refresh ~5s while
   held open. No background polling when the menu is closed.
7. Display precedence: needs you / done / working (Claude states) > hosting >
   idle/dash. New "hosting" label with its own marker/color.

## Non-goals

Border colors, attention dots, grid UI (switcher labels only); Linux hosting
detection; manual marking.

## Task outline

1. Strip `.running` from runtime interaction sites; default → `.idle`;
   done→idle acknowledgment on focus; `claude_seen` flag.
2. Hosting-detection helper (lsof + ps tree walk, tmux pane pid).
3. Wire polling + "hosting"/dash labels into `hidden_switcher.zig`.
4. Ponytail → refactor → tester (zig build / test / lint), docs update.
