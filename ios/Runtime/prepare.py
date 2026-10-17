#!/usr/bin/env python3
"""Prepare the pinned interpreter and original extensions for the iOS target."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

SOURCE = Path(__file__).resolve().parent
IOS = SOURCE.parent
BUILD = IOS / 'build/runtime'
CACHE = BUILD / 'downloads'
PROBE = IOS / 'build/runtime-probe'
LOCK = json.loads((SOURCE / 'dependencies.json').read_text())
BUILD.mkdir(parents=True, exist_ok=True)
CACHE.mkdir(exist_ok=True)

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def download(name):
    item = LOCK[name]
    target = CACHE / name
    if not target.exists():
        existing = PROBE / name
        if not existing.exists() and name.endswith('.jar'):
            existing = PROBE / 'Extensions' / name
        if existing.exists() and digest(existing) == item['sha256']:
            shutil.copy2(existing, target)
        else:
            temporary = target.with_suffix(target.suffix + '.part')
            print('Downloading', name, flush=True)
            request = urllib.request.Request(item['url'], headers={'User-Agent':'Yokai-iOS-build'})
            with urllib.request.urlopen(request, timeout=60) as response, temporary.open('wb') as output:
                shutil.copyfileobj(response, output)
            if digest(temporary) != item['sha256']:
                raise RuntimeError(f'{name}: downloaded artifact differs from dependencies.json')
            temporary.replace(target)
    if digest(target) != item['sha256']:
        raise RuntimeError(f'{target}: cached artifact differs from dependencies.json')
    return target

def run(*args, cwd=BUILD):
    subprocess.run([str(x) for x in args], cwd=cwd, check=True)

def desktop_jdk(name, directory):
    home = BUILD / directory / 'Contents/Home'
    if not home.exists():
        archive = download(name)
        with tarfile.open(archive) as tar:
            tar.extractall(BUILD, filter='data')
    return home

JDK = desktop_jdk('openjdk27.tar.gz', 'jdk-27.jdk')
writer_home = os.environ.get('YOKAI_JDK23')
if not writer_home:
    installed = Path('/opt/homebrew/Cellar/openjdk/23.0.1/libexec/openjdk.jdk/Contents/Home')
    writer_home = installed if installed.exists() else desktop_jdk('openjdk23.tar.gz', 'jdk-23.0.2.jdk')
WRITER = Path(writer_home)

if not (BUILD/'OpenJDK.xcframework').exists():
    with zipfile.ZipFile(download('OpenJDK.xcframework.zip')) as archive:
        archive.extractall(BUILD)

prefixes = ('eu/kanade/', 'kotlin/', 'kotlinx/', 'rx/', 'okhttp3/', 'okio/', 'uy/',
    'android/', 'androidx/', 'org/jsoup/', 'org/jetbrains/annotations/', 'org/slf4j/',
    'io/github/oshai/', 'org/koin/', 'xyz/nulldev/', 'com/typesafe/', 'ch/qos/',
    'org/apache/commons/', 'org/brotli/', 'com/google/gson/', 'org/json/', 'com/googlecode/d2j/',
    'com/googlecode/dex2jar/', 'net/dongliu/apk/', 'org/objectweb/asm/')
helpers = ('suwayomi/tachidesk/manga/impl/util/lang/JsonObjectKt',
    'suwayomi/tachidesk/manga/impl/util/lang/RxCoroutineBridgeKt')
notices = BUILD/'Notices'
notices.mkdir(exist_ok=True)
for generated_class in notices.glob('*.class'):
    generated_class.unlink()
with zipfile.ZipFile(download('suwayomi.jar')) as archive:
    entries = {name:archive.read(name) for name in dict.fromkeys(archive.namelist())
        if name.startswith(prefixes) or name.startswith(helpers) or name in ('r_values.ini', 'r_styles.ini')}
    for name in dict.fromkeys(archive.namelist()):
        if name.startswith('META-INF/services/'):
            providers = []
            for line in archive.read(name).decode('utf-8').splitlines():
                provider = line.split('#')[0].strip()
                if provider.replace('.', '/')+'.class' in entries:
                    providers.append(provider)
            if providers:
                entries[name] = ('\n'.join(providers)+'\n').encode()
    with zipfile.ZipFile(download('aircompressor.jar')) as compressed:
        for name in compressed.namelist():
            if name.startswith('io/airlift/compress/') and name.endswith('.class'):
                entries[name] = compressed.read(name)
    with zipfile.ZipFile(BUILD/'compat.jar', 'w', zipfile.ZIP_DEFLATED) as output:
        for name, contents in entries.items():
            if not name.endswith('/'):
                output.writestr(name, contents)
    # Preserve every license/notice entry, including duplicates in the upstream fat JAR.
    for index, item in enumerate(archive.infolist()):
        if not item.is_dir() and not item.filename.endswith('.class') and any(part.lower().startswith(('license','notice','copying')) for part in Path(item.filename).parts):
            (notices/f'{index}-{item.filename.replace("/", "_")}').write_bytes(archive.read(item))

# The mobile static VM omits libverify, used by pre-Java-6 dependency classes.
run(JDK/'bin/javac', '--release', '17', '-cp', BUILD/'compat.jar', '-d', BUILD, SOURCE/'ModernizeBytecode.java')
run(JDK/'bin/java', '-cp', str(BUILD)+':'+str(BUILD/'compat.jar'), 'ModernizeBytecode', BUILD/'compat.jar', BUILD/'compat-modern.jar')
(BUILD/'compat-modern.jar').replace(BUILD/'compat.jar')

classes = BUILD/'engine-classes'
classes.mkdir(exist_ok=True)
run(JDK/'bin/javac', '--release','17','-cp',BUILD/'compat.jar','-d',classes,*sorted((SOURCE/'java').rglob('*.java')))
run(JDK/'bin/jar','cf',BUILD/'Engine.jar','-C',classes,'.')

modules = BUILD/'lib/lib/modules'
if not modules.exists() or modules.stat().st_mtime < (SOURCE/'JimageBuilder.java').stat().st_mtime:
    base = BUILD/'module-build/baseclasses'
    base.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(download('java.base-device.zip')) as archive:
        archive.extractall(base)
    run(JDK/'bin/javac','--add-exports','java.base/jdk.internal.module=ALL-UNNAMED','-d',BUILD,SOURCE/'ModulePackages.java')
    run(JDK/'bin/java','--add-exports','java.base/jdk.internal.module=ALL-UNNAMED','-cp',BUILD,'ModulePackages',base/'java.base',BUILD/'module-build/java.base-module-info.class')
    exports = ['--add-modules','jdk.jlink','--add-exports','jdk.jlink/jdk.tools.jlink.internal=ALL-UNNAMED']
    run(WRITER/'bin/javac',*exports,'-d',BUILD,SOURCE/'JimageBuilder.java')
    run(WRITER/'bin/java',*exports,'-cp',BUILD,'JimageBuilder',base/'java.base',JDK/'jmods',modules)
shutil.copytree(JDK/'conf',BUILD/'lib/conf',dirs_exist_ok=True)
(BUILD/'lib/lib/security').mkdir(exist_ok=True)
shutil.copy2(JDK/'lib/security/cacerts',BUILD/'lib/lib/security/cacerts')
shutil.copy2(JDK/'lib/tzdb.dat',BUILD/'lib/lib/tzdb.dat')
shutil.copytree(JDK/'legal',notices/'OpenJDK',dirs_exist_ok=True)
shutil.copy2(SOURCE/'LICENSE-Suwayomi',notices/'LICENSE-Suwayomi')
shutil.copy2(download('aircompressor-license.txt'),notices/'LICENSE-aircompressor.txt')

extensions = BUILD/'Extensions'
extensions.mkdir(exist_ok=True)
for name in ['vomic','bakamh','boylove','manwa','picacomic']:
    shutil.copy2(download(name+'.jar'),extensions/(name+'.jar'))
shutil.copy2(SOURCE/'bundled/huakacomic.jar',extensions/'huakacomic.jar')
converter_cp = str(BUILD)+':'+str(BUILD/'Engine.jar')+':'+str(BUILD/'compat.jar')
run(JDK/'bin/javac','--release','17','-cp',converter_cp,'-d',BUILD,SOURCE/'ConvertApk.java')
for name in ['copymanga','hotmangas']:
    if not (extensions/(name+'.jar')).exists():
        run(JDK/'bin/java','-cp',converter_cp,'ConvertApk',download(name+'.apk'),extensions/(name+'.jar'))
print('Prepared:', BUILD, flush=True)
