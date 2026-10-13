#!/usr/bin/env python3
"""Generate an isolated Xcode UI-test project without changing the Swift package."""
import hashlib, json, pathlib, sys, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
stage = pathlib.Path(tempfile.mkdtemp(prefix='cove-xcui-'))
project = stage / 'CoveUI.xcodeproj'
project.mkdir()
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(key_name, **fields):
    key = ident(key_name); objects[key] = fields; return key
def emit(v):
    if isinstance(v, dict): return '{' + ''.join(json.dumps(k)+ ' = '+emit(x)+';\n' for k,x in v.items())+'}'
    if isinstance(v, list): return '('+','.join(emit(x) for x in v)+')'
    return json.dumps(str(v))
def file(path, kind): return obj(str(path), isa='PBXFileReference', lastKnownFileType=kind, path=str(path), sourceTree='<absolute>')
app_product=obj('app-product',isa='PBXFileReference',explicitFileType='wrapper.application',path='CoveUIHost.app',sourceTree='BUILT_PRODUCTS_DIR')
test_product=obj('test-product',isa='PBXFileReference',explicitFileType='wrapper.cfbundle',path='CoveUITests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
files=[file(p,'sourcecode.swift') for p in sorted((root/'Sources/Cove').rglob('*.swift')) if p.name!='main.swift']
files.append(file(root/'Tests/UI/CoveUIHost.swift','sourcecode.swift'))
test_file=file(root/'Tests/UI/UIFlowTests.swift','sourcecode.swift')
fixtures=file(root/'Tests/CoveTests/Fixtures','folder')
def phase(name,kind,refs):
    builds=[obj(name+ref,isa='PBXBuildFile',fileRef=ref) for ref in refs]
    return obj(name,isa=kind,buildActionMask=2147483647,files=builds,runOnlyForDeploymentPostprocessing=0)
app_src=phase('app-src','PBXSourcesBuildPhase',files)
app_res=phase('app-res','PBXResourcesBuildPhase',[fixtures])
test_src=phase('test-src','PBXSourcesBuildPhase',[test_file])
base={'SDKROOT':'macosx','MACOSX_DEPLOYMENT_TARGET':'14.0','SWIFT_VERSION':'5.0','CODE_SIGN_IDENTITY':'-','CODE_SIGN_STYLE':'Manual','ENABLE_HARDENED_RUNTIME':'NO','GENERATE_INFOPLIST_FILE':'YES','SWIFT_OPTIMIZATION_LEVEL':'-Onone'}
def configs(name,extra):
    ids=[]
    for mode in ['Debug','Release']:
        ids.append(obj(name+mode,isa='XCBuildConfiguration',name=mode,buildSettings={**base,**extra}))
    return obj(name+'configs',isa='XCConfigurationList',buildConfigurations=ids,defaultConfigurationIsVisible=0,defaultConfigurationName='Debug')
app_target=obj('app-target',isa='PBXNativeTarget',name='CoveUIHost',productName='CoveUIHost',productReference=app_product,productType='com.apple.product-type.application',buildConfigurationList=configs('app',{'PRODUCT_BUNDLE_IDENTIFIER':'app.cove.ui-test','PRODUCT_NAME':'CoveUIHost','OTHER_LDFLAGS':'-lsqlite3 -framework IOKit -framework ServiceManagement'}),buildPhases=[app_src,app_res],buildRules=[],dependencies=[])
proxy=obj('proxy',isa='PBXContainerItemProxy',containerPortal=ident('project'),proxyType=1,remoteGlobalIDString=app_target,remoteInfo='CoveUIHost')
dep=obj('dep',isa='PBXTargetDependency',target=app_target,targetProxy=proxy)
test_target=obj('test-target',isa='PBXNativeTarget',name='CoveUITests',productName='CoveUITests',productReference=test_product,productType='com.apple.product-type.bundle.ui-testing',buildConfigurationList=configs('test',{'PRODUCT_BUNDLE_IDENTIFIER':'app.cove.ui-tests','PRODUCT_NAME':'CoveUITests','TEST_TARGET_NAME':'CoveUIHost'}),buildPhases=[test_src],buildRules=[],dependencies=[dep])
group=obj('group',isa='PBXGroup',children=files+[test_file,fixtures,app_product,test_product],sourceTree='<group>')
proj=obj('project',isa='PBXProject',attributes={'LastUpgradeCheck':'1600','TargetAttributes':{test_target:{'TestTargetID':app_target}}},buildConfigurationList=configs('project',{}),compatibilityVersion='Xcode 14.0',developmentRegion='en',knownRegions=['en','Base'],mainGroup=group,projectDirPath='',projectRoot='',targets=[app_target,test_target])
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n'+emit({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':proj}))
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True)
def ref(target,name,product):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:CoveUI.xcodeproj"/>'
(schemes/'CoveUI.xcscheme').write_text(f'''<?xml version="1.0"?><Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref(app_target,'CoveUIHost','CoveUIHost.app')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(test_target,'CoveUITests','CoveUITests.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app_target,'CoveUIHost','CoveUIHost.app')}</BuildableProductRunnable></LaunchAction></Scheme>''')
print(project)
