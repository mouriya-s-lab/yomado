#!/bin/bash
set -euo pipefail

ym_root="$(cd "$(dirname "$0")" && pwd -P)"
ym_dist="${YOMADO_OUTPUT_DIR:-$ym_root/dist}"
ym_output="$ym_dist/Yomado.app"
ym_icon="$ym_root/app/Resources/Yomado.icns"
ym_signing_identity="${YOMADO_SIGNING_IDENTITY:-}"
ym_signing_flags=(--force --sign -)

# Local builds stay ad hoc signed. Distribution signing must be explicit;
# never select a keychain identity or change its trust settings automatically.
if [ -n "$ym_signing_identity" ]; then
  if [ "$ym_signing_identity" = "-" ]; then
    printf 'For an ad hoc build, leave YOMADO_SIGNING_IDENTITY unset.\n' >&2
    exit 1
  fi
  ym_signing_flags=(--force --sign "$ym_signing_identity" --options runtime --timestamp)
fi

ym_verify_signature() {
  /usr/bin/codesign --verify --strict "$1"
  if [ -n "$ym_signing_identity" ]; then
    local ym_signature
    ym_signature="$(/usr/bin/codesign --display --verbose=4 "$1" 2>&1)"
    case "$ym_signature" in
      *"Authority=Developer ID Application:"*) ;;
      *) printf 'Distribution signing requires a Developer ID Application certificate.\n' >&2; return 1 ;;
    esac
    case "$ym_signature" in
      *"Timestamp="*) ;;
      *) printf 'Distribution signature is missing a secure timestamp.\n' >&2; return 1 ;;
    esac
    case "$ym_signature" in
      *"(runtime)"*) ;;
      *) printf 'Distribution signature is missing the hardened runtime.\n' >&2; return 1 ;;
    esac
  fi
}

if [ ! -s "$ym_icon" ]; then
  printf 'Missing required app icon: app/Resources/Yomado.icns\n' >&2
  exit 1
fi

if [ "${YOMADO_DEVELOPER_DIR:-}" != "" ]; then
  ym_clang="$(DEVELOPER_DIR="$YOMADO_DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx --find clang)"
  ym_sdk="$(DEVELOPER_DIR="$YOMADO_DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx --show-sdk-path)"
else
  ym_clang="$(/usr/bin/xcrun --sdk macosx --find clang)"
  ym_sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
fi

ym_stage="$(mktemp -d "${TMPDIR:-/tmp}/Yomado-build.XXXXXX")"
trap 'rm -rf "$ym_stage"' EXIT
ym_bundle="$ym_stage/Yomado.app"
mkdir -p "$ym_bundle/Contents/MacOS" "$ym_bundle/Contents/Resources"

ym_flags=(
  -fobjc-arc -Wall -Wextra -Werror -g0
  -isysroot "$ym_sdk" -mmacosx-version-min=14.0
  "-ffile-prefix-map=$ym_root=."
  "-fmacro-prefix-map=$ym_root=."
  "-fdebug-prefix-map=$ym_root=."
  "-ffile-prefix-map=$ym_stage=."
  "-fmacro-prefix-map=$ym_stage=."
  "-fdebug-prefix-map=$ym_stage=."
)

"$ym_clang" "${ym_flags[@]}" -I "$ym_root/bridge" -I "$ym_root/fork-features/control" -I "$ym_root/fork-features/agent" \
  "$ym_root/app/Yomado.m" "$ym_root/app/ControlUI.m" "$ym_root/app/WindowRecovery.m" \
  "$ym_root/app/UpdateChecker.m" "$ym_root/app/MenuBarIcon.m" "$ym_root/app/PanelPresentation.m" \
  "$ym_root/app/AppWorkspace.m" "$ym_root/app/AppWorkspaceView.m" "$ym_root/bridge/VDVirtualDisplay.m" \
  "$ym_root/bridge/YMDisplayTopology.m" "$ym_root/fork-features/control/YMControl.m" \
  "$ym_root/fork-features/agent/YMAgentClient.m" \
  -framework AppKit -framework CoreGraphics -framework ColorSync -framework IOKit -framework Carbon -framework ApplicationServices -framework QuartzCore \
  -o "$ym_bundle/Contents/MacOS/Yomado"

# Fork feature: agent sessions (fork-features/agent). The helper is a nested bundle
# with its own identifier so LaunchServices never treats it as Yomado itself.
ym_agent="$ym_bundle/Contents/Helpers/YomadoAgent.app"
mkdir -p "$ym_agent/Contents/MacOS"
"$ym_clang" "${ym_flags[@]}" -I "$ym_root/fork-features/control" -I "$ym_root/fork-features/agent" \
  "$ym_root/fork-features/agent/YomadoAgent.m" "$ym_root/fork-features/control/YMControl.m" \
  -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit -framework CoreGraphics \
  -framework ImageIO -framework UniformTypeIdentifiers \
  -o "$ym_agent/Contents/MacOS/YomadoAgent"
/bin/cp -X "$ym_root/fork-features/agent/Info.plist" "$ym_agent/Contents/Info.plist"
mkdir -p "$ym_bundle/Contents/Resources/agent"
/bin/cp -X "$ym_root/fork-features/agent/client/yomado.ts" "$ym_root/fork-features/agent/client/yomado.py" \
  "$ym_bundle/Contents/Resources/agent/"

"$ym_clang" "${ym_flags[@]}" "$ym_root/app/Watchdog.m" \
  -framework Foundation -framework CoreGraphics \
  -o "$ym_bundle/Contents/MacOS/YomadoWatchdog"

/bin/cp -X "$ym_root/Info.plist" "$ym_bundle/Contents/Info.plist"
/bin/cp -X "$ym_icon" "$ym_bundle/Contents/Resources/Yomado.icns"
/usr/bin/xattr -cr "$ym_bundle"
/usr/bin/codesign "${ym_signing_flags[@]}" "$ym_bundle/Contents/MacOS/YomadoWatchdog"
/usr/bin/codesign "${ym_signing_flags[@]}" "$ym_agent"
/usr/bin/codesign "${ym_signing_flags[@]}" "$ym_bundle"
ym_verify_signature "$ym_bundle/Contents/MacOS/YomadoWatchdog"
ym_verify_signature "$ym_agent"
ym_verify_signature "$ym_bundle"

# Only generated artifacts in the selected output directory are replaced.
# Do not point YOMADO_OUTPUT_DIR at an installed or running app's directory.
# Archive the verified staged bundle before destination metadata can be added.
mkdir -p "$ym_dist"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent \
  "$ym_bundle" "$ym_stage/Yomado.zip"
rm -rf "$ym_output"
/usr/bin/ditto --norsrc --noextattr "$ym_bundle" "$ym_output"
/bin/mv -f "$ym_stage/Yomado.zip" "$ym_dist/Yomado.zip"
printf 'Built: %s\nArchive: %s\n' "$ym_output" "$ym_dist/Yomado.zip"
