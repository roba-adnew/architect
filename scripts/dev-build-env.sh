# Sourceable: set up the native (Homebrew SDL3 + macOS 15.4 SDK) build environment
# for the current worktree. The caller must ensure `zig` is already on PATH.
# Every value is only filled in if not already set, so this is a no-op inside a
# Nix dev shell that already provides them. Intended to be `source`d, not run.

if command -v brew >/dev/null 2>&1; then
    # build.zig reads *_INCLUDE_PATH and derives the lib dir (<include>/../lib).
    : "${SDL3_INCLUDE_PATH:=$(brew --prefix sdl3 2>/dev/null)/include}"
    : "${SDL3_TTF_INCLUDE_PATH:=$(brew --prefix sdl3_ttf 2>/dev/null)/include}"
    export SDL3_INCLUDE_PATH SDL3_TTF_INCLUDE_PATH
fi

# Zig 0.15.2 cannot link the macOS 26.x SDK (ziglang/zig#31756); redirect SDK
# discovery to the 15.4 SDK when present and DEVELOPER_DIR isn't already set.
_dbe_legacy_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$_dbe_legacy_sdk" ]; then
    _dbe_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    _dbe_wr="$_dbe_root/.tmp/macos-sdk-workaround"
    mkdir -p "$_dbe_wr/bin" "$_dbe_wr/developer/SDKs" "$_dbe_wr/developer/usr/bin"
    ln -sfn "$_dbe_legacy_sdk" "$_dbe_wr/developer/SDKs/MacOSX.sdk"
    cat > "$_dbe_wr/developer/usr/bin/xcrun" <<XCRUN
#!/bin/sh
if [ "\$1" = "--sdk" ] && [ "\$2" = "macosx" ] && [ "\$3" = "--show-sdk-path" ] && [ "\$#" -eq 3 ]; then
    printf '%s\n' '$_dbe_legacy_sdk'
    exit 0
fi
exec env DEVELOPER_DIR= /usr/bin/xcrun "\$@"
XCRUN
    chmod +x "$_dbe_wr/developer/usr/bin/xcrun"
    ln -sfn "$_dbe_wr/developer/usr/bin/xcrun" "$_dbe_wr/bin/xcrun"
    case ":$PATH:" in
        *":$_dbe_wr/bin:"*) ;;
        *) export PATH="$_dbe_wr/bin:$PATH" ;;
    esac
    export DEVELOPER_DIR="$_dbe_wr/developer"
fi
