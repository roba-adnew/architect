// Dynamic grid layout management for the terminal wall.
// Handles automatic grid expansion/contraction as terminals are added/removed.
const std = @import("std");
const geom = @import("../geom.zig");
const easing = @import("../anim/easing.zig");

const Rect = geom.Rect;
const log = std.log.scoped(.grid_layout);

pub const max_grid_size: usize = 12;
pub const max_terminals: usize = max_grid_size * max_grid_size;

/// Represents a position in the grid (column, row).
pub const GridPosition = struct {
    col: usize,
    row: usize,

    pub fn toIndex(self: GridPosition, cols: usize) usize {
        return self.row * cols + self.col;
    }

    pub fn fromIndex(idx: usize, cols: usize) GridPosition {
        return .{
            .col = idx % cols,
            .row = idx / cols,
        };
    }
};

/// Animation state for a terminal moving between grid positions.
pub const TerminalAnimation = struct {
    session_idx: usize,
    start_rect: Rect,
    target_rect: Rect,
    start_time: i64,
};

/// Describes how a session moves when the grid layout changes.
pub const SessionMove = struct {
    session_idx: usize,
    old_index: ?usize,
};

/// Manages dynamic grid dimensions based on active terminal count.
pub const GridLayout = struct {
    cols: usize,
    rows: usize,
    /// Animations for terminals moving during grid resize.
    animations: std.ArrayList(TerminalAnimation),
    /// Timestamp when grid resize animation started.
    resize_start_time: i64,
    /// Previous dimensions before resize (for animation).
    prev_cols: usize,
    prev_rows: usize,
    /// Whether a grid resize animation is in progress.
    is_resizing: bool,
    allocator: std.mem.Allocator,

    pub const animation_duration_ms: i64 = 300;

    pub fn init(allocator: std.mem.Allocator) !GridLayout {
        return .{
            .cols = 1,
            .rows = 1,
            .animations = try std.ArrayList(TerminalAnimation).initCapacity(allocator, 16),
            .resize_start_time = 0,
            .prev_cols = 1,
            .prev_rows = 1,
            .is_resizing = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GridLayout) void {
        self.animations.deinit(self.allocator);
    }

    /// Calculate optimal grid dimensions for a given terminal count.
    /// Maintains cols >= rows invariant.
    pub fn calculateDimensions(count: usize) struct { cols: usize, rows: usize } {
        if (count == 0) return .{ .cols = 1, .rows = 1 };
        if (count == 1) return .{ .cols = 1, .rows = 1 };
        if (count == 2) return .{ .cols = 2, .rows = 1 };
        // 3 terminals lay out as a single horizontal row (3x1) rather than a
        // 2x2 grid with an empty cell. The general search below caps cols at
        // rows+1, so it would pick 2x2 for count=3 — hence this explicit case.
        if (count == 3) return .{ .cols = 3, .rows = 1 };

        // Find smallest grid where cols >= rows and cols * rows >= count
        var rows: usize = 1;
        while (rows <= max_grid_size) : (rows += 1) {
            // Start with square, then try cols = rows + 1
            var cols = rows;
            while (cols <= max_grid_size and cols <= rows + 1) : (cols += 1) {
                if (cols * rows >= count) {
                    return .{ .cols = cols, .rows = rows };
                }
            }
        }

        return .{ .cols = max_grid_size, .rows = max_grid_size };
    }

    /// Returns the total capacity of the current grid.
    pub fn capacity(self: *const GridLayout) usize {
        return self.cols * self.rows;
    }

    /// Check if the grid needs to expand to fit one more terminal.
    pub fn needsExpansion(self: *const GridLayout, active_count: usize) bool {
        return active_count >= self.capacity();
    }

    /// Convert session index to grid position.
    pub fn indexToPosition(self: *const GridLayout, idx: usize) GridPosition {
        return GridPosition.fromIndex(idx, self.cols);
    }

    /// Start a grid resize animation.
    pub fn startResize(
        self: *GridLayout,
        new_cols: usize,
        new_rows: usize,
        now: i64,
        render_width: c_int,
        render_height: c_int,
        session_moves: []const SessionMove,
    ) !void {
        self.animations.clearRetainingCapacity();
        log.debug("start resize {d}x{d} -> {d}x{d} moves={d}", .{
            self.cols,
            self.rows,
            new_cols,
            new_rows,
            session_moves.len,
        });
        self.prev_cols = self.cols;
        self.prev_rows = self.rows;
        self.resize_start_time = now;

        // Calculate where each active session will move from/to
        const old_cell_w = @divFloor(render_width, @as(c_int, @intCast(self.cols)));
        const old_cell_h = @divFloor(render_height, @as(c_int, @intCast(self.rows)));
        const new_cell_w = @divFloor(render_width, @as(c_int, @intCast(new_cols)));
        const new_cell_h = @divFloor(render_height, @as(c_int, @intCast(new_rows)));

        for (session_moves) |move| {
            const new_pos = GridPosition.fromIndex(move.session_idx, new_cols);

            const target_rect = Rect{
                .x = @as(c_int, @intCast(new_pos.col)) * new_cell_w,
                .y = @as(c_int, @intCast(new_pos.row)) * new_cell_h,
                .w = new_cell_w,
                .h = new_cell_h,
            };

            const start_rect = if (move.old_index) |old_idx| blk: {
                const old_pos = GridPosition.fromIndex(old_idx, self.cols);
                break :blk Rect{
                    .x = @as(c_int, @intCast(old_pos.col)) * old_cell_w,
                    .y = @as(c_int, @intCast(old_pos.row)) * old_cell_h,
                    .w = old_cell_w,
                    .h = old_cell_h,
                };
            } else target_rect;

            try self.animations.append(self.allocator, .{
                .session_idx = move.session_idx,
                .start_rect = start_rect,
                .target_rect = target_rect,
                .start_time = now,
            });
        }

        self.cols = new_cols;
        self.rows = new_rows;
        self.is_resizing = true;
    }

    /// Update resize animation state. Returns true if animation is complete.
    pub fn updateResize(self: *GridLayout, now: i64) bool {
        if (!self.is_resizing) return true;

        const elapsed = now - self.resize_start_time;
        if (elapsed >= animation_duration_ms) {
            self.is_resizing = false;
            self.animations.clearRetainingCapacity();
            return true;
        }
        return false;
    }

    pub fn cancelResize(self: *GridLayout) void {
        log.debug("cancel resize {d}x{d} anims={d}", .{ self.cols, self.rows, self.animations.items.len });
        self.is_resizing = false;
        self.resize_start_time = 0;
        self.animations.clearRetainingCapacity();
    }

    /// Get the current animated rect for a session during resize.
    pub fn getAnimatedRect(
        self: *const GridLayout,
        session_idx: usize,
        now: i64,
    ) ?Rect {
        if (!self.is_resizing) return null;

        for (self.animations.items) |anim| {
            if (anim.session_idx == session_idx) {
                const elapsed = now - anim.start_time;
                const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, animation_duration_ms));
                // Gentle sine ease: large grid reflows move hundreds of px, and
                // cubic's 3x peak velocity made the middle frames teleport. Sine's
                // ~1.57x peak keeps per-frame motion small enough to read as a glide.
                const eased = easing.easeInOutSine(progress);
                return interpolateRect(anim.start_rect, anim.target_rect, eased);
            }
        }

        // Session wasn't in the animation list - it's a new cell
        return null;
    }

    fn interpolateRect(start: Rect, target: Rect, progress: f32) Rect {
        return Rect{
            .x = start.x + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.x - start.x)) * progress)),
            .y = start.y + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.y - start.y)) * progress)),
            .w = start.w + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.w - start.w)) * progress)),
            .h = start.h + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.h - start.h)) * progress)),
        };
    }
};

test "calculateDimensions" {
    // 0-1 terminals: 1x1
    try std.testing.expectEqual(@as(usize, 1), GridLayout.calculateDimensions(0).cols);
    try std.testing.expectEqual(@as(usize, 1), GridLayout.calculateDimensions(0).rows);
    try std.testing.expectEqual(@as(usize, 1), GridLayout.calculateDimensions(1).cols);
    try std.testing.expectEqual(@as(usize, 1), GridLayout.calculateDimensions(1).rows);

    // 2 terminals: 2x1
    try std.testing.expectEqual(@as(usize, 2), GridLayout.calculateDimensions(2).cols);
    try std.testing.expectEqual(@as(usize, 1), GridLayout.calculateDimensions(2).rows);

    // 3 terminals: 3x1 (single horizontal row)
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(3).cols);
    try std.testing.expectEqual(@as(usize, 1), GridLayout.calculateDimensions(3).rows);
    // 4 terminals: 2x2
    try std.testing.expectEqual(@as(usize, 2), GridLayout.calculateDimensions(4).cols);
    try std.testing.expectEqual(@as(usize, 2), GridLayout.calculateDimensions(4).rows);

    // 5-6 terminals: 3x2
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(5).cols);
    try std.testing.expectEqual(@as(usize, 2), GridLayout.calculateDimensions(5).rows);
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(6).cols);
    try std.testing.expectEqual(@as(usize, 2), GridLayout.calculateDimensions(6).rows);

    // 7-9 terminals: 3x3
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(7).cols);
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(7).rows);
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(9).cols);
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(9).rows);

    // 10-12 terminals: 4x3
    try std.testing.expectEqual(@as(usize, 4), GridLayout.calculateDimensions(10).cols);
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(10).rows);
    try std.testing.expectEqual(@as(usize, 4), GridLayout.calculateDimensions(12).cols);
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(12).rows);
}

test "GridPosition" {
    const pos = GridPosition{ .col = 2, .row = 1 };
    try std.testing.expectEqual(@as(usize, 5), pos.toIndex(3));

    const pos2 = GridPosition.fromIndex(5, 3);
    try std.testing.expectEqual(@as(usize, 2), pos2.col);
    try std.testing.expectEqual(@as(usize, 1), pos2.row);
}
