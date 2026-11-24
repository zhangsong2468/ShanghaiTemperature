#!/usr/bin/env python3
"""Generate a self-contained two-target Xcode project; no third-party packages."""
import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def obj(object_key, isa, **fields):
    key = uid(object_key)
    objects[key] = {'isa': isa, **fields}
    return key

def plist(path, value):
    (ROOT / path).write_bytes(plistlib.dumps(value, sort_keys=False))

sources = ['App/ShanghaiTemperatureApp.swift', 'App/ContentView.swift', 'App/AircraftPlaybackModel.swift', 'App/AircraftHistoryRuler.swift', 'App/AircraftFrameRenderer.swift',
           'Shared/WeatherModel.swift', 'Shared/TemperatureChartView.swift', 'Shared/WeatherService.swift',
           'Shared/CommuteRainForecast.swift', 'Shared/AircraftService.swift', 'Shared/AircraftHistory.swift', 'Shared/AircraftMetadata.swift', 'Shared/AircraftTracking.swift', 'Shared/AircraftSelection.swift', 'Shared/AircraftMapLayer.swift',
           'Shared/HistoricalWeatherArchive.swift', 'Shared/ThermalComparison.swift',
           'Shared/ThermalSourceSettings.swift', 'Shared/NetworkApparentTemperature.swift',
           'Shared/DynamicThermalBands.swift', 'Shared/ThermalMapGeometry.swift', 'Shared/ThermalMapView.swift', 'Shared/SolarTermCalendar.swift', 'Shared/ThermalSurface.swift',
           'Shared/RegionalThermalStore.swift', 'Shared/RegionalCurrentWeather.swift', 'Shared/ThermalTimingAnalysis.swift',
           'Widgets/ShanghaiTemperatureWidgets.swift', 'Widgets/RegionalThermalMapWidget.swift']
refs = {}
for path in sources:
    refs[path] = obj('file:'+path, 'PBXFileReference', lastKnownFileType='sourcecode.swift',
                     path=path, sourceTree='<group>')
app_product = obj('app-product', 'PBXFileReference', explicitFileType='wrapper.application',
                  includeInIndex='0', path='ShanghaiTemperature.app', sourceTree='BUILT_PRODUCTS_DIR')
widget_product = obj('widget-product', 'PBXFileReference', explicitFileType='wrapper.app-extension',
                     includeInIndex='0', path='ShanghaiTemperatureWidgets.appex', sourceTree='BUILT_PRODUCTS_DIR')
products = obj('products', 'PBXGroup', children=[app_product, widget_product], name='Products', sourceTree='<group>')
extra = []
for path in ['README.md','App/Info.plist','App/App.entitlements','Widgets/Info.plist','Widgets/Widgets.entitlements']:
    extra.append(obj('file:'+path, 'PBXFileReference', lastKnownFileType='text.plist.xml' if path.endswith(('.plist','.entitlements')) else 'text', path=path, sourceTree='<group>'))
asset_ref = obj('app-assets', 'PBXFileReference', lastKnownFileType='folder.assetcatalog', path='App/Assets.xcassets', sourceTree='<group>')
notice_ref = obj('icon-notice', 'PBXFileReference', lastKnownFileType='text', path='App/Resources/Meteocons-LICENSE.txt', sourceTree='<group>')
history_ref = obj('weather-history', 'PBXFileReference', lastKnownFileType='folder',
                  path='Widgets/Resources/WeatherHistory', sourceTree='<group>')
map_ref = obj('thermal-map', 'PBXFileReference', lastKnownFileType='folder',
              path='Widgets/Resources/ThermalMap', sourceTree='<group>')
extra += [asset_ref, notice_ref, history_ref, map_ref]
framework_refs = []
for fw in ['SwiftUI', 'Charts', 'WidgetKit']:
    framework_refs.append(obj('framework:'+fw, 'PBXFileReference', lastKnownFileType='wrapper.framework',
                              name=fw+'.framework', path='System/Library/Frameworks/'+fw+'.framework', sourceTree='SDKROOT'))
framework_group = obj('framework-group', 'PBXGroup', children=framework_refs, name='Frameworks', sourceTree='<group>')
main_group = obj('main-group','PBXGroup',children=list(refs.values())+extra+[framework_group,products],sourceTree='<group>')

for extension in [False, True]:
    prefix = 'widget' if extension else 'app'
    paths = [p for p in sources if p.startswith('Shared/') or p.startswith('Widgets/' if extension else 'App/')]
    builds = [obj(prefix+':build:'+p, 'PBXBuildFile', fileRef=refs[p]) for p in paths]
    obj(prefix+':sources', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=builds, runOnlyForDeploymentPostprocessing='0')
    frameworks = [obj(prefix+':framework:'+str(i),'PBXBuildFile',fileRef=ref) for i,ref in enumerate(framework_refs)]
    obj(prefix+':frameworks','PBXFrameworksBuildPhase',buildActionMask='2147483647',files=frameworks,runOnlyForDeploymentPostprocessing='0')
    resources = [obj('weather-history-build','PBXBuildFile',fileRef=history_ref), obj('thermal-map-build','PBXBuildFile',fileRef=map_ref)] if extension else [obj('app-assets-build','PBXBuildFile',fileRef=asset_ref), obj('icon-notice-build','PBXBuildFile',fileRef=notice_ref), obj('app-weather-history-build','PBXBuildFile',fileRef=history_ref), obj('app-thermal-map-build','PBXBuildFile',fileRef=map_ref)]
    obj(prefix+':resources','PBXResourcesBuildPhase',buildActionMask='2147483647',files=resources,runOnlyForDeploymentPostprocessing='0')
    config_ids = []
    for config in ['Debug','Release']:
        settings = {
            'PRODUCT_NAME': 'ShanghaiTemperatureWidgets' if extension else 'ShanghaiTemperature',
            'PRODUCT_BUNDLE_IDENTIFIER': 'com.songa.ShanghaiTemperature'+('.Widgets' if extension else ''),
            'INFOPLIST_FILE': 'Widgets/Info.plist' if extension else 'App/Info.plist',
            'CODE_SIGN_ENTITLEMENTS':'Widgets/Widgets.entitlements' if extension else 'App/App.entitlements',
            'GENERATE_INFOPLIST_FILE':'NO','CODE_SIGN_STYLE':'Automatic',
            'SWIFT_VERSION':'5.0','MACOSX_DEPLOYMENT_TARGET':'14.0','SDKROOT':'macosx',
            'SUPPORTED_PLATFORMS':'macosx', 'ENABLE_HARDENED_RUNTIME':'YES',
            'CURRENT_PROJECT_VERSION':'2', 'MARKETING_VERSION':'0.4.0',
            'LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks']+(['@executable_path/../../../../Frameworks'] if extension else []),
            'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O',
            'SWIFT_COMPILATION_MODE':'singlefile' if config=='Debug' else 'wholemodule',
        }
        if extension:
            settings.update({'APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES'})
        else:
            settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
        config_ids.append(obj(prefix+':config:'+config,'XCBuildConfiguration',name=config,buildSettings=settings))
    obj(prefix+':config-list','XCConfigurationList',buildConfigurations=config_ids,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')

embed_file = obj('embed-file','PBXBuildFile',fileRef=widget_product, settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
embed = obj('embed-phase','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='13',files=[embed_file],name='Embed App Extensions',runOnlyForDeploymentPostprocessing='0')
proxy = obj('widget-proxy','PBXContainerItemProxy',containerPortal=uid('project'),proxyType='1',remoteGlobalIDString=uid('widget-target'),remoteInfo='ShanghaiTemperatureWidgets')
dependency = obj('widget-dependency','PBXTargetDependency',target=uid('widget-target'),targetProxy=proxy)
for prefix in ['app','widget']:
    extension = prefix=='widget'
    obj(prefix+'-target','PBXNativeTarget',buildConfigurationList=uid(prefix+':config-list'),
        buildPhases=[uid(prefix+':sources'),uid(prefix+':frameworks'),uid(prefix+':resources')]+([] if extension else [embed]),
        buildRules=[],dependencies=[] if extension else [dependency],
        name='ShanghaiTemperatureWidgets' if extension else 'ShanghaiTemperature',
        productName='ShanghaiTemperatureWidgets' if extension else 'ShanghaiTemperature',
        productReference=widget_product if extension else app_product,
        productType='com.apple.product-type.app-extension' if extension else 'com.apple.product-type.application')
project_configs = [obj('project-config:'+c,'XCBuildConfiguration',name=c,buildSettings={'CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','SWIFT_VERSION':'5.0','MACOSX_DEPLOYMENT_TARGET':'14.0','SDKROOT':'macosx','DEBUG_INFORMATION_FORMAT':'dwarf' if c=='Debug' else 'dwarf-with-dsym','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if c=='Debug' else ''}) for c in ['Debug','Release']]
project_config_list = obj('project-config-list','XCConfigurationList',buildConfigurations=project_configs,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')
obj('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'1600','TargetAttributes':{uid('app-target'):{'CreatedOnToolsVersion':'16.0'},uid('widget-target'):{'CreatedOnToolsVersion':'16.0'}}},buildConfigurationList=project_config_list,compatibilityVersion='Xcode 14.0',developmentRegion='zh-Hans',hasScannedForEncodings='0',knownRegions=['zh-Hans','en','Base'],mainGroup=main_group,productRefGroup=products,projectDirPath='',projectRoot='',targets=[uid('app-target'),uid('widget-target')])

def emit(value, depth=0):
    tab='\t'*depth
    if isinstance(value,dict):
        return '{\n'+''.join('\t'*(depth+1)+json.dumps(k,ensure_ascii=False)+' = '+emit(v,depth+1)+';\n' for k,v in value.items())+tab+'}'
    if isinstance(value,list):
        return '('+', '.join(emit(v,depth) for v in value)+')'
    return json.dumps(value,ensure_ascii=False)

project = {'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':uid('project')}
(ROOT/'ShanghaiTemperature.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n'+emit(project)+'\n')
base={'CFBundleDevelopmentRegion':'zh-Hans','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'$(PRODUCT_NAME)','CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)','CFBundleDisplayName':'上海温度','LSMinimumSystemVersion':'$(MACOSX_DEPLOYMENT_TARGET)'}
plist('App/Info.plist',base|{'CFBundlePackageType':'APPL','NSPrincipalClass':'NSApplication','LSApplicationCategoryType':'public.app-category.weather'})
plist('Widgets/Info.plist',base|{'CFBundlePackageType':'XPC!','NSExtension':{'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}})
for path in ['App/App.entitlements','Widgets/Widgets.entitlements']:
    access = 'read-write'
    plist(path,{'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,
        'com.apple.security.temporary-exception.shared-preference.'+access:
            ['com.songa.ShanghaiTemperature.ThermalPreferences']})
app_id=uid('app-target')
(ROOT/'ShanghaiTemperature.xcodeproj/xcshareddata/xcschemes/ShanghaiTemperature.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="ShanghaiTemperature.app" BlueprintName="ShanghaiTemperature" ReferencedContainer="container:ShanghaiTemperature.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="ShanghaiTemperature.app" BlueprintName="ShanghaiTemperature" ReferencedContainer="container:ShanghaiTemperature.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="ShanghaiTemperature.app" BlueprintName="ShanghaiTemperature" ReferencedContainer="container:ShanghaiTemperature.xcodeproj"/></BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print('Generated two targets, embedded widget extension and shared run scheme.')
