#!/usr/bin/env bash
set -e

echo "Gemmini Test Setup - Use -h or --help for usage information"

# ------------------ Config / Flags ------------------
PROGRAM="my_test"
SWITCH_CONFIG=""  # empty means no config switch
SPIKE_EXT="gemmini"   # <-- default so set -u won't complain
TEST_FOLDER=""  # auto-detect test folder
CHECK_CONFIGS_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --program)   PROGRAM="${2:-}"; shift 2 ;;
    --swconfig)  SWITCH_CONFIG="${2:-}"; shift 2 ;;
    --spike-ext) SPIKE_EXT="${2:-}"; shift 2 ;;
    --check-configs)
      CHECK_CONFIGS_ONLY=1
      shift ;;
    -h|--help)
      echo "Usage: $0 [--program NAME] [--swconfig CONFIG] [--spike-ext EXT] [--check-configs]"
      echo "  --program:       Test program name (default: my_test)"
      echo "  --swconfig:      Switch Gemmini configuration before running"
      echo "  --spike-ext:     Spike extension to use (default: gemmini)"
      echo "  --check-configs: List all available Chipyard configurations and exit"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ------------------ Verify location ------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$SCRIPT_DIR")" != "gemmini-rocc-tests" ]]; then
  echo "Error: run this from the 'gemmini-rocc-tests' directory."; exit 1
fi

# ------------------ Source env.sh ------------------
# Chipyard root is 4 levels up from gemmini-rocc-tests
CHIPYARD_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
if [[ ! -f "$CHIPYARD_DIR/env.sh" ]]; then
  echo "Error: env.sh not found at $CHIPYARD_DIR/env.sh"; exit 1
fi
echo "Sourcing: $CHIPYARD_DIR/env.sh"
set +u
# shellcheck disable=SC1090
source "$CHIPYARD_DIR/env.sh"
set -u

# ------------------ Check configs only and exit ------------------
if [[ "$CHECK_CONFIGS_ONLY" == "1" ]]; then
  echo "Available Chipyard configurations:"
  ( cd "$CHIPYARD_DIR" && sbt "project chipyard; runMain chipyard.ChipyardConfigFinder" )
  exit 0
fi

# ------------------ Handle config switching ------------------
if [[ -n "$SWITCH_CONFIG" ]]; then
  echo "Switching to configuration: $SWITCH_CONFIG"
  
  # Step 1: Build the configuration in verilator
  VERILATOR_DIR="$CHIPYARD_DIR/sims/verilator"
  if [[ ! -d "$VERILATOR_DIR" ]]; then
    echo "Error: Verilator directory not found at $VERILATOR_DIR"; exit 1
  fi
  
  echo "Building configuration in verilator..."
  ( cd "$VERILATOR_DIR" && make clean && make CONFIG="$SWITCH_CONFIG" )
  
  # Step 2: Copy updated gemmini_params.h from rocc-tests to libgemmini
  PARAMS_SRC="$SCRIPT_DIR/include/gemmini_params.h"
  PARAMS_DST="$CHIPYARD_DIR/generators/gemmini/software/libgemmini/gemmini_params.h"
  LIBGEMMINI_DIR="$CHIPYARD_DIR/generators/gemmini/software/libgemmini"
  
  if [[ ! -f "$PARAMS_SRC" ]]; then
    echo "Error: Source gemmini_params.h not found at $PARAMS_SRC"; exit 1
  fi
  
  if [[ ! -d "$LIBGEMMINI_DIR" ]]; then
    echo "Error: libgemmini directory not found at $LIBGEMMINI_DIR"; exit 1
  fi
  
  echo "Copying updated gemmini_params.h to libgemmini..."
  cp "$PARAMS_SRC" "$PARAMS_DST"
  
  # Step 3: Rebuild libgemmini
  echo "Rebuilding libgemmini..."
  ( cd "$LIBGEMMINI_DIR" && make clean && make && make install )
  
  echo "Configuration switch completed successfully!"
  exit 0
fi

# ------------------ Auto-detect or set test folder ------------------
if [[ -z "$TEST_FOLDER" ]]; then
  # Auto-detect: check if program exists in known folders
  if [[ -f "$SCRIPT_DIR/transformers/${PROGRAM}.c" ]]; then
    TEST_FOLDER="transformers"
  elif [[ -f "$SCRIPT_DIR/mlps/${PROGRAM}.c" ]]; then
    TEST_FOLDER="mlps"
  elif [[ -f "$SCRIPT_DIR/imagenet/${PROGRAM}.c" ]]; then
    TEST_FOLDER="imagenet"
  else
    TEST_FOLDER="bareMetalC"  # default
  fi
fi

# ------------------ Paths ------------------
TEST_SUBDIR="$SCRIPT_DIR/$TEST_FOLDER"
TEST_DIR="$SCRIPT_DIR"          # gemmini-rocc-tests
MAKEFILE="$TEST_SUBDIR/Makefile"
TEST_FILE="$TEST_SUBDIR/${PROGRAM}.c"
BUILD_SH="$TEST_DIR/build.sh"
BIN_DIR="$TEST_DIR/build/$TEST_FOLDER"
BIN_PATH="$BIN_DIR/${PROGRAM}-baremetal"

# ------------------ Step 1: ensure <prog>.c exists ------------------
if [[ -f "$TEST_FILE" ]]; then
  echo "$PROGRAM.c detected in $TEST_FOLDER folder."
else
  echo "Error: $PROGRAM.c not found in $TEST_FOLDER folder."
  echo "Ensure the program name is correct and the file exists in the bareMetalC folder. If not, create it manually."
  echo "Available test folders and their programs:"
  echo " - bareMetalC/ - Basic Gemmini C tests"
  echo " - transformers/ - Transformer attention tests"  
  echo " - mlps/ - Multi-layer perceptron tests"
  echo " - imagenet/ - Large neural network tests"
  exit 1
fi

# ------------------ Step 2: put program in `tests = \` block (only for bareMetalC) ------------------
if [[ "$TEST_FOLDER" == "bareMetalC" ]]; then
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
  echo "Ensured '${PROGRAM}' is listed in the bareMetalC tests block."
else
  echo "Using existing test '${PROGRAM}' in $TEST_FOLDER folder."
fi

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
