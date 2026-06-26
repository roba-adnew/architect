#!/usr/bin/env bash
# Build Architect from the CURRENT worktree and STAGE the fresh bundle so it
# applies on your NEXT quit + reopen of the daily /Applications app — no forced
# restart, no killing live agents mid-turn.
#
# Why staged-then-swap-on-quit instead of a plain in-place swap:
# a running macOS app is code-signed and its mach-o pages are mmap'd. If you
# overwrite its bundle while it's running, the kernel faults a page that no
# longer matches the cached signature and SIGKILLs the process
# ("Killed: 9" / cs_invalid_page). So the swap MUST happen while the app is not
# running. We build into a staging dir on the SAME volume as /Applications, then
# a tiny detached watcher waits for the running app to exit and atomically
# renames the staged bundle into place. This is the same shape Sparkle (the
# standard macOS updater) uses.
#
# Usage:
#   scripts/dev-stage.sh            build + stage + arm swap-on-quit watcher
#   scripts/dev-stage.sh --dry-run  build + stage into a temp dir, no swap/arm
#   scripts/dev-stage.sh --debug    stage a Debug build instead of ReleaseFast
set -euo pipefail

dry_run=false
build_debug=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --debug) build_debug=true ;;
        *) echo "unknown flag: $arg" >&2; exit 1 ;;
    esac
done
[ -n "${DEV_STAGE_DEBUG:-}" ] && build_debug=true

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ] || [ ! -f "$ROOT/scripts/bundle-macos.sh" ]; then
    echo "error: run this from inside the Architect repo (no scripts/bundle-macos.sh found)" >&2
    exit 1
fi
cd "$ROOT"

# Toolchain: a Nix dev shell provides zig; otherwise the native (Homebrew) env.
if ! command -v zig >/dev/null 2>&1; then
    if command -v nix >/dev/null 2>&1; then
        exec nix develop "$ROOT" -c "$0" "$@"
    fi
    echo "error: 'zig' is not on PATH and 'nix' is unavailable." >&2
    exit 1
fi
# shellcheck source=scripts/dev-build-env.sh
. "$ROOT/scripts/dev-build-env.sh"

APP="/Applications/Architect.app"
APP_EXE="$APP/Contents/MacOS/architect"
# Stage on the SAME volume as /Applications so the final swap is an atomic
# rename, not a slow cross-device copy that widens the window where the app path
# is missing. A dot-prefixed dir keeps it out of Finder/Launchpad.
STAGE_PARENT="/Applications/.architect-staged"
PIDFILE="${TMPDIR:-/tmp}/architect-stage-watcher.pid"
if [ "$dry_run" = true ]; then
    STAGE_PARENT="$(mktemp -d)"
fi

# Carry the daily app's persistence opt-in forward, so a stage never downgrades
# it out of tmux persistence (the --resume rewind fix). bundle-macos.sh bakes
# ARCHITECT_PERSIST_SESSIONS into Info.plist from this env, because the
# Finder-launched app doesn't inherit shell env. Mirrors dev-reload.sh.
if [ -z "${ARCHITECT_PERSIST_SESSIONS:-}" ] && [ -f "$APP/Contents/Info.plist" ]; then
    prev="$(/usr/libexec/PlistBuddy -c 'Print :LSEnvironment:ARCHITECT_PERSIST_SESSIONS' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$prev" = "1" ] || [ "$prev" = "true" ]; then
        export ARCHITECT_PERSIST_SESSIONS=1
        echo "==> Inherited ARCHITECT_PERSIST_SESSIONS=1 from the installed bundle."
    fi
fi

if [ "$build_debug" = true ]; then
    echo "==> Building Architect (Debug)..."
    zig build
else
    echo "==> Building Architect (ReleaseFast)..."
    zig build -Doptimize=ReleaseFast
fi

echo "==> Packaging staged bundle..."
rm -rf "$STAGE_PARENT"
mkdir -p "$STAGE_PARENT"
./scripts/bundle-macos.sh zig-out/bin/architect "$STAGE_PARENT" zig-out/bin/architect-mcp >/dev/null
staged="$STAGE_PARENT/Architect.app"
if [ ! -d "$staged" ]; then
    echo "error: bundling did not produce $staged" >&2
    exit 1
fi

if [ "$dry_run" = true ]; then
    echo "==> [dry-run] staged a valid bundle at: $staged"
    echo "    Would swap it into $APP on the next quit of the running app."
    echo "    Leaving it in place for inspection; remove with: rm -rf '$STAGE_PARENT'"
    exit 0
fi

# Cancel any previously-armed watcher: its staged build is now stale.
if [ -f "$PIDFILE" ]; then
    old="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$old" ]; then kill "$old" 2>/dev/null || true; fi
    rm -f "$PIDFILE"
fi

# Find the running daily app by its bundle exe path. Use ps, not pgrep: pgrep
# can fail to match the Finder-launched .app process in some shells, while ps
# reliably lists it.
app_pid="$(ps -Axo pid=,comm= | awk -v exe="$APP_EXE" '$2 == exe { print $1; exit }')"

if [ -z "$app_pid" ]; then
    echo "==> Daily app isn't running — applying the new build now."
    rm -rf "$APP.prev"
    mv "$APP" "$APP.prev" 2>/dev/null || true
    mv "$staged" "$APP"
    rm -rf "$APP.prev" "$STAGE_PARENT"
    echo "==> Done. Open Architect for the new build."
    exit 0
fi

# Arm a detached watcher: wait for THIS pid to exit (event-based, no polling),
# then atomically swap. nohup + disown so it survives the launching shell/PTY
# being torn down when Architect quits.
# shellcheck disable=SC2016
nohup bash -c '
    set -e
    app="$1"; staged="$2"; stage_parent="$3"; pid="$4"; pidfile="$5"
    caffeinate -w "$pid" 2>/dev/null || true
    sleep 1   # let the bundle fully release before renaming it out
    rm -rf "$app.prev"
    mv "$app" "$app.prev" 2>/dev/null || true
    mv "$staged" "$app"
    rm -rf "$app.prev" "$stage_parent"
    rm -f "$pidfile"
    osascript -e "display notification \"New build applied — reopen Architect.\" with title \"Architect\"" 2>/dev/null || true
' _ "$APP" "$staged" "$STAGE_PARENT" "$app_pid" "$PIDFILE" >/dev/null 2>&1 &
echo "$!" > "$PIDFILE"
disown

echo "==> Staged (watcher pid $(cat "$PIDFILE")). Your next Cmd+Q + reopen comes up on the new build."
echo "    Cancel before restarting with:  kill \$(cat '$PIDFILE') 2>/dev/null; rm -rf '$STAGE_PARENT'"
