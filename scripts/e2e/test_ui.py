"""E2E UI scenarios for Architect.

Run:  python3 scripts/e2e/test_ui.py
Needs a built binary (`zig build`) and a logged-in macOS GUI session — each test
launches a real window and drives it with OS input, so it briefly takes focus.
"""

import sys

from harness import Architect, CMD


def _spawned(state):
    return sum(1 for s in state["sessions"] if s["spawned"])


def test_startup_writes_state():
    """The probe reports a sane initial state: session 0 spawned and focused."""
    with Architect() as app:
        s = app.wait_for(lambda s: _spawned(s) >= 1, what="session 0 to spawn")
        assert s["focused_session"] == 0, s
        assert s["sessions"][0]["spawned"] and not s["sessions"][0]["dead"], s
        return f"mode={s['mode']} focused_session=0 spawned={_spawned(s)}"


def test_cmd_esc_enters_grid():
    """Cmd+N adds a pane; Cmd+Esc collapses to grid view."""
    with Architect() as app:
        app.wait_for(lambda s: _spawned(s) >= 1, what="initial pane")
        app.key("n", CMD)
        app.wait_for(lambda s: _spawned(s) >= 2, what="second pane to spawn")
        app.key("esc", CMD)
        s = app.wait_for(lambda s: s["mode"] == "Grid", what="grid mode after Cmd+Esc")
        return f"panes={_spawned(s)} mode={s['mode']}"


def test_grid_click_moves_focus():
    """Single-clicking a grid pane moves keyboard focus to it (the bug we hit)."""
    with Architect() as app:
        app.wait_for(lambda s: _spawned(s) >= 1, what="initial pane")
        app.key("n", CMD)
        app.wait_for(lambda s: _spawned(s) >= 2, what="2 panes")
        app.key("esc", CMD)
        app.wait_for(lambda s: s["mode"] == "Grid", what="grid mode")

        cx, cy = app.grid_cell_center(1)
        app.click(cx, cy)
        app.wait_for(lambda s: s["focused_session"] == 1, what="click pane 1 -> focus pane 1")

        cx, cy = app.grid_cell_center(0)
        app.click(cx, cy)
        app.wait_for(lambda s: s["focused_session"] == 0, what="click pane 0 -> focus pane 0")
        return "click moves grid focus (1 -> 0)"


def test_cmd_return_expands_to_full():
    """From grid, Cmd+Return expands the focused pane back to full view."""
    with Architect() as app:
        app.wait_for(lambda s: _spawned(s) >= 1, what="initial pane")
        app.key("n", CMD)
        app.wait_for(lambda s: _spawned(s) >= 2, what="2 panes")
        app.key("esc", CMD)
        app.wait_for(lambda s: s["mode"] == "Grid", what="grid mode")
        app.key("return", CMD)
        s = app.wait_for(lambda s: s["mode"] == "Full", what="full mode after Cmd+Return")
        return f"mode={s['mode']}"


TESTS = [
    test_startup_writes_state,
    test_cmd_esc_enters_grid,
    test_grid_click_moves_focus,
    test_cmd_return_expands_to_full,
]


def main():
    only = sys.argv[1:] if len(sys.argv) > 1 else None
    tests = [t for t in TESTS if not only or t.__name__ in only]
    passed, failed = 0, 0
    for t in tests:
        try:
            msg = t()
            print(f"PASS  {t.__name__}: {msg}")
            passed += 1
        except Exception as e:
            print(f"FAIL  {t.__name__}: {e}")
            failed += 1
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
