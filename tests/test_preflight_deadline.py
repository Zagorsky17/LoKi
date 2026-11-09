#!/usr/bin/env python3
"""Exercise the stock BusyBox query watchdog with real Linux subprocesses."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


class QueryDeadline(unittest.TestCase):
    def query(self, expression):
        binary = shutil.which('ucode')
        self.assertIsNotNone(binary)
        process = subprocess.run([binary, '-L', str(ROOT/'loki/files/usr/lib'), '-e',
                                  'let e=require("core.exec");'+expression],
                                 capture_output=True, text=True, timeout=6)
        self.assertEqual(process.returncode, 0, process.stderr)
        return json.loads(process.stdout)

    def test_success_and_exit_status_survive_the_watchdog(self):
        self.assertEqual(self.query('print(sprintf("%J",e.deadline(["/bin/sh","-c","printf safe; exit 7"],1,1024)));'),
                         {'status': 7, 'output': 'safe'})

    def test_hung_group_is_killed_and_private_watchdog_files_are_removed(self):
        value = self.query('let fs=require("fs");let pid=require("core.common").own_pid();'
                           'let result=e.deadline(["/bin/sh","-c","sleep 30 & wait"],1,1024);'
                           'assert(length(filter(fs.glob("/tmp/loki-query.*"),(path)=>index(path,"/tmp/loki-query."+pid+".")==0))==0);'
                           'print(sprintf("%J",result));')
        self.assertNotEqual(value['status'], 0)

    def test_output_budget_and_invalid_bounds_cannot_report_success(self):
        value = self.query('print(sprintf("%J",e.deadline(["/bin/sh","-c","head -c 2048 /dev/zero"],1,1024)));')
        self.assertTrue(value['output_limit'])
        self.assertEqual(self.query('print(sprintf("%J",e.deadline(["/bin/true"],0,1024)));'),
                         {'status': 1, 'output': ''})


if __name__ == '__main__':
    if sys.platform != 'linux': raise SystemExit('Run these checks only on the Linux server')
    unittest.main()
