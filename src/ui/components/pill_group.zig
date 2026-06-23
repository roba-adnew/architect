const std = @import("std");
const c = @import("../../c.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const HelpOverlayComponent = @import("help_overlay.zig").HelpOverlayComponent;
const WorktreeOverlayComponent = @import("worktree_overlay.zig").WorktreeOverlayComponent;
const RecentFoldersOverlayComponent = @import("recent_folders_overlay.zig").RecentFoldersOverlayComponent;
const HiddenIndicatorComponent = @import("hidden_indicator.zig").HiddenIndicatorComponent;

const ExpandingOverlay = @import("expanding_overlay.zig").ExpandingOverlay;

pub const PillGroupComponent = struct {
    allocator: std.mem.Allocator,
    help: *HelpOverlayComponent,
    recent_folders: *RecentFoldersOverlayComponent,
    worktree: *WorktreeOverlayComponent,
    hidden_indicator: *HiddenIndicatorComponent,
    last_help_state: ExpandingOverlay.State = .Closed,
    last_recent_folders_state: ExpandingOverlay.State = .Closed,
    last_worktree_state: ExpandingOverlay.State = .Closed,

    pub fn create(
        allocator: std.mem.Allocator,
        help: *HelpOverlayComponent,
        recent_folders: *RecentFoldersOverlayComponent,
        worktree: *WorktreeOverlayComponent,
        hidden_indicator: *HiddenIndicatorComponent,
    ) !UiComponent {
        const comp = try allocator.create(PillGroupComponent);
        comp.* = .{
            .allocator = allocator,
            .help = help,
            .recent_folders = recent_folders,
            .worktree = worktree,
            .hidden_indicator = hidden_indicator,
        };

        return UiComponent{
            .ptr = comp,
            .vtable = &vtable,
            .z_index = 999,
        };
    }

    fn deinit(self_ptr: *anyopaque, _: *c.SDL_Renderer) void {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        self.allocator.destroy(self);
    }

    fn handleEvent(_: *anyopaque, _: *const types.UiHost, _: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        return false;
    }

    fn hitTest(_: *anyopaque, _: *const types.UiHost, _: c_int, _: c_int) bool {
        return false;
    }

    fn hiddenCount(host: *const types.UiHost) usize {
        var n: usize = 0;
        for (host.sessions) |info| {
            if (info.spawned and info.hidden) n += 1;
        }
        return n;
    }

    /// Pack the visible pills into consecutive slots (slot 0 = rightmost) so a
    /// hidden pill never leaves a gap. Each pill is conditionally shown — recent
    /// folders only with history, worktree only on-git, the hidden indicator only
    /// when something is hidden — and help is always present. Order right→left:
    /// help, recent folders, worktree, hidden indicator.
    fn assignSlots(self: *PillGroupComponent, host: *const types.UiHost) void {
        var slot: usize = 0;
        self.help.overlay.slot = slot; // always visible
        slot += 1;
        if (self.recent_folders.all_folders.items.len > 0) {
            self.recent_folders.overlay.slot = slot;
            slot += 1;
        }
        if (self.worktree.available or self.worktree.creating or self.worktree.confirming_removal) {
            self.worktree.overlay.slot = slot;
            slot += 1;
        }
        if (hiddenCount(host) > 0) {
            self.hidden_indicator.overlay.slot = slot;
            slot += 1;
        }
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        self.assignSlots(host);

        const help_state = self.help.overlay.state;
        const recent_folders_state = self.recent_folders.overlay.state;
        const worktree_state = self.worktree.overlay.state;

        const help_started_expanding = self.last_help_state != .Expanding and help_state == .Expanding;
        const recent_folders_started_expanding = self.last_recent_folders_state != .Expanding and recent_folders_state == .Expanding;
        const worktree_started_expanding = self.last_worktree_state != .Expanding and worktree_state == .Expanding;

        // When one overlay starts expanding, collapse the others
        if (help_started_expanding) {
            if (recent_folders_state == .Open or recent_folders_state == .Expanding) {
                self.recent_folders.overlay.startCollapsing(host.now_ms);
            }
            if (worktree_state == .Open or worktree_state == .Expanding) {
                self.worktree.overlay.startCollapsing(host.now_ms);
            }
        }

        if (recent_folders_started_expanding) {
            if (help_state == .Open or help_state == .Expanding) {
                self.help.overlay.startCollapsing(host.now_ms);
            }
            if (worktree_state == .Open or worktree_state == .Expanding) {
                self.worktree.overlay.startCollapsing(host.now_ms);
            }
        }

        if (worktree_started_expanding) {
            if (help_state == .Open or help_state == .Expanding) {
                self.help.overlay.startCollapsing(host.now_ms);
            }
            if (recent_folders_state == .Open or recent_folders_state == .Expanding) {
                self.recent_folders.overlay.startCollapsing(host.now_ms);
            }
        }

        self.last_help_state = help_state;
        self.last_recent_folders_state = recent_folders_state;
        self.last_worktree_state = worktree_state;
    }

    fn render(_: *anyopaque, _: *const types.UiHost, _: *c.SDL_Renderer, _: *types.UiAssets) void {}

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        deinit(self_ptr, renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .hitTest = hitTest,
        .update = update,
        .render = render,
        .deinit = deinitComp,
    };
};
