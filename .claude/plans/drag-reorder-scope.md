# Drag-to-Reorder Terminal Tiles — Scoping Plan (critique-corrected)

Produced 2026-09-20 by scoping workflow wf_f30f6b6d-f5b (4 Sonnet readers → Opus design → Sonnet critique verified all file:line claims). Corrections from the critique pass are merged inline.

## 1. Plain-English approach

Right now, "where a terminal appears in the grid" is not a number anyone stores. It's just *where the pointer sits in an array*. `sessions` is a list of terminal pointers, and the renderer computes a tile's position straight from its index (`row = i / cols`, `col = i % cols`). Whenever a terminal opens, closes, hides or reveals, `compactSessions` (`src/app/runtime.zig:574-656`) rebuilds that array: visible terminals to the front, hidden to the tail, and the visible block re-sorted by `spawn_seq` — a monotonic "you were created 5th" counter. So the grid is permanently sorted by creation time, and any manual shuffle of the array would be silently undone the next time a terminal closes.

To let the user drag tiles around, we change what the grid is sorted *by*: keep exactly one ordering key per session, keep `compactSessions` as the single sorter, and make a drag **renumber that key** rather than shuffle pointers. Like a playlist where every track has a track number: today the number is assigned automatically at import; we add the ability to renumber — the list is still always displayed "sorted by track number", so nothing else in the app learns a new concept.

The gesture lives entirely in the existing UI component layer (`SessionInteractionComponent`). Press-and-hold on a tile without moving much arms a reorder drag; once armed, the terminal is re-slotted live as the cursor crosses other tiles' center zones, with everything between old and new slot shifting one step (springboard semantics). Tiles slide via the animation machinery that already exists for grid reflow (`GridLayout.startResize`). Release commits; Escape or focus loss cancels. Every visible tile gets the same PTY size, so a pure permutation triggers **no PTY resize and no terminal reflow** (verified: `layout.calculateTerminalSizes` at `src/app/layout.zig:157-174` computes one uniform grid winsize; `applyTerminalResize` L198-261 yields identical targets under permutation).

## 2. Core data-model decision

- **(a) Reorder the physical `sessions` array, leave `spawn_seq` alone** — rejected: `compactSessions` re-sorts by `spawn_seq` on close/hide/reveal/startup (`runtime.zig:948, 2023, 2476, 3303`); arrangement silently snaps back on next close.
- **(b) Second field `display_order` + `spawn_seq` tiebreak** — rejected: two sources of truth, four code paths (spawn/despawn/restore/reveal) where the permutation invariant can break.
- **(c) RECOMMENDED: keep one key, renumber it on commit.** Walk the visible block in its new order and assign consecutive values from a fresh block above the `next_spawn_seq` high-water mark. Everything else keeps its meaning; persistence needs no new field.

**Rename `spawn_seq` → `order_seq`** in the same change (`src/session/state.zig:79, 105-111, 254-257, ~450`, comparator in `compactSessions`, tests, CLAUDE.md grid-order note) with a doc comment stating: display-order key, initialized from spawn order, mutable by reorder, NOT `id`/`persist_index`.

Renumber rule:
```
commitReorder(visible_block, from_slot, to_slot):
  permute the block (remove at from, insert at to)
  base = next_order_seq; next_order_seq += block.len
  for i, s in block: s.order_seq = base + i
```
Fresh contiguous block above high-water: no collision with mid-spawn terminals, hidden sessions untouched, next spawn still lands last.

**Hidden sessions:** reorder leaves their `order_seq` untouched. Reveal should mint a fresh `order_seq` (`next_order_seq++`) so a revealed terminal lands at the end instead of resurfacing mid-arrangement (one-line change near `runtime.zig:3303`). Behavior change — flagged as open question #1.

## 3. Drag state machine

Lives in `SessionInteractionComponent` (`src/ui/components/session_interaction.zig`) — that's where grid tile math, Cmd checks, and selection arming already are.

New component state (UI-layer only, nothing in session structs):
```zig
const ReorderDrag = struct {
    phase: enum { idle, pending, active } = .idle,
    origin_slot: usize = 0,
    current_slot: usize = 0,
    press_x: f32, press_y: f32,
    press_ms: u64 = 0,            // host.now_ms (ui/types.zig:62)
    order: []usize,               // live permutation: visible slot -> session idx
};
```
No existing press-timestamp or drag-slop state exists anywhere — both are new.

Transitions:
- **BUTTON_DOWN (grid, left):** Cmd+Click link resolution runs first, unchanged (L209-224). `clicks >= 2` → existing zoom path, unchanged (fires on down, feels instant). Otherwise record press, `phase = .pending`, arm selection as today — and **defer the single-click `SelectGridSession`/`FocusSession` to BUTTON_UP** (avoids select-then-reorder double effect).
- **Hold threshold:** `HOLD_MS = 220` AND travel `<= DRAG_SLOP = 6` render-px. Moving past slop before the hold elapses demotes to a normal text-selection drag permanently for that press. Evaluated on MOUSE_MOTION and in `update()` so a motionless hold promotes without a mouse event (extend the existing `update`/`wantsFrame` — they already exist at L692/L724 for scroll-inertia/wave; this is an extension, not new plumbing).
- **Promotion → .active:** clear armed selection (`endSelection`/`clearSelection` in `session_view_state.zig:54-58`) **plus explicitly `self.grid_selection_idx = null`** (separate field, L49, not covered by the helper — critique catch). Init `order` to identity. `first_frame.markTransition()`.
- **MOTION while .active:** compute pointer slot via **cheap col/row math extracted into a shared helper** (from the local `calculateHoveredSession` L1592-1617 / `sessionRectForIndex` L1619-1641 pattern) — do NOT use `gridViewHitFromMouse` here; it does full terminal-pin resolution walking ghostty-vt pages, wasted per-motion work (critique catch). Hysteresis: re-slot only when the pointer enters the inner 50%×50% centered box of a *different* tile — flicker-proof by construction, and directly implements "near the center". On re-slot: springboard move on `order`, kick the slide animation.
- **BUTTON_UP:** `.active` → queue `UiAction.ReorderGridSessions{order}`; `.pending` → this was a click: fire the deferred select now; `.idle` → unchanged.
- **Cancel:** Escape, window focus loss, or visible-session-count change mid-drag → restore identity, no action.

Gesture collisions:
- **Click-select:** moves to mouse-up for single clicks in grid view (double-click zoom stays on down). Perceptible but tiny latency change — open question #3.
- **Cmd+Click / Cmd+hover underline:** unchanged; additionally gate arming on Cmd not held.
- **Text selection:** the 6px slop escape. A deliberate >220ms motionless press then drag becomes a reorder — accepted iOS-like trade.
- **Mouse-tracking TUIs (vim/htop):** critique verified grid-view clicks **already never reach** mouse-tracking programs today (`forwardMouseToProgram` only in the `.Full` branch, L317/L380) — so the gesture introduces no new regression here. No bail-out needed; the pre-existing no-forwarding-in-grid gap is orthogonal. (Original plan's risk #2 was framed backwards.)

## 4. Slide animation + PTY

Reuse `GridLayout.startResize/updateResize/getAnimatedRect` (`src/app/grid_layout.zig:31-36, 120-178, 200-222`, `easeInOutSine`) — the tile-slide animator already exists; don't build a third rect interpolator. Each mid-drag re-slot emits `UiAction.PreviewReorder` (animation only, no renumber) that retargets `GridLayout`.

Two `GridLayout` changes — **note (critique): this is real surgery, not a one-liner.** `animation_duration_ms` is a `pub const` (L59) baked into `updateResize` (L185) and `getAnimatedRect` (L211); a shorter reorder duration (~140ms vs 300ms reflow) needs a per-animation or per-instance duration field threaded through both. Also seed `start_rect` from `getAnimatedRect(...) orelse current_rect` so rapid re-slots retarget from the interpolated position instead of snapping.

Idle-throttle contract: extend existing `wantsFrame` with `guard.wantsFrame() or phase == .pending or phase == .active`; `markTransition()` on phase flips and re-slots, `markDrawn()` at end of render. Tile motion itself rides the app-level `animating` flag via `anim_state.mode = .GridResizing` (existing polling at `runtime.zig:3659-3688`).

PTY resize: **not needed** for a pure permutation (verified, see §1) — provided focus indices are remapped. `anim_state.focused_session`/`previous_session` are raw indices, but since `applyReorder` delegates the array permutation to `compactSessions`, the by-id focus remap it already does (L580-587, 646-655) covers this **for free** — do not write redundant remap code (critique catch).

Visuals: no floating ghost (per user). Lift cue = slightly stronger border on the dragged tile via `gfx.primitives.drawThickBorder`. Thin in phase 1.

## 5. Files touched

| File | Change |
|---|---|
| `src/session/state.zig` | `spawn_seq` → `order_seq` rename + doc comment; optional `mintOrderSeqBlock(n)`. |
| `src/app/runtime.zig` | Comparator rename; `applyReorder` (validate permutation → renumber from fresh block → delegate to `compactSessions` → `persistence_dirty = true`); `UiAction.PreviewReorder`/`ReorderGridSessions` cases in `ui_action_loop` (~L3228); reveal mints fresh `order_seq` (~L3303). |
| `src/ui/types.zig` | Two new `UiAction` variants carrying a slot permutation; fixed-capacity inline array (grid is small/bounded) to avoid allocator lifetime questions in the queue. |
| `src/ui/components/session_interaction.zig` | Bulk of the work: `ReorderDrag` + constants; arming/deferral on DOWN; slop/promotion/hysteresis on MOTION; commit/deferred-click on UP; extend existing `update`/`wantsFrame`; Escape cancel; extract shared cheap col/row tile-math helper. |
| `src/app/grid_layout.zig` | Retargetable `startResize` (seed from animated rect); per-animation duration (const → field surgery). |
| `src/render/renderer.zig` | Lift cue for dragged tile only. |
| `src/main.zig` | Wire new test files into the `test {}` aggregator. **`grid_layout.zig` is confirmed absent today** (aggregator = L16-35 includes runtime/layout/session_interaction/types but not grid_layout); verify test-count delta with `--summary all`. |
| `docs/ARCHITECTURE.md`, `README.md`, `CLAUDE.md` | Gesture, rename, new UiActions; update the "Grid display order" invariant note. |

Invariants respected: all mutations via UiAction; no UI state in session structs (`order_seq` is data-model ordering read by `compactSessions`); FirstFrameGuard for new visible states; grid never ordered by `id`/`persist_index`.

## 6. Persistence across restart

Works nearly for free: `syncPersistenceTerminalEntriesFromSessions` (`runtime.zig:354-372`) writes entries in physical array order; restore (`runtime.zig:1863-1929`) spawns by file position, minting `order_seq` in that order. Since option (c) makes array order = user order immediately after commit, the next save persists it. **No new persistence field.** Set `persistence_dirty` in `applyReorder`.

Caveats: dead/never-spawned/empty-cwd sessions are skipped by the writer (saved order is a subsequence — fine, matches today); hidden order round-trips but reveal re-sorts (handled by fresh-`order_seq`-on-reveal); restore is macOS-only (`runtime.zig:1660`) so order doesn't survive restart elsewhere — not a regression, document it.

## 7. Risks, most dangerous first

1. **Parallel-array desync.** `compactSessions` swaps `sessions`/`views`/`render_cache.entries` in lockstep (+ index-keyed `hosting_flags`, `runtime.zig:2004-2005, 3195-3196`). `applyReorder` must NEVER permute arrays itself — renumber and delegate. This is the whole reason for option (c).
2. **Stale permutation across a session-set change.** Terminal dies/closes/reveals mid-drag → `order` indices describe a dead world. Validate length+contents in `applyReorder`; abort drag on visible-count change.
3. **Text-selection regression from the hold threshold.** Slow motionless-press selections in a plain shell become reorders. 6px slop + 220ms is the iOS-calibrated compromise; needs real-hands validation.
4. **Click-select latency change** (down → up). Correct design, but perceptible in a constantly-used tool. Grid-view single clicks only; double-click zoom stays on down.
5. **Rename fallout.** Mechanical but touches the invariant CLAUDE.md shouts about; docs must land in the same commit.
6. **Mid-flight retargeting.** Without seeding from the interpolated rect, rapid re-slots snap. Cosmetic but it's the feel of the whole feature. The duration-const surgery (§4) rides along.
7. **Test-aggregator gap.** `grid_layout.zig` confirmed unwired; `zig build test` also known to hang at run stage in this repo — verify with `--summary all` count delta + watchdog.

(Original risk "focus index desync" is absorbed by delegating to `compactSessions` — free. Original risk "stealing clicks from TUIs" was based on a mischaracterization — grid clicks never reach TUIs today.)

## 8. Phased implementation plan (by risk & dependency)

Each phase: commit (no push), stop for hands-on validation.

- **Phase 1 — Data model.** Rename `spawn_seq` → `order_seq`; `applyReorder` in runtime.zig (no UI wiring). Unit tests wired into the aggregator: springboard permutation math (no-op, both extremes), order survives unrelated close, focus follows session, hidden stay at tail, new spawn lands last. Carries risks 1, 5.
- **Phase 2 — Persistence round-trip.** Test-and-verify pass: reorder → save → restore → same arrangement. Implement + test reveal-gets-fresh-`order_seq`.
- **Phase 3 — Gesture, no animation.** Full `ReorderDrag` state machine; tiles teleport on re-slot (deliberately ugly — isolates gesture bugs from animation bugs). Unit tests for hold/slop predicate and hysteresis target-slot function as pure functions. Manual validation: click-select, double-click zoom, Cmd+Click, text selection, vim/htop. Carries risks 2, 3, 4.
- **Phase 4 — Slide animation.** GridLayout retargeting + duration field; `PreviewReorder`; wantsFrame/guard wiring. Manual: slow drag, fast drag, rapid boundary flutter, drag from idle. Carries risk 6. New grid_layout tests need aggregator wiring (risk 7).
- **Phase 5 — Polish & docs.** Lift cue, Escape/focus-loss cancel, ARCHITECTURE/README/CLAUDE.md, `zig build` + watched `zig build test` + `just lint`.

Out of scope: keyboard reorder, reorder in Full/zoomed view, dragging into the hidden set, multi-select drag.

## 9. Open questions

1. **Reveal placement:** revealed hidden terminal appears at the END (recommended, deterministic) vs. tries to reclaim its old spot (requires preserving hidden order, discarded today)?
2. **Hold threshold feel:** 220ms + 6px slop is the proposed calibration — tune during phase 3 hands-on, or is there a preference now?
3. **Click-select on release:** single-click tile selection fires on mouse-UP instead of DOWN (double-click zoom unchanged). Acceptable, or prefer select-on-down with a visible retract when a press becomes a drag?
