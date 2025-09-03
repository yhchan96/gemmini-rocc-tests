#!/usr/bin/env bash
set -e

# ------------------ Config / Flags ------------------
PROGRAM="my_test"
CONFIG="GemminiRocketConfig"
SPIKE_EXT="gemmini"   # <-- default so set -u won't complain

while [[ $# -gt 0 ]]; do
  case "$1" in
    --program)   PROGRAM="${2:-}"; shift 2 ;;
    --config)    CONFIG="${2:-}"; shift 2 ;;
    --spike-ext) SPIKE_EXT="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--program NAME] [--config CONFIG] [--spike-ext EXT]"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ------------------ Verify location ------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$SCRIPT_DIR")" != "bareMetalC" ]]; then
  echo "Error: run this from the 'bareMetalC' directory."; exit 1
fi

# ------------------ Source env.sh ------------------
# Chipyard root is 5 levels up from bareMetalC
CHIPYARD_DIR="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
if [[ ! -f "$CHIPYARD_DIR/env.sh" ]]; then
  echo "Error: env.sh not found at $CHIPYARD_DIR/env.sh"; exit 1
fi
echo "Sourcing: $CHIPYARD_DIR/env.sh"
set +u
# shellcheck disable=SC1090
source "$CHIPYARD_DIR/env.sh"
set -u

# ------------------ Paths ------------------
BAREMETAL_DIR="$SCRIPT_DIR"
TEST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"          # gemmini-rocc-tests
MAKEFILE="$BAREMETAL_DIR/Makefile"                # local Makefile (you showed)
TEMPLATE_FILE="$BAREMETAL_DIR/template.c"
TEST_FILE="$BAREMETAL_DIR/${PROGRAM}.c"
BUILD_SH="$TEST_DIR/build.sh"
BIN_DIR="$TEST_DIR/build/bareMetalC"
BIN_PATH="$BIN_DIR/${PROGRAM}-baremetal"

# ------------------ Step 1: ensure <prog>.c exists ------------------
if [[ -f "$TEST_FILE" ]]; then
  echo "$PROGRAM.c detected."
else
  echo "$PROGRAM.c not found. Creating..."
  if [[ -f "$TEMPLATE_FILE" ]]; then
    cp "$TEMPLATE_FILE" "$TEST_FILE"
  else
    cat > "$TEST_FILE" <<'EOF'
#include <stdio.h>
int main(void) {
  printf("Hello from Gemmini bareMetalC test.\n");
  return 0;
}
EOF
  fi
fi

# ------------------ Step 2: put program in `tests = \` block ------------------
TMP="$(mktemp)"
awk -v prog="$PROGRAM" '
  BEGIN { in_tests=0; inserted=0; found=0; }
  /^tests[[:space:]]*=[[:space:]]*\\[[:space:]]*$/ { in_tests=1; print; next }
  {
    if (in_tests) {
      # if already present in the tests block
      if ($0 ~ ("(^|[[:space:]])" prog "([[:space:]]|\\\\|$)")) found=1;
      # end of block: blank line or next var like tests_baremetal
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^tests_baremetal[[:space:]]*=/) {
        if (!found && !inserted) { print "    " prog " \\"; inserted=1 }
        in_tests=0; print; next
      }
      print; next
    }
    print
  }
' "$MAKEFILE" > "$TMP" && mv "$TMP" "$MAKEFILE"
echo "Ensured '${PROGRAM}' is listed in the tests block."

# ------------------ Step 3: build ------------------
if [[ ! -f "$BUILD_SH" ]]; then
  echo "Error: build.sh not found at $BUILD_SH"; exit 1
fi
echo "Building gemmini-rocc-tests…"
( cd "$TEST_DIR" && bash "$BUILD_SH" )

# ------------------ Step 4: run Spike ------------------
echo "Locating binary at: $BIN_PATH"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Error: binary not found: $BIN_PATH"; exit 1
fi
if ! command -v spike >/dev/null 2>&1; then
  echo "Error: 'spike' not found in PATH (check env.sh)."; exit 1
fi

echo "Running Spike with --extension=${SPIKE_EXT}…"
( cd "$BIN_DIR" && spike --extension="${SPIKE_EXT}" "${PROGRAM}-baremetal" )
