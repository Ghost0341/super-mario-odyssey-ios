#!/bin/sh
# Real macOS Foundation/CloudKit; only UIKit and CloudKit transport are fakes.
set -eu
cd "$(dirname "$0")"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/dm-cloud-coordinator.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
set --
if [ -n "${DM_CLOUD_TEST_SANITIZERS:-}" ]; then set -- "-fsanitize=$DM_CLOUD_TEST_SANITIZERS"; fi
xcrun clang "$@" -fobjc-arc -fblocks -g -O1 -Wno-deprecated-declarations -Wno-incompatible-pointer-types \
  -I . -I ../../Sources \
  -framework Foundation -framework CloudKit -framework CoreGraphics \
  t_cloud_coordinator.m UIKitShim.m ../../Sources/DmSaveArchive.m \
  -o "$build_dir/t_cloud_coordinator"
"$build_dir/t_cloud_coordinator"
