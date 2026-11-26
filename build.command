#!/bin/zsh
set -eu

cd "${0:A:h}"
build_dir=$(mktemp -d "$PWD/.launchos-build.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

app="$build_dir/LaunchOS.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/LaunchOS.icns "$app/Contents/Resources/LaunchOS.icns"

swiftc -O -target arm64-apple-macos26.0 \
  -module-cache-path "${TMPDIR:-/tmp}/launchos-modules" \
  main.swift -o "$app/Contents/MacOS/LaunchOS"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

if [[ -d LaunchOS.app ]]; then
  mv LaunchOS.app "$build_dir/previous.app"
fi
if ! mv "$app" LaunchOS.app; then
  if [[ -d "$build_dir/previous.app" ]]; then
    mv "$build_dir/previous.app" LaunchOS.app
  fi
  exit 1
fi
