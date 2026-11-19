#!/usr/bin/env python3
"""Package complete hourly source samples; no aggregation or fitted thresholds."""
import argparse
import calendar
import datetime as dt
import gzip
import hashlib
import json
import math
from pathlib import Path
import struct
import tempfile
import time

FIELDS = ['temperature_2m', 'relative_humidity_2m', 'wind_speed_10m']
RECORD = struct.Struct('<hHH')


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): result.update(chunk)
    return result.hexdigest()


def encode(t, rh, wind):
    values = [t, rh, wind]
    for value, (low, high) in zip(values, [(-90, 65), (0, 100), (0, 150)]):
        if not isinstance(value, (int, float)) or not math.isfinite(value) or not low <= value <= high:
            raise ValueError('Invalid weather value')
        if abs(value * 100 - round(value * 100)) > 1e-6:
            raise ValueError('Source has precision finer than 0.01; refusing lossy conversion')
    return RECORD.pack(*(round(value * 100) for value in values))


def validate(payload, year):
    if payload.get('timezone') != 'Asia/Shanghai': raise ValueError('Wrong timezone')
    for key, unit in zip(FIELDS, ['°C', '%', 'm/s']):
        if payload['hourly_units'].get(key) != unit: raise ValueError('Wrong units')
    h = payload['hourly']
    count = (366 if calendar.isleap(year) else 365) * 24
    if any(len(h[key]) != count for key in ['time'] + FIELDS): raise ValueError('Incomplete year')
    start = dt.datetime(year, 1, 1)
    for i, text in enumerate(h['time']):
        if text != (start + dt.timedelta(hours=i)).isoformat(timespec='minutes'):
            raise ValueError('Missing, duplicate or unordered hour')
    return count


def build(source, output, start, end):
    source_spec = json.loads((source / 'manifest.json').read_text())
    points = source_spec['points']
    if source_spec['model'] != 'era5' or source_spec['fields'] != FIELDS: raise ValueError('Wrong source model/fields')
    if len({p['id'] for p in points}) != len(points): raise ValueError('Duplicate point ID')
    if len({(p['latitude'], p['longitude']) for p in points}) != len(points): raise ValueError('Duplicate point')
    missing = [f"{p['id']}-{y}.json.gz" for y in range(start, end + 1) for p in points
               if not (source/'raw'/f"{p['id']}-{y}.json.gz").is_file()]
    if missing: raise ValueError(f'{len(missing)} missing fragments; first: {missing[0]}')
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        old = json.loads((output/'index.json').read_text())
        if old.get('schema') != 1 or old.get('points') != points:
            raise ValueError('Existing output belongs to a different schema/grid')
    # Full build/verification in staging; partial results never replace a dataset.
    with tempfile.TemporaryDirectory(prefix='.history-build-', dir=output.parent) as folder:
        stage = Path(folder)
        index = dict(schema=1, model='era5', timezone='Asia/Shanghai', recordBytes=6,
                     scales=[100,100,100], fields=FIELDS, units=['°C','%','m/s'],
                     ordering='point-major/hour-major', points=points, years=[],
                     source='https://open-meteo.com/en/docs/historical-weather-api',
                     license='CC BY 4.0', labels=source_spec['labels'])
        source_cells = set()
        for year in range(start,end+1):
            filename=f'{year}.bin'; target=stage/filename
            sources=[];hours=(366 if calendar.isleap(year) else 365)*24
            with target.open('wb') as stream:
                for point in points:
                    original=source/'raw'/f"{point['id']}-{year}.json.gz"
                    with gzip.open(original,'rt') as raw: wrapper=json.load(raw)
                    if wrapper['point'] != point or wrapper['year'] != year or wrapper['model'] != 'era5':
                        raise ValueError(f'Provenance mismatch: {original.name}')
                    payload=wrapper['payload'];validate(payload,year)
                    cell=(payload['latitude'],payload['longitude'])
                    if year==start: source_cells.add(cell)
                    sources.append(dict(file=original.name,sha256=digest(original),latitude=cell[0],longitude=cell[1]))
                    h=payload['hourly']
                    for values in zip(*(h[f] for f in FIELDS)): stream.write(encode(*values))
            size=hours*len(points)*RECORD.size
            if target.stat().st_size != size: raise ValueError('Packed size mismatch')
            index['years'].append(dict(year=year,file=filename,hours=hours,bytes=size,sha256=digest(target),sourceFragments=sources))
            print(f'Packed {year}: {len(points)} points × {hours} hours, {size:,} bytes',flush=True)
        if len(source_cells)!=len(points): raise ValueError('Source requests resolved to duplicate model cells')
        (stage/'index.json').write_text(json.dumps(index,ensure_ascii=False,indent=2)+'\n')
        (stage/'SOURCE.txt').write_text('Weather data by Open-Meteo: https://open-meteo.com/\nERA5 reanalysis, CC BY 4.0: https://creativecommons.org/licenses/by/4.0/\nConverted to indexed fixed-point binary without dropping samples or changing supplied numeric precision.\n')
        # Exhaustive read-back comparison of all three values against original data.
        total=0
        for entry in index['years']:
            data=(stage/entry['file']).read_bytes()
            for point_index,point in enumerate(points):
                with gzip.open(source/'raw'/f"{point['id']}-{entry['year']}.json.gz",'rt') as stream:
                    h=json.load(stream)['payload']['hourly']
                for hour,values in enumerate(zip(*(h[f] for f in FIELDS))):
                    decoded=RECORD.unpack_from(data,(point_index*entry['hours']+hour)*6)
                    if any(abs(v/100-raw)>1e-8 for v,raw in zip(decoded,values)):
                        raise ValueError('Read-back does not reproduce source values')
                    total+=1
            print(f"Verified every sample in {entry['year']}",flush=True)
        output.mkdir(exist_ok=True)
        # Year files can be atomically replaced; index is committed last.
        for path in stage.iterdir():
            if path.name != 'index.json': path.replace(output/path.name)
        (stage/'index.json').replace(output/'index.json')
    benchmark(output,index)
    print(f'COMPLETE: {total:,} hourly samples, {total*3:,} original values, {total*6:,} binary bytes',flush=True)


def benchmark(output,index):
    import mmap
    maps=[];streams=[]
    began=time.perf_counter()
    try:
        for year in index['years']:
            stream=(output/year['file']).open('rb');streams.append(stream)
            maps.append(mmap.mmap(stream.fileno(),0,access=mmap.ACCESS_READ))
        checksum=0
        # 100 repeats of a typical query: all 100 points for one hour in 11 years.
        for _ in range(100):
            for data,year in zip(maps,index['years']):
                for point in range(len(index['points'])):
                    checksum+=RECORD.unpack_from(data,(point*year['hours']+12)*6)[0]
        ms=(time.perf_counter()-began)*1000/100
    finally:
        for data in maps:data.close()
        for stream in streams:stream.close()
    report=dict(query='one corresponding hour, all points, all years',averageMilliseconds=ms,
                implementation='Python mmap, 100 repeats, includes initial mapping; not a WidgetKit runtime benchmark',
                checksum=checksum,samples=sum(y['hours']*len(index['points']) for y in index['years']),
                binaryBytes=sum(y['bytes'] for y in index['years']))
    (output.parent/'history-pack-verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'Indexed lookup benchmark: {ms:.3f} ms/query (Python, not Swift)',flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True)
    p.add_argument('--output',type=Path,default=Path(__file__).resolve().parents[1]/'Widgets/Resources/WeatherHistory')
    p.add_argument('--start',type=int,default=2015);p.add_argument('--end',type=int,default=2025)
    a=p.parse_args()
    if not 1940<=a.start<=a.end<=2025:p.error('Invalid historical range')
    build(a.source,a.output,a.start,a.end)
