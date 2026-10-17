#!/usr/bin/env python3
"""Compose the existing native readers. No fork of their UI or engine sources."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent
ios = root.parent
qiye = Path(os.environ.get('QIYE_READER_ROOT', ios.parent.parent/'qiye-reader')).resolve()
assert (qiye/'ios-app/App/ReaderViewController.swift').is_file(), 'Set QIYE_READER_ROOT to the qiye-reader checkout'
build = root/'build'
build.mkdir(exist_ok=True)
web = build/'WebAssets'
if web.exists(): shutil.rmtree(web)
shutil.copytree(qiye/'app/src/main/assets', web)
# Use the original document registrations and required permissions from both apps.
info = plistlib.loads((qiye/'ios-app/Config/Info.plist').read_bytes())
yokai = plistlib.loads((ios/'Yokai/Info.plist').read_bytes())
info['UIApplicationSceneManifest'] = {'UIApplicationSupportsMultipleScenes': False, 'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{'UISceneConfigurationName':'ReadingHub','UISceneDelegateClassName':'$(PRODUCT_MODULE_NAME).ReadingHubSceneDelegate'}]}}
info.update({k:v for k,v in yokai.items() if k.startswith('NSPhotoLibraryAdd') or k == 'UTImportedTypeDeclarations'})
info['CFBundleDisplayName'] = '书房'
info['CFBundleName'] = 'ReadingHub'
info['HubQiyeVersion'] = info['CFBundleShortVersionString']
info['HubQiyeCommit'] = subprocess.check_output(['git', '-C', str(qiye), 'rev-parse', 'HEAD'], text=True).strip()
info['CFBundleShortVersionString'] = '0.1.10'
info['CFBundleVersion'] = '11'
info['CFBundleDocumentTypes'] += yokai['CFBundleDocumentTypes']
info['UIBackgroundModes'] = ['audio','fetch','processing']
info['BGTaskSchedulerPermittedIdentifiers'] = info.get('BGTaskSchedulerPermittedIdentifiers', []) + ['$(PRODUCT_BUNDLE_IDENTIFIER).yokai.refresh','$(PRODUCT_BUNDLE_IDENTIFIER).yokai.download.*']
info['CFBundleURLTypes'] = [{'CFBundleURLName':'com.wyih.readinghub','CFBundleURLSchemes':['readinghub']}]
info['UIFileSharingEnabled'] = True
migration_group = os.environ.get('HUB_MIGRATION_GROUP')
if migration_group:
    assert migration_group.isdigit() and int(migration_group) > 0, 'Use the assigned, isolated guest Keychain group'
    info['HubMigrationKeychainGroup'] = '$(AppIdentifierPrefix)com.kdt.livecontainer.shared.'+migration_group
    info['HubOwnKeychainGroup'] = '$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)'
    (build/'Migration.entitlements').write_bytes(plistlib.dumps({'keychain-access-groups': ['$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)','$(AppIdentifierPrefix)com.kdt.livecontainer.shared.'+migration_group]}))
(build/'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=False))
(build/'Simulator.entitlements').write_bytes(plistlib.dumps({'application-identifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'keychain-access-groups': ['$(PRODUCT_BUNDLE_IDENTIFIER)']}))
manifest = {'yokai': str(ios.parent), 'qiye': str(qiye)}
(build/'source-roots.json').write_text(json.dumps(manifest, indent=2))
objects = []
def uid(n): return hashlib.sha256(n.encode()).hexdigest()[:24].upper()
def q(n): return json.dumps(str(n), ensure_ascii=False)
def array(xs): return '('+','.join(xs)+')'
def obj(n, isa, value):
    key=uid(n); objects.append(f'{key} = {{isa = {isa}; {value}}};'); return key
def reference(p,kind):
    rel=os.path.relpath(p,root)
    return obj(rel,'PBXFileReference',f'lastKnownFileType = {kind}; path = {q(rel)}; sourceTree = "<group>";')
refs=[]
def build_file(p,kind,owner):
    ref=reference(p,kind);refs.append(ref)
    return obj(owner+str(p),'PBXBuildFile',f'fileRef = {ref};')
host_sources=[]
for p in sorted((ios/'Yokai').rglob('*')):
    if p.suffix in ['.swift','.m']:
        host_sources.append(build_file(p,'sourcecode.swift' if p.suffix=='.swift' else 'sourcecode.c.objc','host'))
for p in sorted((root/'Sources').glob('*.swift')):
    if p.name != 'QiyeModule.swift': host_sources.append(build_file(p,'sourcecode.swift','host'))
qiye_sources=[build_file(p,'sourcecode.swift','qiye') for p in sorted((qiye/'ios-app/App').glob('*.swift')) if p.name!='AppDelegate.swift']
qiye_sources.append(build_file(root/'Sources/QiyeModule.swift','sourcecode.swift','qiye'))
resources=[]
resources.append(build_file(root/'Assets.xcassets','folder.assetcatalog','resource'))
for name,kind in [('Acknowledgements.txt','text'),('ExtensionRepositories.json','text.json'),('BundledExtensions.json','text.json')]:
    resources.append(build_file(ios/'Yokai'/name,kind,'resource'))
for name,kind in [('lib','folder'),('Engine.jar','archive.jar'),('compat.jar','archive.jar'),('Extensions','folder'),('Notices','folder')]:
    resources.append(build_file(ios/'build/runtime'/name,kind,'resource'))
resources.append(build_file(web,'folder','resource'))
java=build_file(ios/'build/runtime/OpenJDK.xcframework','wrapper.xcframework','link')
zip_pkg=obj('zip-pkg','XCRemoteSwiftPackageReference','repositoryURL = "https://github.com/weichsel/ZIPFoundation.git"; requirement = {kind = upToNextMinorVersion; minimumVersion = 0.9.20; };')
zip_product=obj('zip-product','XCSwiftPackageProductDependency',f'package = {zip_pkg}; productName = ZIPFoundation;')
zip_link=obj('zip-link','PBXBuildFile',f'productRef = {zip_product};')
core_pkg=obj('core-pkg','XCLocalSwiftPackageReference',f'relativePath = {q(os.path.relpath(qiye/"ios-app", root))};')
core_product=obj('core-product','XCSwiftPackageProductDependency',f'package = {core_pkg}; productName = QiyeCore;')
core_link=obj('core-link','PBXBuildFile',f'productRef = {core_product};')
test_sources = [build_file(root/'Tests/HubFlowTests.swift', 'sourcecode.swift', 'test'), build_file(qiye/'ios-app/UITests/AppFlowTests.swift', 'sourcecode.swift', 'test')]
test_resources = [build_file(p,'sourcecode.javascript','test-resource') for p in sorted((qiye/'tests').glob('*-script.js'))]
test_product = obj('test-product','PBXFileReference','explicitFileType = wrapper.cfbundle; path = ReadingHubUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
product=obj('host-product' ,'PBXFileReference','explicitFileType = wrapper.application; path = ReadingHub.app; sourceTree = BUILT_PRODUCTS_DIR;')
qiye_product=obj('qiye-product','PBXFileReference','explicitFileType = archive.ar; path = libQiyeModule.a; sourceTree = BUILT_PRODUCTS_DIR;')
qiye_link=obj('qiye-link','PBXBuildFile',f'fileRef = {qiye_product};')
products=obj('products','PBXGroup',f'children = ({product},{qiye_product},{test_product}); name = Products; sourceTree = "<group>";')
main=obj('main','PBXGroup',f'children = {array(refs+[products])}; sourceTree = "<group>";')
def phase(name,isa,files):return obj(name,isa,f'buildActionMask = 2147483647; files = {array(files)}; runOnlyForDeploymentPostprocessing = 0;')
hs=phase('host-sources','PBXSourcesBuildPhase',host_sources)
hr=phase('host-resources','PBXResourcesBuildPhase',resources)
hf=phase('host-frameworks','PBXFrameworksBuildPhase',[java,zip_link,qiye_link])
qs=phase('qiye-sources','PBXSourcesBuildPhase',qiye_sources)
qf=phase('qiye-frameworks','PBXFrameworksBuildPhase',[core_link])
ts=phase('test-sources','PBXSourcesBuildPhase',test_sources)
tr=phase('test-resources','PBXResourcesBuildPhase',test_resources)
configs={'project':[],'host':[],'qiye':[],'test':[]}
for mode in ['Debug','Release']:
    common={'CLANG_ENABLE_MODULES':'YES','SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.5','SWIFT_VERSION':'5.0','ONLY_ACTIVE_ARCH':'YES' if mode=='Debug' else 'NO','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'READING_HUB'+(' DEBUG' if mode=='Debug' else ''),'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym'}
    host={'PRODUCT_NAME':'ReadingHub','PRODUCT_BUNDLE_IDENTIFIER':'com.wyih.qiyereader','INFOPLIST_FILE':'build/Info.plist','GENERATE_INFOPLIST_FILE':'NO','SWIFT_OBJC_BRIDGING_HEADER':'../Yokai/Yokai-Bridging-Header.h','OTHER_LDFLAGS':'$(inherited) -lc++ -lz -Wl,-all_load','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','ENABLE_DEBUG_DYLIB':'NO','DEAD_CODE_STRIPPING':'NO','TARGETED_DEVICE_FAMILY':'1,2','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'9FU69Y27YS','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'}
    module={'PRODUCT_NAME':'QiyeModule','PRODUCT_MODULE_NAME':'QiyeModule','DEFINES_MODULE':'YES','SWIFT_INSTALL_OBJC_HEADER':'NO','SKIP_INSTALL':'YES','MACH_O_TYPE':'staticlib','CODE_SIGNING_ALLOWED':'NO','TARGETED_DEVICE_FAMILY':'1,2'}
    host['CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]'] = 'build/Simulator.entitlements'
    if migration_group:
        host['CODE_SIGN_ENTITLEMENTS'] = 'build/Migration.entitlements'
        host['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = common['SWIFT_ACTIVE_COMPILATION_CONDITIONS']+' MIGRATE_LIVE_CONTAINER'
    test={'PRODUCT_NAME':'ReadingHubUITests','PRODUCT_BUNDLE_IDENTIFIER':'com.wyih.readinghub.uitests','GENERATE_INFOPLIST_FILE':'YES','TEST_TARGET_NAME':'ReadingHub','TARGETED_DEVICE_FAMILY':'1,2','CODE_SIGN_STYLE':'Automatic'}
    for name,settings in [('project',common),('host',host),('qiye',module),('test',test)]:
        text=' '.join(f'{q(k)} = {q(v)};' for k,v in settings.items())
        configs[name].append(obj(name+mode,'XCBuildConfiguration',f'name = {mode}; buildSettings = {{{text}}};'))
def config(name):return obj(name+'-configs','XCConfigurationList',f'buildConfigurations = {array(configs[name])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
pc,hc,qc=map(config,['project','host','qiye'])
qt=obj('qiye-target','PBXNativeTarget',f'buildConfigurationList = {qc}; buildPhases = ({qs},{qf}); buildRules = (); dependencies = (); name = QiyeModule; productName = QiyeModule; productReference = {qiye_product}; productType = "com.apple.product-type.library.static"; packageProductDependencies = ({core_product});')
proxy=obj('proxy','PBXContainerItemProxy',f'containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {qt}; remoteInfo = QiyeModule;')
dep=obj('qiye-dependency','PBXTargetDependency',f'target = {qt}; targetProxy = {proxy};')
ht=obj('host-target','PBXNativeTarget',f'buildConfigurationList = {hc}; buildPhases = ({hs},{hf},{hr}); buildRules = (); dependencies = ({dep}); name = ReadingHub; productName = ReadingHub; productReference = {product}; productType = "com.apple.product-type.application"; packageProductDependencies = ({zip_product});')
tc=config('test')
tp=obj('test-proxy','PBXContainerItemProxy',f'containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {ht}; remoteInfo = ReadingHub;')
td=obj('test-dependency','PBXTargetDependency',f'target = {ht}; targetProxy = {tp};')
tt=obj('test-target','PBXNativeTarget',f'buildConfigurationList = {tc}; buildPhases = ({ts},{tr}); buildRules = (); dependencies = ({td}); name = ReadingHubUITests; productName = ReadingHubUITests; productReference = {test_product}; productType = "com.apple.product-type.bundle.ui-testing";')
project=obj('project' ,'PBXProject',f'attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }}; buildConfigurationList = {pc}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = (en,Base,"zh-Hans"); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; packageReferences = ({zip_pkg},{core_pkg}); targets = ({ht},{qt},{tt});')
folder=root/'ReadingHub.xcodeproj';folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
scheme=folder/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ht}" BuildableName="ReadingHub.app" BlueprintName="ReadingHub" ReferencedContainer="container:ReadingHub.xcodeproj"/>'
tref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{tt}" BuildableName="ReadingHubUITests.xctest" BlueprintName="ReadingHubUITests" ReferencedContainer="container:ReadingHub.xcodeproj"/>'
(scheme/'ReadingHub.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables><TestableReference skipped="NO">{tref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(folder)
