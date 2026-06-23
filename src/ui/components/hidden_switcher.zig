const std = @import("std");
const c = @import("../../c.zig");
const types = @import("../types.zig");
const component = @import("../component.zig");
const colors = @import("../../colors.zig");
const geom = @import("../../geom.zig");
const dpi = @import("../../dpi.zig");
const primitives = @import("../../gfx/primitives.zig");
const search_utils = @import("search_utils.zig");
const app_state = @import("../../app/app_state.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;

const log = std.log.scoped(.hidden_switcher);

/// Plenty for any realistic number of hidden terminals (grid caps well below this).
const max_entries = 64;

/// Modal picker listing hidden terminals (Cmd+J hides; this reveals). Opens on
/// Cmd+Shift+J, lists each hidden terminal as "folder — status", and reveals the
/// selected one via a RevealHiddenTerminal action.
///
/// ponytail: phase 1 is list + arrow-nav + reveal. Type-to-filter is the planned
/// follow-up; with only a handful of hidden terminals arrow-nav is enough to ship.
pub const HiddenSwitcherComponent = struct {
    allocator: std.mem.Allocator,
    open: bool = false,
    selected: usize = 0,
    first_frame: FirstFrameGuard = .{},

    pub const vtable = component.UiComponent.VTable{
        .handleEvent = handleEvent,
        .render = render,
        .wantsFrame = wantsFrame,
    };

    fn close(self: *HiddenSwitcherComponent) void {
        if (!self.open) return;
        self.open = false;
        // Force one frame so the scene under the modal redraws cleanly.
        self.first_frame.markTransition();
    }

    /// Collect indices of spawned-but-hidden sessions, in grid (index) order.
    fn collectHidden(sessions: []const types.SessionUiInfo, out: *[max_entries]usize) usize {
        var n: usize = 0;
        for (sessions, 0..) |info, i| {
            if (n >= max_entries) break;
            if (info.spawned and info.hidden) {
                out[n] = i;
                n += 1;
            }
        }
        return n;
    }

    fn handleEvent(ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, out: *types.UiActionQueue) bool {
        const self: *HiddenSwitcherComponent = @ptrCast(@alignCast(ptr));

        if (event.type != c.SDL_EVENT_KEY_DOWN) {
            // Stay modal: swallow text input while open (no terminal leakage).
            if (self.open and event.type == c.SDL_EVENT_TEXT_INPUT) return true;
            return false;
        }

        const key = event.key.key;
        const mod = event.key.mod;
        const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
        const has_blocking = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;
        const has_shift = (mod & c.SDL_KMOD_SHIFT) != 0;

        // Cmd+Shift+J toggles the switcher. When nothing is hidden we DON'T consume
        // it, so runtime's handler shows the "No hidden terminals" toast.
        if (has_gui and !has_blocking and has_shift and key == c.SDLK_J) {
            if (self.open) {
                self.close();
                return true;
            }
            var buf: [max_entries]usize = undefined;
            if (collectHidden(host.sessions, &buf) == 0) return false;
            self.open = true;
            self.selected = 0;
            self.first_frame.markTransition();
            return true;
        }

        if (!self.open) return false;

        var buf: [max_entries]usize = undefined;
        const n = collectHidden(host.sessions, &buf);
        if (n == 0) {
            self.close();
            return true;
        }
        const sel = @min(self.selected, n - 1);

        switch (key) {
            c.SDLK_ESCAPE => self.close(),
            c.SDLK_UP => self.selected = if (sel == 0) n - 1 else sel - 1,
            c.SDLK_DOWN => self.selected = if (sel + 1 >= n) 0 else sel + 1,
            c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                out.append(.{ .RevealHiddenTerminal = buf[sel] }) catch |err| {
                    log.warn("failed to queue reveal action: {}", .{err});
                };
                self.close();
            },
            else => {}, // swallow other keys to stay modal
        }
        return true;
    }

    fn statusLabel(status: app_state.SessionStatus) []const u8 {
        return switch (status) {
            .awaiting_approval => "needs you",
            .running => "working",
            .done => "done",
            .idle => "idle",
        };
    }

    fn statusColor(theme: *const colors.Theme, status: app_state.SessionStatus) c.SDL_Color {
        return switch (status) {
            .awaiting_approval => theme.palette[3], // yellow
            .running => theme.accent,
            .done => theme.palette[2], // green
            .idle => theme.foreground,
        };
    }

    fn render(ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *HiddenSwitcherComponent = @ptrCast(@alignCast(ptr));
        defer self.first_frame.markDrawn();
        if (!self.open) return;

        var buf: [max_entries]usize = undefined;
        const n = collectHidden(host.sessions, &buf);
        if (n == 0) {
            self.open = false;
            return;
        }
        const sel = @min(self.selected, n - 1);
        const font_cache = assets.font_cache orelse return;
        const theme = host.theme;
        const ui_scale = host.ui_scale;

        const pad = dpi.scale(16, ui_scale);
        const row_h = dpi.scale(34, ui_scale);
        const title_h = dpi.scale(26, ui_scale);
        const gap = dpi.scale(8, ui_scale);
        const radius = dpi.scale(10, ui_scale);

        const max_w = dpi.scale(460, ui_scale);
        const modal_w = @min(max_w, host.window_w - dpi.scale(80, ui_scale));
        const modal_h = pad + title_h + gap + @as(c_int, @intCast(n)) * row_h + pad;
        const modal_x = @divFloor(host.window_w - modal_w, 2);
        const modal_y = @divFloor(host.window_h - modal_h, 3); // upper third reads better than dead-center

        // Dim the scene behind the modal.
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 120);
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(host.window_w),
            .h = @floatFromInt(host.window_h),
        });

        const modal = geom.Rect{ .x = modal_x, .y = modal_y, .w = modal_w, .h = modal_h };
        _ = c.SDL_SetRenderDrawColor(renderer, theme.selection.r, theme.selection.g, theme.selection.b, 245);
        primitives.fillRoundedRect(renderer, modal, radius);
        _ = c.SDL_SetRenderDrawColor(renderer, theme.accent.r, theme.accent.g, theme.accent.b, 230);
        primitives.drawRoundedBorder(renderer, modal, radius);

        const title_fonts = font_cache.get(dpi.scale(18, ui_scale)) catch return;
        drawText(self.allocator, renderer, title_fonts.regular, "Hidden terminals", theme.foreground, modal_x + pad, modal_y + pad + @divFloor(title_h, 2));

        const row_fonts = font_cache.get(dpi.scale(16, ui_scale)) catch return;
        const rows_y0 = modal_y + pad + title_h + gap;
        for (0..n) |i| {
            const gi = buf[i];
            const info = host.sessions[gi];
            const row_y = rows_y0 + @as(c_int, @intCast(i)) * row_h;
            const row_center = row_y + @divFloor(row_h, 2);

            if (i == sel) {
                const hl = geom.Rect{ .x = modal_x + gap, .y = row_y, .w = modal_w - 2 * gap, .h = row_h };
                _ = c.SDL_SetRenderDrawColor(renderer, theme.accent.r, theme.accent.g, theme.accent.b, 60);
                primitives.fillRoundedRect(renderer, hl, dpi.scale(6, ui_scale));
            }

            const basename = blk: {
                const b = info.cwd_basename orelse "~";
                break :blk if (b.len == 0) "/" else b;
            };
            drawText(self.allocator, renderer, row_fonts.regular, basename, theme.foreground, modal_x + pad + gap, row_center);

            const label = statusLabel(info.session_status);
            const label_color = statusColor(theme, info.session_status);
            drawTextRight(self.allocator, renderer, row_fonts.regular, label, label_color, modal_x + modal_w - pad - gap, row_center);
        }
    }

    fn wantsFrame(ptr: *anyopaque, host: *const types.UiHost) bool {
        _ = host;
        const self: *HiddenSwitcherComponent = @ptrCast(@alignCast(ptr));
        return self.open or self.first_frame.wantsFrame();
    }
};

/// Build a one-shot texture for `text` and blit it left-aligned at x, vertically
/// centered on center_y.
/// ponytail: rebuilt every frame the modal is open; it's a short list shown
/// briefly, so a glyph-texture cache isn't worth it yet.
fn drawText(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer, font: *c.TTF_Font, text: []const u8, color: c.SDL_Color, x: c_int, center_y: c_int) void {
    if (text.len == 0) return;
    const tex = search_utils.makeTextTexture(allocator, renderer, font, text, color) catch return;
    defer c.SDL_DestroyTexture(tex.tex);
    _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
        .x = @floatFromInt(x),
        .y = @floatFromInt(center_y - @divFloor(tex.h, 2)),
        .w = @floatFromInt(tex.w),
        .h = @floatFromInt(tex.h),
    });
}

/// Same as drawText but right-aligned to `right_x`.
fn drawTextRight(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer, font: *c.TTF_Font, text: []const u8, color: c.SDL_Color, right_x: c_int, center_y: c_int) void {
    if (text.len == 0) return;
    const tex = search_utils.makeTextTexture(allocator, renderer, font, text, color) catch return;
    defer c.SDL_DestroyTexture(tex.tex);
    _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
        .x = @floatFromInt(right_x - tex.w),
        .y = @floatFromInt(center_y - @divFloor(tex.h, 2)),
        .w = @floatFromInt(tex.w),
        .h = @floatFromInt(tex.h),
    });
}

// --- Tests ---

test "collectHidden picks only spawned+hidden, preserving index order" {
    const sessions = [_]types.SessionUiInfo{
        .{ .dead = false, .spawned = true, .hidden = false }, // 0: visible
        .{ .dead = false, .spawned = true, .hidden = true }, // 1: hidden
        .{ .dead = false, .spawned = false, .hidden = true }, // 2: not spawned -> skip
        .{ .dead = false, .spawned = true, .hidden = true }, // 3: hidden
    };
    var buf: [max_entries]usize = undefined;
    const n = HiddenSwitcherComponent.collectHidden(&sessions, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 1), buf[0]);
    try std.testing.expectEqual(@as(usize, 3), buf[1]);
}

test "collectHidden returns 0 when nothing is hidden" {
    const sessions = [_]types.SessionUiInfo{
        .{ .dead = false, .spawned = true, .hidden = false },
        .{ .dead = false, .spawned = false, .hidden = false },
    };
    var buf: [max_entries]usize = undefined;
    try std.testing.expectEqual(@as(usize, 0), HiddenSwitcherComponent.collectHidden(&sessions, &buf));
}

test "statusLabel covers every status" {
    try std.testing.expectEqualStrings("needs you", HiddenSwitcherComponent.statusLabel(.awaiting_approval));
    try std.testing.expectEqualStrings("working", HiddenSwitcherComponent.statusLabel(.running));
    try std.testing.expectEqualStrings("done", HiddenSwitcherComponent.statusLabel(.done));
    try std.testing.expectEqualStrings("idle", HiddenSwitcherComponent.statusLabel(.idle));
}
