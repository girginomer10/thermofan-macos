# shellcheck shell=bash
# Shared packaging contract. Source this file (do not execute it) from
# scripts/build_app.sh, scripts/release_direct.sh, and .github/workflows/ci.yml.
#
# It is the only code that reads packaging and XPC constants out of
# Sources/FanControlXPC/ThermoFanXPC.swift and the only definition of the
# legacy command-surface scans, so the build, the release, and CI cannot drift
# apart. A rename or reformat in the Swift source fails here, once, with one
# explicit message and exit status 64.

THERMOFAN_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THERMOFAN_XPC_SOURCE="$THERMOFAN_REPO_ROOT/Sources/FanControlXPC/ThermoFanXPC.swift"

# Legacy CLI/setuid command-surface tokens. Nothing is allow-listed.
THERMOFAN_LEGACY_COMMAND_SURFACE='--fanctl|--watch|THERMOFAN_WATCHDOG_READY|osascript'

# Prints the value of one `[public] static let|var NAME[: Type] = VALUE`
# declaration in ThermoFanXPC.swift, where VALUE is a decimal integer or a
# "string" literal. A trailing `// comment` is tolerated. Prints nothing when
# the declaration is absent or no longer has this single-line shape.
thermofan_swift_constant() {
  sed -nE "s/^[[:space:]]*(public[[:space:]]+)?static[[:space:]]+(let|var)[[:space:]]+$1([[:space:]]*:[[:space:]]*[A-Za-z]+)?[[:space:]]*=[[:space:]]*(\"([^\"]*)\"|([0-9]+))[[:space:]]*(\/\/.*)?\$/\5\6/p" \
    "$THERMOFAN_XPC_SOURCE"
}

thermofan_require_constant() {
  if [[ ! "$2" =~ $3 ]]; then
    echo "Could not read exactly one well-formed ThermoFanXPC.$1 from $THERMOFAN_XPC_SOURCE (found: '${2:-nothing}')." >&2
    echo "Keep it as a single-line \`public static let $1 = <value>\` declaration; a trailing // comment is fine." >&2
    exit 64
  fi
}

# Sets THERMOFAN_APP_IDENTIFIER, THERMOFAN_HELPER_IDENTIFIER,
# THERMOFAN_DAEMON_PLIST_NAME, and THERMOFAN_IMPLEMENTATION_REVISION from the
# Swift source. Exits 64 when any of them is empty, duplicated, or malformed.
thermofan_load_packaging_contract() {
  THERMOFAN_APP_IDENTIFIER="$(thermofan_swift_constant appIdentifier || true)"
  THERMOFAN_HELPER_IDENTIFIER="$(thermofan_swift_constant helperIdentifier || true)"
  THERMOFAN_DAEMON_PLIST_NAME="$(thermofan_swift_constant daemonPlistName || true)"
  THERMOFAN_IMPLEMENTATION_REVISION="$(thermofan_swift_constant implementationRevision || true)"

  thermofan_require_constant appIdentifier "$THERMOFAN_APP_IDENTIFIER" '^[A-Za-z0-9][A-Za-z0-9.-]*$'
  thermofan_require_constant helperIdentifier "$THERMOFAN_HELPER_IDENTIFIER" '^[A-Za-z0-9][A-Za-z0-9.-]*$'
  thermofan_require_constant daemonPlistName "$THERMOFAN_DAEMON_PLIST_NAME" '^[A-Za-z0-9][A-Za-z0-9.-]*\.plist$'
  thermofan_require_constant implementationRevision "$THERMOFAN_IMPLEMENTATION_REVISION" '^[1-9][0-9]*$'
}

# Fails when a legacy token appears anywhere in Sources/ or Helpers/. Swift
# string literals of up to 15 UTF-8 bytes are stored inline in instructions,
# so the binary `strings` scan below cannot see them; this scan can.
thermofan_scan_sources_for_legacy_command_surface() {
  local status=0
  grep -rnE -- "$THERMOFAN_LEGACY_COMMAND_SURFACE" \
    "$THERMOFAN_REPO_ROOT/Sources" "$THERMOFAN_REPO_ROOT/Helpers" >&2 || status=$?
  case "$status" in
    1) return 0 ;;
    0) echo "A legacy CLI/setuid command-surface string was found in the sources listed above." >&2 ;;
    *) echo "The source command-surface scan could not run (grep exit $status)." >&2 ;;
  esac
  return 1
}

# Fails when a built executable still contains a legacy token in any section
# other than __TEXT,__text.
thermofan_scan_binary_for_legacy_command_surface() {
  local binary_strings
  binary_strings="$(strings "$1")" || {
    echo "Could not read strings from $1." >&2
    return 1
  }
  if grep -Eq -- "$THERMOFAN_LEGACY_COMMAND_SURFACE" <<<"$binary_strings"; then
    echo "A legacy CLI/setuid command surface was found in $1." >&2
    return 1
  fi
}

# Fails when the arm64 Hardware Helper still embeds the Intel/T2 `FS!`
# force-mask key, which must never be an Apple Silicon fallback.
thermofan_require_helper_without_force_mask() {
  local helper_strings
  helper_strings="$(strings -n 3 "$1")" || {
    echo "Could not read strings from $1." >&2
    return 1
  }
  if grep -qx 'FS!' <<<"$helper_strings"; then
    echo "The arm64 Hardware Helper still contains the legacy FS! force-mask key: $1" >&2
    return 1
  fi
}
