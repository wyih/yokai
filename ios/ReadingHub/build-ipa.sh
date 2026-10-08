#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
task_team="${READING_HUB_TEAM:-9FU69Y27YS}"
task_device="${READING_HUB_DEVICE:-00008150-001261301E42401C}"
mkdir -p "$task_root/build"
# Distribution builds do not retain the one-time migration capability.
unset HUB_MIGRATION_GROUP
python3 "$task_root/../Runtime/prepare.py" > "$task_root/build/runtime-prepare.log" 2>&1
python3 "$task_root/generate-project.py"
xcodebuild -project "$task_root/ReadingHub.xcodeproj" -scheme ReadingHub -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$task_root/build/DerivedData" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$task_team" build \
  > "$task_root/build/final-build.log" 2>&1
task_app="$task_root/build/DerivedData/Build/Products/Release-iphoneos/ReadingHub.app"
codesign --verify --deep --strict "$task_app"
task_stage="$task_root/build/package"
mkdir -p "$task_stage/Payload"
if [[ -d "$task_stage/Payload/ReadingHub.app" ]]; then rm -r "$task_stage/Payload/ReadingHub.app"; fi
ditto "$task_app" "$task_stage/Payload/ReadingHub.app"
ditto -c -k --keepParent "$task_stage/Payload" "$task_root/build/ReadingHub.ipa"
python3 - "$task_root/build/ReadingHub.ipa" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    assert archive.testzip() is None
PY
print -r -- "$task_root/build/ReadingHub.ipa"
if [[ "${1:-}" == "--install" ]]; then
  xcrun devicectl device install app --device "$task_device" "$task_app"
  xcrun devicectl device process launch --device "$task_device" com.wyih.qiyereader
fi
