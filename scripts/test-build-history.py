import datetime as dt
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('history_pack',Path(__file__).with_name('build-history.py'))
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)

class HistoryPackingTests(unittest.TestCase):
    def test_signed_little_endian_and_exact_precision(self):
        packed=h.encode(-3.25,72.5,3.45)
        self.assertEqual(len(packed),6)
        self.assertEqual(h.RECORD.unpack(packed),(-325,7250,345))
    def test_rejects_missing_out_of_range_and_lossy_values(self):
        for args in [(None,50,1),(1,float('nan'),2),(66,50,1),(1,101,1),(1,50,-1),(1.001,50,1)]:
            with self.assertRaises(ValueError):h.encode(*args)
    def test_checks_every_hour_and_leap_year(self):
        start=dt.datetime(2024,1,1)
        hourly={'time':[(start+dt.timedelta(hours=i)).isoformat(timespec='minutes') for i in range(8784)]}
        hourly.update({k:[v]*8784 for k,v in zip(h.FIELDS,[1,50,2])})
        payload={'timezone':'Asia/Shanghai','hourly_units':dict(zip(h.FIELDS,['°C','%','m/s'])),'hourly':hourly}
        self.assertEqual(h.validate(payload,2024),8784)
        hourly['time'][1]=hourly['time'][0]
        with self.assertRaises(ValueError):h.validate(payload,2024)

if __name__=='__main__':unittest.main()
