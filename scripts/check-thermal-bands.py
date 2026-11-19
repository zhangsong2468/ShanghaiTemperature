#!/usr/bin/env python3
"""Historical replay using actual archived weather; never labelled live weather."""
import argparse
import datetime as dt
import importlib.util
import json
import mmap
from pathlib import Path
import struct
import time


def module(name,filename):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(filename))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--history',type=Path,required=True)
    p.add_argument('--at',default='2025-11-19T15:00')
    a=p.parse_args();date=dt.datetime.fromisoformat(a.at)
    ref=module('history_reference','check-thermal-history.py')
    bands=module('bands_reference','thermal-bands-reference.py')
    start=time.perf_counter()
    summary,years=ref.check(a.history,date,verbose=False)
    index=json.loads((a.history/'index.json').read_text())
    year=next(y for y in index['years'] if y['year']==date.year)
    hour=int((date-dt.datetime(date.year,1,1)).total_seconds()/3600)
    with (a.history/year['file']).open('rb') as stream:
        with mmap.mmap(stream.fileno(),0,access=mmap.ACCESS_READ) as data:
            current=[ref.apparent(*(v/100 for v in struct.unpack_from('<hHH',data,(i*year['hours']+hour)*6))) for i in range(len(index['points']))]
    hist=[y['windows'][summary['selectedDayRadius']] for y in years]
    result=bands.build(index['points'],current,hist)
    result.update(replayDate=date.isoformat(),historicalYears=summary['historicalYears'],
                  selectedDayRadius=summary['selectedDayRadius'],currentRange=[min(current),max(current)],
                  bandCount=len(result['cuts'])+1,elapsedSeconds=time.perf_counter()-start,
                  note='Real archived-date local-formula replay; not current weather, not Swift runtime verification.')
    result.pop('labels')
    print(json.dumps(result,ensure_ascii=False,indent=2))
