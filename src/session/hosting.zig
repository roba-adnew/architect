const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const SessionState = @import("state.zig").SessionState;
const tmux = @import("../tmux.zig");

const log = std.log.scoped(.hosting);

/// Cap on parent-chain hops when walking a listener pid up to a session root.
const max_walk_depth = 32;
/// The full `ps -axo pid=,ppid=` table for a busy machine fits well under this.
const max_subprocess_output = 1 << 20;

const RootMap = std.AutoHashMap(posix.pid_t, usize);

/// Mark each hidden session whose pane process tree owns a listening TCP
/// socket ("hosting" a local server). `out[i]` parallels `sessions[i]`.
///
/// One `lsof` (TCP listeners only) + one `ps` (pid→ppid table) covers all
/// sessions; each listener's parent chain is walked up to a session's root
/// pid. tmux-backed sessions use the tmux pane pid — their real process tree
/// lives under the tmux server, not our PTY child (the tmux client).
///
/// Spawns subprocesses (~tens of ms), so callers must poll sparingly — the
/// switcher polls only while its modal is open. macOS only; elsewhere all
/// flags stay false.
pub fn detectHosting(allocator: std.mem.Allocator, sessions: []const *SessionState, out: []bool) void {
    @memset(out[0..sessions.len], false);
    if (builtin.os.tag != .macos) return;

    var roots = RootMap.init(allocator);
    defer roots.deinit();
    for (sessions, 0..) |session, i| {
        if (!session.spawned or session.dead or !session.hidden) continue;
        const root = if (session.tmux_backed)
            tmux.panePid(allocator, session.persist_index)
        else
            session.shellPid();
        if (root) |pid| {
            roots.put(pid, i) catch |err| {
                log.warn("failed to record session root pid: {}", .{err});
                return;
            };
        }
    }
    if (roots.count() == 0) return;

    // -Fp prints one "p<pid>" line per process holding a LISTEN TCP socket.
    const listeners = runCapture(allocator, &.{ "/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fp" }) orelse return;
    defer allocator.free(listeners);
    const ps_table = runCapture(allocator, &.{ "/bin/ps", "-axo", "pid=,ppid=" }) orelse return;
    defer allocator.free(ps_table);

    markListenerSessions(allocator, listeners, ps_table, &roots, out);
}

/// Pure core of detectHosting: parse the lsof `-Fp` listener list and the ps
/// pid/ppid table, then walk each listener's parent chain; any chain that
/// reaches a root pid marks that root's session in `out`.
fn markListenerSessions(
    allocator: std.mem.Allocator,
    listeners: []const u8,
    ps_table: []const u8,
    roots: *const RootMap,
    out: []bool,
) void {
    var parent = std.AutoHashMap(posix.pid_t, posix.pid_t).init(allocator);
    defer parent.deinit();
    var rows = std.mem.tokenizeScalar(u8, ps_table, '\n');
    while (rows.next()) |row| {
        var fields = std.mem.tokenizeAny(u8, row, " \t");
        const pid_text = fields.next() orelse continue;
        const ppid_text = fields.next() orelse continue;
        const pid = std.fmt.parseInt(posix.pid_t, pid_text, 10) catch |err| {
            log.debug("skipping ps row with unparsable pid {s}: {}", .{ pid_text, err });
            continue;
        };
        const ppid = std.fmt.parseInt(posix.pid_t, ppid_text, 10) catch |err| {
            log.debug("skipping ps row with unparsable ppid {s}: {}", .{ ppid_text, err });
            continue;
        };
        parent.put(pid, ppid) catch |err| {
            log.warn("failed to record pid table entry: {}", .{err});
            return;
        };
    }

    var lines = std.mem.tokenizeScalar(u8, listeners, '\n');
    while (lines.next()) |line| {
        if (line.len < 2 or line[0] != 'p') continue;
        var pid = std.fmt.parseInt(posix.pid_t, line[1..], 10) catch |err| {
            log.debug("skipping lsof line with unparsable pid {s}: {}", .{ line, err });
            continue;
        };
        var depth: usize = 0;
        while (depth < max_walk_depth) : (depth += 1) {
            if (roots.get(pid)) |session_idx| {
                out[session_idx] = true;
                break;
            }
            pid = parent.get(pid) orelse break;
            if (pid <= 1) break;
        }
    }
}

/// Run a command and return its stdout (caller owns). Null on spawn failure.
/// A non-zero exit with output still returns the output — lsof exits 1 when
/// some files can't be inspected even though listeners were found.
fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = max_subprocess_output,
    }) catch |err| {
        log.warn("{s} failed to run: {}", .{ argv[0], err });
        return null;
    };
    allocator.free(result.stderr);
    return result.stdout;
}

test "listener descended from a root marks its session" {
    const allocator = std.testing.allocator;
    var roots = RootMap.init(allocator);
    defer roots.deinit();
    try roots.put(100, 2); // session 2's pane shell is pid 100

    // pid 300 (listener) ← parent 200 ← parent 100 (root)
    const ps_table = "  100     1\n  200   100\n  300   200\n  999     1\n";
    const listeners = "p300\np999\n";

    var out = [_]bool{ false, false, false };
    markListenerSessions(allocator, listeners, ps_table, &roots, &out);
    try std.testing.expectEqual([_]bool{ false, false, true }, out);
}

test "root pid itself listening marks its session" {
    const allocator = std.testing.allocator;
    var roots = RootMap.init(allocator);
    defer roots.deinit();
    try roots.put(50, 0);

    var out = [_]bool{false};
    markListenerSessions(allocator, "p50\n", "  50   1\n", &roots, &out);
    try std.testing.expectEqual([_]bool{true}, out);
}

test "unrelated listeners and malformed lines mark nothing" {
    const allocator = std.testing.allocator;
    var roots = RootMap.init(allocator);
    defer roots.deinit();
    try roots.put(100, 0);

    var out = [_]bool{false};
    // f-lines (lsof field prefixes we ignore), garbage, and an orphan chain.
    markListenerSessions(allocator, "f12\npabc\np777\n", "  777   666\n", &roots, &out);
    try std.testing.expectEqual([_]bool{false}, out);
}
