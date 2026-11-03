#!/usr/bin/env bash
# Builds VOID from the command line and launches it.
# Full compiler output goes to build.log; only errors are printed here.
set -uo pipefail
cd "$(dirname "$0")"

# Use the full Xcode app even if xcode-select points at Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app "$HOME/Applications/Xcode.app"; do
    if [[ -d "$candidate/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  echo "Couldn't find Xcode.app in /Applications. Install Xcode from the App Store, open it once, then run ./build.sh again."
  exit 1
fi
echo "Using Xcode at: $DEVELOPER_DIR"

# Always regenerate the project so changes to project.yml take effect.
./setup.sh --no-open || exit 1

# Release (optimized) build: Debug makes MLX, Parakeet and the voice several times slower.
echo "Building VOID, optimized (the first Release build compiles everything and takes several minutes)..."
xcodebuild \
  -project VOID.xcodeproj \
  -scheme VOID \
  -configuration Release \
  -derivedDataPath build \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  build > build.log 2>&1

if grep -q "BUILD SUCCEEDED" build.log; then
  echo "Build succeeded. Launching VOID..."
  pkill -x VOID 2>/dev/null || true
  open build/Build/Products/Release/VOID.app
else
  echo "Build failed. Errors:"
  grep -E "error:|license" build.log | sort -u | head -40
  if grep -qi "license" build.log; then
    echo ""
    echo "Xcode's license isn't accepted yet. Run this once, then ./build.sh again:"
    echo "  sudo xcodebuild -license accept"
  fi
  echo "Full log: $(pwd)/build.log"
  exit 1
fi
