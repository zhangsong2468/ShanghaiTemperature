#!/usr/bin/env python3
"""Check integration membership, then optionally verify one real five-point API request."""
import argparse
import datetime as dt
import json
import math
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
POINTS=[(34.4,120.2),(32.3,121.8),(30.8,122.4),(29.5,122.6),(28.3,121.9)]

def check(rows,now):
    assert isinstance(rows,list) and len(rows)==len(POINTS),'Expected five marine responses'
    seen=set();valid=0
    for (lat,lon),row in zip(POINTS,rows):
        assert abs(row['latitude']-lat)<=.25 and abs(row['longitude']-lon)<=.25
        units=row['current_units'];values=row['current']
        assert units['time']=='unixtime' and units['ocean_current_velocity']=='m/s' and units['ocean_current_direction']=='°'
        speed=values['ocean_current_velocity'];direction=values['ocean_current_direction']
        if speed is None or direction is None:continue
        assert math.isfinite(speed) and speed>=0 and math.isfinite(direction) and 0<=direction<=360
        assert 0<=now-values['time']<=3600,'Current model timestamp not within the last hour'
        cell=(row['latitude'],row['longitude']);assert cell not in seen;seen.add(cell);valid+=1
        print(f"{cell[0]:.5f}, {cell[1]:.5f}: {speed:.2f} m/s, heading {direction:.0f}°, valid {dt.datetime.fromtimestamp(values['time'],dt.timezone(dt.timedelta(hours=8))).isoformat()}")
    assert valid>0,'No valid model currents'
    print(f'PASS: {valid}/5 valid instantaneous model samples; no 24-hour averaging')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--live',action='store_true');p.add_argument('--json',type=Path);p.add_argument('--at',type=float);args=p.parse_args()
    view=(ROOT/'Shared/ThermalMapView.swift').read_text()
    provider=(ROOT/'Widgets/RegionalThermalMapWidget.swift').read_text()
    assert view.index('drawCoastalCurrents(context:&context')<view.index('var occupied=drawRanges(')
    assert 'guard !appPresentation,!display.isReplay,let coastalCurrents' in view
    assert 'dates.append(currents.expiresAt)' in provider
    assert 'currentUpdate.refreshAfter' in provider
    for f in (ROOT/'App').glob('*.swift'):
        assert 'CoastalCurrentStore.shared' not in f.read_text(),str(f)
    print('PASS: widget-only acquisition, below-label rendering, expiration timeline and refresh policy')
    if args.json:check(json.loads(args.json.read_text()),args.at or dt.datetime.now(dt.timezone.utc).timestamp())
    if args.live:
        params={'latitude':','.join(str(v[0]) for v in POINTS),'longitude':','.join(str(v[1]) for v in POINTS),
            'current':'ocean_current_velocity,ocean_current_direction','wind_speed_unit':'ms','timezone':'Asia/Shanghai',
            'timeformat':'unixtime','forecast_days':1,'cell_selection':'sea'}
        url='https://marine-api.open-meteo.com/v1/marine?'+urllib.parse.urlencode(params)
        try:
            with urllib.request.urlopen(url,timeout=30) as response:rows=json.load(response)
            check(rows,dt.datetime.now(dt.timezone.utc).timestamp())
        except urllib.error.HTTPError as error:
            raise SystemExit(f'HTTP {error.code}: '+error.read().decode(errors='replace'))
