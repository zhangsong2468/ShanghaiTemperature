#!/usr/bin/env python3
"""Small real API integration check. No keys, no certificate bypass, no big download."""
import datetime as dt
import json
import math
import sys
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo


def fetch(host,path,start,end,historical):
    params=dict(latitude='31.25,30.25',longitude='121.5,120.25',start_date=start.isoformat(),end_date=end.isoformat(),
        hourly='temperature_2m,relative_humidity_2m,wind_speed_10m,apparent_temperature',timezone='Asia/Shanghai',
        temperature_unit='celsius',wind_speed_unit='ms')
    if historical:params.update(models='era5',cell_selection='nearest',elevation=','.join(['nan']*len(params['latitude'].split(','))))
    url='https://'+host+path+'?'+urllib.parse.urlencode(params)
    with urllib.request.urlopen(url,timeout=45) as r:rows=json.load(r)
    if not isinstance(rows,list) or len(rows)!=2:raise ValueError('Expected two coordinate responses')
    expected=(end-start).days*24+24
    first=start.isoformat()+'T00:00';last=end.isoformat()+'T23:00'
    fields={'temperature_2m':'°C','relative_humidity_2m':'%','wind_speed_10m':'m/s','apparent_temperature':'°C'}
    for row in rows:
        if row['timezone']!='Asia/Shanghai':raise ValueError('Wrong timezone')
        h=row['hourly']
        if len(h['time'])!=expected or h['time'][0]!=first or h['time'][-1]!=last:raise ValueError('Unexpected date range')
        for key,unit in fields.items():
            if row['hourly_units'][key]!=unit:raise ValueError('Wrong unit for '+key)
            if len(h[key])!=expected or any(v is None or not math.isfinite(v) for v in h[key]):raise ValueError('Missing/invalid '+key)
    print('PASS:',host,'2 coordinates,',expected,'hours each, air/humidity/wind/apparent fields and units')


if __name__=='__main__':
    try:
        today=dt.datetime.now(ZoneInfo('Asia/Shanghai')).date()
        fetch('api.open-meteo.com','/v1/forecast',today-dt.timedelta(days=13),today,False)
        # Same 69-day coverage used by the normal historical warm-up, two points only.
        centre=dt.date(2025,today.month,min(today.day,28) if today.month==2 else today.day)
        fetch('archive-api.open-meteo.com','/v1/archive',centre-dt.timedelta(days=34),centre+dt.timedelta(days=34),True)
    except urllib.error.HTTPError as error:
        print("FAIL: HTTP",error.code,error.read().decode("utf-8",errors="replace"),file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        print('FAIL:',type(error).__name__,str(error),file=sys.stderr)
        sys.exit(1)
