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
/// the agent), instant Escape, generous scrollback, truecolor passthrough, and
/// sessions that outlive a detached client.
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
    \\set -as terminal-features ",*:RGB"
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
    const path_env = posix.getenv("PATH") orelse return null;
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
