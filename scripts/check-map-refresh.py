#!/usr/bin/env python3
"""Check seasonal-message policy and replay actual 14-day local archive series.
Not a Swift or live-network test.
"""
import argparse
import datetime as dt
import importlib.util
import json
import statistics
import struct
from pathlib import Path


def slope(a):
    return statistics.median((a[j]-a[i])/(j-i) for i in range(len(a)-1) for j in range(i+1,len(a)))


def timing(observed,profiles):
    if len(observed)!=14 or len(profiles)<5:return None
    first,last=slope(observed[:7]),slope(observed[-7:])
    if first*last<=0:return None
    profiles=[p for p in profiles if all(i in p for i in range(-27,15))]
    if len(profiles)<5:return None
    shifts=list(range(-14,15))
    def curve(ps,s):return [statistics.mean(p[i+s] for p in ps) for i in range(-13,1)]
    def best(ps):
        return min(shifts,key=lambda s:(sum((a-b)**2 for a,b in zip(observed,curve(ps,s))),abs(s)))
    selected=best(profiles)
    if not 0<abs(selected)<14 or slope(curve(profiles,selected))*first<=0:return None
    state=0x535448;estimates=[]
    for _ in range(200):
        sample=[]
        for _ in profiles:
            state=(state*6364136223846793005+1442695040888963407)&((1<<64)-1)
            sample.append(profiles[(state>>32)%len(profiles)])
        estimates.append(best(sample))
    estimates.sort()
    if not (estimates[4]>0 or estimates[195]<0) or abs(estimates[4])>=14 or abs(estimates[195])>=14:return None
    return '近期'+('回暖' if first>0 else '降温')+'较往年'+('提前' if selected>0 else '推迟')+f'约{abs(selected)}天'


def selftest():
    profile={i:20-i*.2 for i in range(-31,32)}
    current=[20-(i+5)*.2 for i in range(-13,1)]
    assert timing(current,[profile]*11)=='近期降温较往年提前约5天'
    assert timing([15]*14,[profile]*11) is None
    assert timing(current[:5],[profile]*11) is None
    uncertain=[{i:20-i*.2+(y-5)*2 for i in range(-31,32)} for y in range(11)]
    assert timing([20-(i+2)*.2 for i in range(-13,1)],uncertain) is None
    print('PASS: stable trend, flat trend, missing days and uncertain timing cases')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--history',type=Path,required=True);p.add_argument('--at',default='2025-11-19T15:00')
    a=p.parse_args();selftest()
    spec=importlib.util.spec_from_file_location('reference',Path(__file__).with_name('check-thermal-history.py'))
    reference=importlib.util.module_from_spec(spec);spec.loader.exec_module(reference)
    index=json.loads((a.history/'index.json').read_text());date=dt.datetime.fromisoformat(a.at)
    cache={}
    def regional(year,offset):
        centre=date.replace(year=year);at=centre+dt.timedelta(days=offset)
        if at.year!=year:return None
        entry=next(e for e in index['years'] if e['year']==year)
        if year not in cache:cache[year]=(a.history/entry['file']).read_bytes()
        hour=int((at-dt.datetime(year,1,1)).total_seconds()/3600)
        return statistics.mean(reference.apparent(*(v/100 for v in struct.unpack_from('<hHH',cache[year],(point*entry['hours']+hour)*6))) for point in range(len(index['points'])))
    observed=[regional(date.year,i) for i in range(-13,1)]
    profiles=[]
    for entry in index['years']:
        if entry['year']>=date.year:continue
        profile={i:regional(entry['year'],i) for i in range(-27,15)}
        if all(v is not None for v in profile.values()):profiles.append(profile)
    result=dict(replayDate=date.isoformat(),recentDays=len(observed),referenceYears=len(profiles),
        seasonalMessage=timing(observed,profiles),
        note='Historical local-formula replay only. A null timing message deliberately means no reliable early/late claim.')
    print(json.dumps(result,ensure_ascii=False,indent=2))
