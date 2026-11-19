#!/usr/bin/env python3
"""Resource, geometry, replay and layout-space checks; not a Swift render test."""
import json
import math
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]


class ThermalMapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder=ROOT/'Widgets/Resources/ThermalMap'
        cls.g=json.loads((cls.folder/'geometry.json').read_text())
        cls.replay=json.loads((cls.folder/'replay.json').read_text())

    def test_sourced_geometry_bounds_and_regions(self):
        self.assertEqual({r['name'] for r in self.g['regions']},{'jiangsu','zhejiang','shanghai'})
        west,south,east,north=self.g['bounds']
        self.assertLess(west,east);self.assertLess(south,north)
        for r in self.g['regions']:
            for p in r['polygons']:
                for ring in p:
                    self.assertGreaterEqual(len(ring),4)
                    self.assertEqual(ring[0],ring[-1])
                    self.assertTrue(all(west<=x<=east and south<=y<=north for x,y in ring))

    def test_exact_ten_lowercase_labels(self):
        self.assertEqual([l['name'] for l in self.g['labels']],
            ['suzhou','xuzhou','suqian','nanjing','changzhou','wenzhou','ningbo','shanghai','lishui','qiandaohu'])
        self.assertTrue(all(l['name']==l['name'].lower() for l in self.g['labels']))

    def test_replay_is_explicitly_archived_and_preserves_width_cap(self):
        self.assertTrue(self.replay['date'].startswith('2025-11-19T15:00:00'))
        self.assertEqual(self.replay['source'],'local')
        self.assertEqual(len(self.replay['points']),100)
        self.assertTrue(all(b['upper']-b['lower']<=3.000000001 for b in self.replay['bands']))
        self.assertEqual(sum(b['pointCount'] for b in self.replay['bands']),100)
        self.assertTrue(all(0<=p['bandIndex']<len(self.replay['bands']) for p in self.replay['points']))

    def test_published_solar_term_tables_and_display_contract(self):
        import re,datetime
        source=(ROOT/'Shared/SolarTermCalendar.swift').read_text()
        names=['小寒','大寒','立春','雨水','惊蛰','春分','清明','谷雨','立夏','小满','芒种','夏至',
               '小暑','大暑','立秋','处暑','白露','秋分','寒露','霜降','立冬','小雪','大雪','冬至']
        events=[]
        for year in [2025,2026,2027]:
            match=re.search(str(year)+r': \[([0-9,]+)\]',source)
            days=[int(v) for v in match.group(1).split(',')]
            self.assertEqual(len(days),24)
            events.extend((datetime.date(year,i//2+1,day),names[i]) for i,day in enumerate(days))
        def label(date):
            for day,name in events:
                if date==day:return name
            before=max((d,n) for d,n in events if d<date)
            after=min((d,n) for d,n in events if d>date)
            return before[1]+'—'+after[1]
        self.assertEqual(label(datetime.date(2026,11,19)),'立冬—小雪')
        self.assertEqual(label(datetime.date(2026,11,22)),'小雪')
        self.assertEqual(label(datetime.date(2026,12,31)),'冬至—小寒')
        self.assertIn('SolarTermCalendar.status(at:display.date).label',(ROOT/'Shared/ThermalMapView.swift').read_text())

    def test_projection_roundtrip(self):
        w,s,e,n=self.g['bounds']
        def merc(y):return math.log(math.tan(math.pi/4+math.radians(y)/2))
        for l in self.g['labels']:
            x=(l['longitude']-w)/(e-w);y=(merc(n)-merc(l['latitude']))/(merc(n)-merc(s))
            lon=w+x*(e-w);lat=math.degrees(2*math.atan(math.exp(merc(n)-y*(merc(n)-merc(s))))-math.pi/2)
            self.assertAlmostEqual(lon,l['longitude']);self.assertAlmostEqual(lat,l['latitude'])

if __name__=='__main__':unittest.main()
