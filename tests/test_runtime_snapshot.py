#!/usr/bin/env python3
"""Keep native UCI validation, core generation and nft generation on one model."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RuntimeSnapshot(unittest.TestCase):
    def test_an_independent_native_commit_cannot_replace_the_validated_model(self):
        with tempfile.TemporaryDirectory(prefix='loki-runtime-snapshot-') as directory:
            root = Path(directory)
            config, saved = root/'config', root/'saved'
            config.mkdir(mode=0o700)
            saved.mkdir(mode=0o700)
            (config/'loki').write_text("config settings 'settings'\n option dns_server '1.1.1.1'\n"
                                     " option bootstrap_dns_server '1.1.1.1'\n option source_network_interfaces 'br-lan'\n"
                                     f" option cache_path '{root}/private/cache.db'\n"
                                     "config section 'main'\n option action 'bypass'\n option destinations 'before.example'\n")
            program = r'''
let u=require("uci"),factory=u.cursor;
u.cursor=()=>factory(ARGV[0],ARGV[1],"");
let v=require("config.validator"),g=require("singbox.generator"),n=require("nft.apply");
let model=v.validate({core_tags:null});
let other=factory(ARGV[0],ARGV[1],"");assert(other.load("loki")===true);
assert(other.set("loki","main","destinations","after.example")===true);
assert(other.set("loki","settings","source_network_interfaces","eth9")===true);
assert(other.commit("loki")===true);
let core=sprintf("%J",g.build({controller_secret:sprintf("%064x",1),local_prefixes:[]},model));
let nft=n.build(model).script;
print(sprintf("%J",{old:index(core,"before.example")>=0,new:index(core,"after.example")>=0,
 old_interface:index(nft,"{ br-lan }")>=0,new_interface:index(nft,"{ eth9 }")>=0}));
'''
            result = subprocess.run([shutil.which('ucode'), '-L', str(ROOT/'loki/files/usr/lib'), '-e',
                                     program, str(config), str(saved)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            self.assertEqual(json.loads(result.stdout), dict(old=True, new=False, old_interface=True, new_interface=False))
            self.assertIn('after.example', (config/'loki').read_text())


if __name__ == '__main__':
    unittest.main()
