#!/usr/bin/env bash
# Generates VOID.xcodeproj from project.yml. Safe to run again any time.
set -euo pipefail
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

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing XcodeGen with Homebrew..."
    brew install xcodegen
  else
    echo "XcodeGen is missing and Homebrew isn't installed."
    echo "Install Homebrew from https://brew.sh, then run ./setup.sh again."
    exit 1
  fi
fi

# Xcode 26+ ships the Metal toolchain as a separate download; MLX needs it.
xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1 || true

xcodegen generate
echo "VOID.xcodeproj is ready."

if [[ "${1:-}" != "--no-open" ]]; then
  open VOID.xcodeproj
fi
