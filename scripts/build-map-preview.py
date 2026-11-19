#!/usr/bin/env python3
"""Build an explicitly archived-date gallery preview, never a live fallback."""
import argparse
import datetime as dt
import importlib.util
import json
from pathlib import Path
import struct


def load(name,file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file))
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history',type=Path,default=Path(__file__).resolve().parents[1]/'Widgets/Resources/WeatherHistory')
    parser.add_argument('--output',type=Path,default=Path(__file__).resolve().parents[1]/'Widgets/Resources/ThermalMap/replay.json')
    a=parser.parse_args();date=dt.datetime(2025,11,19,15)
    ref=load('reference_history','check-thermal-history.py');bands=load('reference_bands','thermal-bands-reference.py')
    stats,years=ref.check(a.history,date,verbose=False)
    index=json.loads((a.history/'index.json').read_text());entry=next(y for y in index['years'] if y['year']==date.year)
    data=(a.history/entry['file']).read_bytes();hour=int((date-dt.datetime(date.year,1,1)).total_seconds()/3600)
    values=[ref.apparent(*(v/100 for v in struct.unpack_from('<hHH',data,(i*entry['hours']+hour)*6))) for i in range(len(index['points']))]
    result=bands.build(index['points'],values,[y['windows'][stats['selectedDayRadius']] for y in years])
    edges=[min(values)]+result['cuts']+[max(values)]
    snapshot=dict(algorithmVersion=2,source='local',date=date.replace(tzinfo=dt.timezone(dt.timedelta(hours=8))).isoformat(),
        bands=[dict(index=i,lower=edges[i],upper=edges[i+1],representative=result['means'][i],pointCount=count) for i,count in enumerate(result['pointCounts'])],
        cuts=result['cuts'],baseCuts=result['baseCuts'],
        points=[dict(id=p['id'],latitude=p['latitude'],longitude=p['longitude'],apparentTemperature=v,bandIndex=label) for p,v,label in zip(index['points'],values,result['labels'])],
        historicalSpatialError=result['historicalSpatialError'],selectedNeighbourCount=result['selectedNeighbourCount'],
        criterionScore=result['score'],retainedPreviousCuts=False)
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(snapshot,ensure_ascii=False,separators=(',',':'))+'\n')
    print('PASS: archived 2025-11-19 preview,',len(snapshot['bands']),'bands,',len(snapshot['points']),'points')
