//! tmux-backed session persistence (Phase 1).
//!
//! When enabled, Architect spawns each shell *inside* a detached tmux session so
//! agents (claude/codex/gemini) survive an Architect restart and reattach live,
//! instead of being killed at quit and resumed from a possibly-stale local
//! transcript (the bridged `--resume` rewind bug). The tmux server double-forks
//! away from Architect's process tree, so quitting Architect — yours or the
//! reload script's — only drops the client; the server + shell + agent live on.
//!
//! Gated behind `ARCHITECT_PERSIST_SESSIONS=1`. When disabled, or when tmux is
//! not on PATH, `buildPersist` returns null and the caller spawns a direct shell
//! exactly as before — so this is strictly non-breaking.
const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.tmux);

/// Everything `Shell.spawn` needs to wrap a shell in a persistent tmux session.
/// All fields are owned heap strings; free with `freePersist`.
pub const Persist = struct {
    /// Absolute path to the tmux binary (execve needs a full path).
    tmux_path: [:0]const u8,
    /// Private server socket, stable across restarts so reattach finds the session.
    socket_path: [:0]const u8,
    /// Per-slot session name (`architect-<slot>`); `new-session -A` keys off this.
    session_name: [:0]const u8,
    /// Config that makes tmux a transparent layer (no status bar, no keybindings).
    conf_path: [:0]const u8,
};

/// tmux config that turns tmux into an invisible persistence layer: no status
/// bar, no prefix, every key unbound (so Ctrl-B etc. pass straight through to
/// the agent), instant Escape, generous scrollback, truecolor passthrough,
/// OSC 8 hyperlink passthrough (so Cmd+Click doc links survive the tmux round
/// trip), and sessions that outlive a detached client.
///
/// `hyperlinks` in terminal-features tells tmux the OUTER terminal (Architect)
/// understands OSC 8, so tmux re-emits hyperlinks it parsed from the pane
/// instead of stripping them; `allow-passthrough on` lets agents forward raw
/// escape sequences (OSC 52 clipboard, etc.) through tmux unmodified. Verified:
/// without `hyperlinks`, a pane's OSC 8 link is dropped before reaching
/// Architect; with it, the link is re-emitted intact.
const conf_contents =
    \\set -g status off
    \\set -g prefix None
    \\set -g prefix2 None
    \\unbind-key -a
    \\set -g escape-time 0
    \\set -g history-limit 50000
    \\set -g destroy-unattached off
    \\set -g mouse off
    \\set -g focus-events off
    \\set -g default-terminal "screen-256color"
    \\set -as terminal-features ",*:RGB:hyperlinks"
    \\set -g allow-passthrough on
    \\
;

/// Did the user opt into persistent sessions for this run?
pub fn persistEnabled() bool {
    const v = posix.getenv("ARCHITECT_PERSIST_SESSIONS") orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
}

/// Allocate a null-terminated formatted string. Caller owns the result.
/// Uses a manual len+1 buffer (not allocSentinel) so freeing the returned
/// `[:0]u8` matches the allocation size exactly.
fn allocZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    const buf = try allocator.alloc(u8, s.len + 1);
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// Resolve an executable on PATH. Caller owns the returned string.
fn findOnPath(allocator: std.mem.Allocator, name: []const u8) ?[:0]u8 {
    const path_env = posix.getenv("PATH") orelse "";
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = allocZ(allocator, "{s}/{s}", .{ dir, name }) catch return null;
        if (posix.accessZ(candidate.ptr, posix.X_OK)) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    // Fallback to common install dirs. A Finder/login-item launch inherits
    // launchd's minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin), which omits
    // Homebrew, so tmux at /opt/homebrew/bin would be missed and persistence
    // would silently degrade to non-persistent shells. Check those dirs too.
    const fallback_dirs = [_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin" };
    for (fallback_dirs) |dir| {
        const candidate = allocZ(allocator, "{s}/{s}", .{ dir, name }) catch return null;
        if (posix.accessZ(candidate.ptr, posix.X_OK)) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    return null;
}

/// Stable per-user runtime directory for the tmux socket + config. Must be
/// stable across restarts (so reattach finds the same socket) and short enough
/// to keep the socket path under the ~104-char sun_path limit.
fn runtimeDir() []const u8 {
    if (posix.getenv("XDG_RUNTIME_DIR")) |d| if (d.len > 0) return trimTrailingSlash(d);
    if (posix.getenv("TMPDIR")) |d| if (d.len > 0) return trimTrailingSlash(d);
    return "/tmp";
}

fn trimTrailingSlash(d: []const u8) []const u8 {
    if (d.len > 1 and d[d.len - 1] == '/') return d[0 .. d.len - 1];
    return d;
}

fn writeConf(path: [:0]const u8) !void {
    const file = try std.fs.cwd().createFileZ(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(conf_contents);
}

/// Re-apply the passthrough options to a server that is ALREADY running. tmux
/// reads `-f` only when it first starts the server, so a server left over from a
/// previous Architect launch keeps its old options (e.g. missing the hyperlinks
/// feature) even after we rewrite the file. The next client attach negotiates
/// these, so OSC 8 links survive without restarting the server (which would kill
/// the agents). Best effort — on the first launch no server exists yet (no-op).
///
/// We set the two relevant options directly rather than `source-file`-ing the
/// whole conf, because the conf's `unbind-key -a` errors ("table prefix doesn't
/// exist") on a server whose prefix table was already emptied at start, aborting
/// the rest of the file before it reaches these lines. Keep in sync with
/// `conf_contents`.
fn refreshRunningServer(allocator: std.mem.Allocator, tmux_path: [:0]const u8, socket_path: [:0]const u8) void {
    var child = std.process.Child.init(&[_][]const u8{
        tmux_path,       "-S",                socket_path,
        "set",           "-ag",               "terminal-features",
        ",*:hyperlinks", ";",                 "set",
        "-g",            "allow-passthrough", "on",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return;
}

/// Build persist options for a session slot, or null if persistence is disabled
/// or unavailable (tmux not found). On any partial failure, frees what it
/// allocated and returns null so the caller falls back to a direct shell spawn.
pub fn buildPersist(allocator: std.mem.Allocator, slot_index: usize) ?Persist {
    if (!persistEnabled()) return null;

    const tmux_path = findOnPath(allocator, "tmux") orelse {
        log.warn("ARCHITECT_PERSIST_SESSIONS set but tmux not found on PATH; using direct shell", .{});
        return null;
    };
    errdefer allocator.free(tmux_path);

    const dir = runtimeDir();
    const socket_path = allocZ(allocator, "{s}/architect-tmux.sock", .{dir}) catch return null;
    errdefer allocator.free(socket_path);
    const conf_path = allocZ(allocator, "{s}/architect-tmux.conf", .{dir}) catch return null;
    errdefer allocator.free(conf_path);
    const session_name = allocZ(allocator, "architect-{d}", .{slot_index}) catch return null;
    errdefer allocator.free(session_name);

    writeConf(conf_path) catch |err| {
        log.warn("failed to write tmux config {s}: {}; using direct shell", .{ conf_path, err });
        return null;
    };

    // Push current options into a server that survived a previous launch, so the
    // upcoming attach negotiates with the new conf (e.g. hyperlinks) instead of
    // the stale one. No-op when no server is running yet.
    refreshRunningServer(allocator, tmux_path, socket_path);

    return .{
        .tmux_path = tmux_path,
        .socket_path = socket_path,
        .session_name = session_name,
        .conf_path = conf_path,
    };
}

pub fn freePersist(allocator: std.mem.Allocator, p: Persist) void {
    allocator.free(p.tmux_path);
    allocator.free(p.socket_path);
    allocator.free(p.session_name);
    allocator.free(p.conf_path);
}

/// Scroll a persistent session's history via the tmux control socket.
///
/// Under persistence the shell runs full-screen *inside* tmux, so scrolled-off
/// lines live in tmux's 50k history buffer, not Architect's ghostty-vt
/// scrollback — the wheel handler has nothing of its own to scroll. So drive
/// tmux copy-mode out-of-band: `copy-mode -e` enters it (idempotent; the `-e`
/// flag auto-exits when scrolled back to the bottom) and `send-keys -X -N <n>
/// scroll-{up,down}` moves the view. One combined tmux invocation per call.
/// Best-effort: a missing tmux or a failed call is a silent no-op, never an
/// error surfaced to the UI.
///
/// ponytail: spawnAndWait blocks the caller ~5-10ms per wheel tick — fine at
/// mouse-wheel cadence; if trackpad momentum feels laggy, coalesce ticks or
/// detach the spawn (double-fork). Also: while scrolled up the pane sits in tmux
/// copy-mode, so keystrokes are captured until you scroll back to the bottom.
pub fn scrollHistory(allocator: std.mem.Allocator, slot_index: usize, lines: u16, up: bool) void {
    if (!persistEnabled()) return;
    if (lines == 0) return;

    const tmux_path = findOnPath(allocator, "tmux") orelse return;
    defer allocator.free(tmux_path);

    const dir = runtimeDir();
    const socket_path = allocZ(allocator, "{s}/architect-tmux.sock", .{dir}) catch return;
    defer allocator.free(socket_path);
    const target = allocZ(allocator, "architect-{d}", .{slot_index}) catch return;
    defer allocator.free(target);

    var count_buf: [8]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d}", .{lines}) catch return;
    const scroll_cmd: []const u8 = if (up) "scroll-up" else "scroll-down";

    var child = std.process.Child.init(&[_][]const u8{
        tmux_path,   "-S",   socket_path,
        "copy-mode", "-e",   "-t",
        target,      ";",    "send-keys",
        "-t",        target, "-X",
        "-N",        count,  scroll_cmd,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return;
}

/// Exit copy-mode for a persistent session's pane (best-effort, no-op if not in
/// copy-mode). `scrollHistory` leaves the pane in tmux copy-mode, which is modal —
/// the cursor and keys belong to the scroll, not the app underneath — so the first
/// keystroke afterward should snap back to the live prompt. Called from
/// `SessionState.sendInput`; spawnAndWait so copy-mode is gone before the keystroke
/// is written to the PTY (otherwise the key would drive the scroll instead).
pub fn cancelCopyMode(allocator: std.mem.Allocator, slot_index: usize) void {
    if (!persistEnabled()) return;

    const tmux_path = findOnPath(allocator, "tmux") orelse return;
    defer allocator.free(tmux_path);

    const dir = runtimeDir();
    const socket_path = allocZ(allocator, "{s}/architect-tmux.sock", .{dir}) catch return;
    defer allocator.free(socket_path);
    const target = allocZ(allocator, "architect-{d}", .{slot_index}) catch return;
    defer allocator.free(target);

    var child = std.process.Child.init(&[_][]const u8{
        tmux_path, "-S", socket_path, "send-keys", "-t", target, "-X", "cancel",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return;
}
