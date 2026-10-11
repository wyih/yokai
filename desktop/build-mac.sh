#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_ios="$task_root/ios"
task_configuration="${YOKAI_MAC_CONFIGURATION:-Release}"
task_arch="$(uname -m)"
if [[ "$task_arch" != arm64 ]]; then
  print -u2 -- '当前桌面运行时支持 Apple Silicon Mac。'
  exit 1
fi
mkdir -p "$task_root/outputs/desktop"
mkdir -p "$task_ios/build"
python3 "$task_ios/Runtime/prepare.py" > "$task_ios/build/mac-runtime-prepare.log" 2>&1
task_jdk="$task_ios/build/runtime/jdk-27.jdk/Contents/Home"
task_runtime="$task_ios/build/mac-runtime"
if [[ ! -f "$task_runtime/lib/server/libjvm.dylib" ]]; then
  "$task_jdk/bin/jlink" --add-modules java.base,java.desktop,java.logging,java.management,java.naming,java.net.http,java.sql,java.xml,jdk.crypto.ec,jdk.unsupported \
    --strip-debug --no-header-files --no-man-pages --output "$task_runtime"
fi
swiftc "$task_root/desktop/keychain.swift" -O -target arm64-apple-macos14.0 -o "$task_ios/build/YokaiKeychain"
xcodebuild -project "$task_ios/Yokai.xcodeproj" -scheme Yokai -configuration "$task_configuration" \
  -destination "platform=macOS,variant=Mac Catalyst,arch=$task_arch" -derivedDataPath "$task_ios/.macDerivedData" \
  CODE_SIGNING_ALLOWED=NO DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.wyih.yokai.desktop ENABLE_APP_SANDBOX=NO \
  MARKETING_VERSION=0.1.3 CURRENT_PROJECT_VERSION=4 OTHER_LDFLAGS='-lc++ -lz' build \
  > "$task_ios/build/mac-build.log" 2>&1
python3 "$task_root/desktop/package-mac.py" \
  "$task_ios/.macDerivedData/Build/Products/$task_configuration-maccatalyst/Yokai.app" \
  "$task_runtime" "$task_ios/build/YokaiKeychain" "$task_root/outputs/desktop"
