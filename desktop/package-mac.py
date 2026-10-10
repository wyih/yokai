#!/usr/bin/env python3
"""Embed the desktop JVM, sign the complete bundle, and verify the ZIP."""
from pathlib import Path
import plistlib
import os
import re
import shutil
import subprocess
import sys
import zipfile

source, runtime, helper, output = map(Path, sys.argv[1:])
identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], check=True, capture_output=True, text=True).stdout
certificates = re.findall(r'([A-F0-9]{40}) "Apple Development:[^"]+"', identities)
identity = os.environ.get('YOKAI_MAC_SIGNING_IDENTITY') or (certificates[0] if len(certificates) == 1 else '-')
app = output / 'Yokai.app'
if app.exists():
    shutil.rmtree(app)
shutil.copytree(source, app, symlinks=True)
keychain = app / 'Contents/MacOS/YokaiKeychain'
shutil.copy2(helper, keychain)
subprocess.run(['codesign', '--force', '--sign', identity, '--identifier', 'com.wyih.yokai.desktop.keychain', str(keychain)], check=True)
target = app / 'Contents/Resources/JavaRuntime'
if target.exists():
    shutil.rmtree(target)
shutil.copytree(runtime, target, symlinks=True)
magic = {bytes.fromhex(value) for value in ('cffaedfe', 'cefaedfe', 'cafebabe')}
for file in target.rglob('*'):
    if file.is_file():
        with file.open('rb') as stream:
            executable = stream.read(4) in magic
        if executable:
            subprocess.run(['codesign', '--force', '--sign', '-', str(file)], check=True, capture_output=True)
subprocess.run(['codesign', '--force', '--sign', identity, str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.wyih.yokai.desktop'
assert (target / 'lib/server/libjvm.dylib').is_file()
assert (app / 'Contents/Resources/Extensions/vomic.jar').is_file()
assert not (app / 'Contents/Resources/lib').exists(), 'The iOS runtime must not enter the Mac bundle'
archive = output / f"Yokai-{info['CFBundleShortVersionString']}-mac-arm64.zip"
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
with zipfile.ZipFile(archive) as contents:
    assert contents.testzip() is None
print(app.resolve())
print(archive.resolve())
