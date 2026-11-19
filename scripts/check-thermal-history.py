#!/usr/bin/env python3
"""Independent Python reference check on the packed real history; not a Swift test."""
import argparse
import datetime as dt
import json
import math
import mmap
from pathlib import Path
import struct
import time


def apparent(t,rh,wind):
    return t+.33*(rh/100*6.105*math.exp(17.27*t/(237.7+t)))-.70*wind-4


def check(root,date,verbose=True):
    index=json.loads((root/'index.json').read_text())
    radii=[0,3,7,14,21]
    years=[]; began=time.perf_counter()
    for item in index['years']:
        year=item['year']
        if year>=date.year:continue
        try:centres=[date.replace(year=year)]
        except ValueError:centres=[date.replace(year=year,day=28),date.replace(year=year,month=3,day=1)]
        with (root/item['file']).open('rb') as stream:
            with mmap.mmap(stream.fileno(),0,access=mmap.ACCESS_READ) as data:
                start=dt.datetime(year,1,1)
                dates=sorted({centre+dt.timedelta(days=i) for centre in centres for i in range(-21,22) if (centre+dt.timedelta(days=i)).year==year})
                windows={r:[[] for p in index['points']] for r in radii}
                anchor=[]
                def read(point,at):
                    hour=int((at-start).total_seconds()/3600)
                    t,h,w=struct.unpack_from('<hHH',data,(point*item['hours']+hour)*6)
                    return apparent(t/100,h/100,w/100)
                for at in dates:
                    distance=min(abs((at-c).days) for c in centres)
                    for point in range(len(index['points'])):
                        value=read(point,at)
                        for radius in radii:
                            if distance<=radius:windows[radius][point].append(value)
                anchor=[sum(read(p,c) for c in centres)/len(centres) for p in range(len(index['points']))]
                years.append(dict(year=year,windows=windows,anchor=anchor))
    if len(years)<3:raise ValueError('Need at least three earlier historical years')
    errors={}
    for radius in radii:
        means=[[sum(v)/len(v) for v in y['windows'][radius]] for y in years]
        errors[radius]=sum(abs(sum(means[j][p] for j in range(len(years)) if j!=held)/(len(years)-1)-years[held]['anchor'][p]) for held in range(len(years)) for p in range(len(index['points'])))/(len(years)*len(index['points']))
    best=min(radii,key=lambda r:errors[r])
    reference=[sum(sum(y['windows'][best][p])/len(y['windows'][best][p]) for y in years)/len(years) for p in range(len(index['points']))]
    result=dict(target=date.isoformat(),historicalYears=[y['year'] for y in years],pointCount=len(reference),
        selectedDayRadius=best,crossValidationMAE=errors[best],candidateErrors=errors,
        regionalReferenceApparentTemperature=sum(reference)/len(reference),elapsedSeconds=time.perf_counter()-began,
        note='Historical reference only. No current weather was fetched or fabricated. Python check, Swift execution pending.')
    if verbose: print(json.dumps(result,ensure_ascii=False,indent=2))
    return result, years


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history',type=Path,required=True)
    parser.add_argument('--at',default='2026-11-19T15:00')
    a=parser.parse_args()
    check(a.history,dt.datetime.fromisoformat(a.at))
