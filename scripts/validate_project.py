#!/usr/bin/env python3
"""Structural checks, explicitly not a substitute for compiling Swift."""
import json
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path
root = Path(__file__).resolve().parents[1]
project_path = root/'ShanghaiTemperature.xcodeproj/project.pbxproj'
project = json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(project_path)]))
objects=project['objects']
assert objects[project['rootObject']]['isa']=='PBXProject'
targets={o['name']:o for o in objects.values() if o['isa']=='PBXNativeTarget'}
assert set(targets)=={'ShanghaiTemperature','ShanghaiTemperatureWidgets'}
for o in objects.values():
    if o['isa']=='PBXFileReference' and o.get('sourceTree')=='<group>':
        assert (root/o['path']).exists(), o['path']

def source_paths(target):
    phase=next(objects[i] for i in target['buildPhases'] if objects[i]['isa']=='PBXSourcesBuildPhase')
    return {objects[objects[i]['fileRef']]['path'] for i in phase['files']}
a=source_paths(targets['ShanghaiTemperature'])
w=source_paths(targets['ShanghaiTemperatureWidgets'])
assert 'Widgets/ShanghaiTemperatureWidgets.swift' in w and not any(p.startswith('App/') for p in w)
assert 'App/ShanghaiTemperatureApp.swift' in a and not any(p.startswith('Widgets/') for p in a)
assert a&w=={'Shared/WeatherModel.swift','Shared/TemperatureChartView.swift','Shared/WeatherService.swift'}
app=targets['ShanghaiTemperature']
assert len(app['dependencies'])==1
widget=targets['ShanghaiTemperatureWidgets']
assert objects[objects[app['dependencies'][0]]['target']]==widget
embed=next(objects[i] for i in app['buildPhases'] if objects[i]['isa']=='PBXCopyFilesBuildPhase')
assert embed['dstSubfolderSpec']=='13'
assert objects[embed['files'][0]]['fileRef']==widget['productReference']
info=plistlib.loads((root/'Widgets/Info.plist').read_bytes())
assert info['NSExtension']['NSExtensionPointIdentifier']=='com.apple.widgetkit-extension'
for p in ['App/App.entitlements','Widgets/Widgets.entitlements']:
    entitlements=plistlib.loads((root/p).read_bytes())
    assert entitlements['com.apple.security.app-sandbox'] is True
    assert entitlements['com.apple.security.network.client'] is True
scheme=ET.parse(root/'ShanghaiTemperature.xcodeproj/xcshareddata/xcschemes/ShanghaiTemperature.xcscheme')
for ref in scheme.findall('.//BuildableReference'):
    assert ref.attrib['BlueprintIdentifier'] in objects
model=(root/'Shared/WeatherModel.swift').read_text()
for name,count in [('maximum',15),('minimum',15),('trendMaximum',30),('trendMinimum',30)]:
    values=[float(x) for x in re.search(r'static let '+name+r' = \[([^]]+)\]',model).group(1).split(',')]
    assert len(values)==count
for high,low in [('maximum','minimum'),('trendMaximum','trendMinimum')]:
    h=[float(x) for x in re.search(r'static let '+high+r' = \[([^]]+)\]',model).group(1).split(',')]
    l=[float(x) for x in re.search(r'static let '+low+r' = \[([^]]+)\]',model).group(1).split(',')]
    assert all(x>=y for x,y in zip(h,l))
print('PASS: file references, target membership, extension embedding, scheme, plists and sample data.')
print('Swift compilation and widget rendering have NOT been validated.')
