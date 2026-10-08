#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
task_device="${YOKAI_DEVICE:-00008150-001261301E42401C}"
task_team="${YOKAI_TEAM:-9FU69Y27YS}"
task_destination="${YOKAI_DESTINATION:-generic/platform=iOS}"
mkdir -p "$task_root/build"
python3 "$task_root/Runtime/prepare.py" > "$task_root/build/runtime-prepare.log" 2>&1
xcodebuild -project "$task_root/Yokai.xcodeproj" -scheme Yokai -configuration Release \
  -destination "$task_destination" -derivedDataPath "$task_root/.derivedData" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM="$task_team" build \
  > "$task_root/build/device-build.log" 2>&1
task_app="$task_root/.derivedData/Build/Products/Release-iphoneos/Yokai.app"
codesign --verify --deep --strict "$task_app"
python3 - "$task_app" "$task_root/build/Yokai.ipa" <<'PY'
from pathlib import Path
import sys, zipfile, plistlib
app=Path(sys.argv[1])
info=plistlib.loads((app/'Info.plist').read_bytes())
if not info.get('CFBundleShortVersionString') or not info.get('CFBundleVersion'):
    raise RuntimeError('App version metadata is missing')
with zipfile.ZipFile(sys.argv[2],'w',zipfile.ZIP_DEFLATED) as archive:
    for file in app.rglob('*'):
        if file.is_file():
            if file.suffix == '.class': raise RuntimeError(f'Exploded Java class would break LiveContainer signing: {file}')
            archive.write(file,Path('Payload/Yokai.app')/file.relative_to(app))
    assert archive.testzip() is None
PY
print -r -- "$task_root/build/Yokai.ipa"
if [[ "${1:-}" == "--install-direct" ]]; then
  xcrun devicectl device install app --device "$task_device" "$task_app"
  xcrun devicectl device process launch --device "$task_device" com.wyih.yokai
elif [[ "${1:-}" == "--upload-livecontainer" ]]; then
  xcrun devicectl device copy to --device "$task_device" --domain-type appDataContainer \
    --domain-identifier "${YOKAI_CONTAINER:-com.kdt.livecontainer.9FU69Y27YS}" \
    --source "$task_root/build/Yokai.ipa" --destination Documents/Yokai.ipa
  print -r -- 'Uploaded to LiveContainer Documents/Yokai.ipa; import and replace com.wyih.yokai.app in LiveContainer.'
fi
