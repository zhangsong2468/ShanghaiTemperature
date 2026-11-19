#!/usr/bin/env python3
"""Offline release checks: original archive hashes and real archived-date replays."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
archive=ROOT/'Widgets/Resources/WeatherHistory'
index=json.loads((archive/'index.json').read_text())
assert [y['year'] for y in index['years']]==list(range(2015,2026))
assert len(index['points'])==100
samples=0
for y in index['years']:
    path=archive/y['file']
    assert path.stat().st_size==y['bytes']==y['hours']*100*6
    assert hashlib.sha256(path.read_bytes()).hexdigest()==y['sha256'],path
    samples+=y['hours']*100
assert samples==9643200
print('PASS: all 11 historical binary hashes; 9,643,200 complete point-hours',flush=True)
# Dates selected from actual 2025 regional daily-median diagnostics: smallest
# spatial spread, largest spatial spread, coldest and hottest regional medians.
for label,date in [('small-spread','2025-11-20'),('large-spread','2025-03-02'),('cold','2025-02-08'),('hot','2025-07-05')]:
    result=subprocess.check_output([sys.executable,str(ROOT/'scripts/check-thermal-bands.py'),
        '--history',str(archive),'--at',date+'T15:00'],text=True)
    data=json.loads(result)
    assert data['bandCount']==len(data['cuts'])+1
    assert all(0<=v<=3.00000001 for v in data['widths'])
    assert sum(data['pointCounts'])==100
    assert all(y<2025 for y in data['historicalYears'])
    print(f"PASS: {label} {date} historical replay, {data['bandCount']} bands, max width {max(data['widths']):.3f}°C",flush=True)
print('NOTE: these checks do not certify Swift, live API operation or WidgetKit rendering.')
