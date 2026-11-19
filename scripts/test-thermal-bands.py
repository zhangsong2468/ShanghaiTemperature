import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('bands',Path(__file__).with_name('thermal-bands-reference.py'))
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)

class DynamicBandsTests(unittest.TestCase):
    def setUp(self):
        self.points=[dict(id=f'p{i:03}',latitude=30+i*.1,longitude=120) for i in range(20)]
        self.history=[[[10+y+(p%2)*1.2+s*.2 for s in range(3)] for p in range(20)] for y in range(3)]
    def test_uniform_field_is_one_band(self):
        r=b.build(self.points,[10.]*20,self.history)
        self.assertEqual(r['cuts'],[])
        self.assertEqual(r['pointCounts'],[20])
    def test_small_difference_is_not_forced_into_five_bands(self):
        r=b.build(self.points,[10+i*.005 for i in range(20)],self.history)
        self.assertEqual(r['cuts'],[])
    def test_large_regions_split_without_fixed_celsius_boundaries(self):
        values=[0.]*7+[8.]*6+[16.]*7
        r=b.build(self.points,values,self.history)
        self.assertEqual(len(r['baseCuts']),2)
        self.assertTrue(all(width<=3+1e-9 for width in r['widths']))
        shifted=b.build(self.points,[v+1.37 for v in values],self.history)
        for old,new in zip(r['cuts'],shifted['cuts']):self.assertAlmostEqual(new-old,1.37)
        self.assertEqual(sum(r['pointCounts']),20)
    def test_hysteresis_retains_near_ties_but_allows_major_change(self):
        values=[0.]*10+[12.]*10
        old=b.build(self.points,values,self.history)
        stable=b.build(self.points,[v+.01 for v in values],self.history,old)
        self.assertTrue(stable['retainedPreviousCuts'])
        changed=b.build(self.points,[v+30 for v in values],self.history,old)
        self.assertFalse(changed['retainedPreviousCuts'])
    def test_width_cap_covers_empty_gaps_and_can_exceed_five_bands(self):
        values=[0.]*10+[30.]*10
        r=b.build(self.points,values,self.history)
        self.assertGreater(len(r['cuts'])+1,5)
        self.assertTrue(all(width<=3+1e-9 for width in r['widths']))
        self.assertAlmostEqual(sum(r['widths']),30)
        self.assertEqual(sum(r['pointCounts']),20)
    def test_invalid_history_and_duplicate_locations_fail(self):
        with self.assertRaises(ValueError):b.build(self.points,[0.]*20,[])
        points=self.points.copy();points[1]=points[0]
        with self.assertRaises(ValueError):b.build(points,[0.]*20,self.history)

if __name__=='__main__':unittest.main()
