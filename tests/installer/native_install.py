#!/usr/bin/env python3
"""Exercise the upstream SSH workflow against isolated package-manager fixtures."""
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT/'install.sh').read_text().rsplit('\nmain "$@"', 1)[0]
PM = r'''import json,os,re,sys
from pathlib import Path
home=Path(os.environ['NATIVE_INSTALL_TEST']);kind=Path(sys.argv[0]).name;args=sys.argv[1:]
state=json.loads((home/'state.json').read_text());versions=state['versions']
with (home/'events').open('a') as f:f.write(json.dumps([kind,*args])+'\n')
def save():
 info=home/'info';info.mkdir(exist_ok=True)
 for p in info.glob('*.control'):p.unlink()
 (home/'state.json').write_text(json.dumps(state));apk=[];ipk=[]
 for name,v in versions.items():
  deps='libc';provides='ip=6.18.0-r2' if name=='ip-tiny' else ''
  url='https://github.com/Zagorsky17/LoKi' if name in ['loki','luci-app-loki','loki-core'] else 'https://openwrt.org'
  (info/(name+'.control')).write_text('URL: '+url+'\n')
  apk.append(f'P:{name}\nV:{v}\nU:{url}\nD:{deps}\np:{provides}\nI:1024\n\n')
  ipk.append(f'Package: {name}\nVersion: {v}\nURL: {url}\nDepends: {deps}\nProvides: {provides.split("=")[0]}\nStatus: install ok installed\n\n')
 (home/'installed').write_text(''.join(apk));(home/'status').write_text(''.join(ipk))
 (home/'world').write_text('\n'.join(versions)+'\n')
if not args:save();raise SystemExit(0)
if args[:2]==['version','-t'] or args[0]=='compare-versions':
 def v(x):return tuple(map(int,re.findall(r'[0-9]+',x)))
 a,b=v(args[2] if kind=='apk' else args[1]),v(args[3]);order='<' if a<b else '>' if a>b else '='
 if kind=='apk':print(order)
 else:raise SystemExit(0 if (args[2],order) in [('=','='),('<<','<')] else 1)
 raise SystemExit(0)
if args[0] in ['info','list-installed']:raise SystemExit(0)
if args[0]=='print-architecture':print('arch all 1\narch '+state['arch']+' 100');raise SystemExit(0)
if args[0]=='update':raise SystemExit(0)
if args[0]=='adbdump':
 row=state['controls'][Path(args[1]).name]
 print('info:\n  name: '+row['name']+'\n  version: '+row['version']+'\n  arch: '+row['arch']+'\n  installed-size: 4096\n  depends:')
 for d in row['depends'].split():print('    - '+d)
 raise SystemExit(0)
operation=next((x for x in args if x in ['add','install','del','remove']),None)
if operation is None:raise SystemExit('unexpected PM command: '+repr(args))
items=[];skip=False
for arg in args[args.index(operation)+1:]:
 if skip:skip=False;continue
 if arg in ['--repositories-file','--logfile','--cache-dir']:skip=True;continue
 if not arg.startswith('-'):items.append(arg)
simulate='--simulate' in args or '--noaction' in args
packages=[state['controls'][Path(x).name]['name'] if '/' in x else x for x in items]
if state['failure']=='plan' and simulate and any('/' in x for x in items):
 print('Cannot satisfy dependencies');raise SystemExit(1)
if state['failure']=='dependency' and not simulate and 'ucode-mod-socket' in packages:raise SystemExit(1)
if state['failure']=='apply' and not simulate and any('/' in x for x in items):raise SystemExit(1)
for i,(item,name) in enumerate(zip(items,packages),1):
 version=state['controls'][Path(item).name]['version'] if '/' in item else '1'
 remove=operation in ['del','remove']
 if kind=='apk':print(f'({i}/{len(items)}) '+('Purging' if remove else 'Installing')+f' {name} ({version})')
 else:print(('Removing package' if remove else 'Installing')+f' {name} ({version}) on root.')
 if not simulate:
  if remove:versions.pop(name,None)
  else:versions[name]=version
if kind=='apk':print('OK: 1.0 MiB in '+str(len(versions))+' packages')
if not simulate:save()
'''


class NativeInstall(unittest.TestCase):
    def run_case(self, kind, arch, failure='', current=False, uninstall=False, outdated=False):
        with tempfile.TemporaryDirectory(prefix='loki-native-install-') as directory:
            home=Path(directory);binaries=home/'bin';binaries.mkdir();assets=home/'assets';assets.mkdir()
            for name in [kind]:
                path=binaries/name;path.write_text('#!'+sys.executable+'\n'+PM);path.chmod(0o755)
            controls={};ext='apk' if kind=='apk' else 'ipk'
            for name,version,architecture,deps in [
                ('loki','2.0.2','all','libc ucode-mod-socket ip loki-core'),
                ('luci-app-loki','2.0.2','all','libc loki'),
                ('loki-core','1.14.4-r10',arch,'libc')]:
                filename=(f'{name}_{version}_base_{arch}.{ext}' if name=='loki-core' else f'{name}_{version}_all.{ext}')
                row=controls[filename]=dict(name=name,version=version,arch=architecture,depends=deps)
                if kind=='apk':(assets/filename).write_bytes(b'fixture-package\n')
                else:
                    control='Package: '+name+'\nVersion: '+version+'\nArchitecture: '+architecture+'\nInstalled-Size: 4096\nDepends: '+', '.join(deps.split())+'\n'
                    inner=io.BytesIO()
                    with tarfile.open(fileobj=inner,mode='w:gz') as t:
                        body=control.encode();info=tarfile.TarInfo('./control');info.size=len(body);t.addfile(info,io.BytesIO(body))
                    with tarfile.open(assets/filename,'w:gz') as t:
                        body=inner.getvalue();info=tarfile.TarInfo('./control.tar.gz');info.size=len(body);t.addfile(info,io.BytesIO(body))
            versions={'libc':'1','ip-tiny':'6.18.0-r2','unrelated':'42'}
            if current or outdated:versions.update({'loki':'2.0.2','luci-app-loki':'2.0.2','loki-core':'1.14.4-r10','ucode-mod-socket':'1'})
            if outdated:versions.update({'loki':'2.0.1','luci-app-loki':'2.0.1'})
            state=dict(arch=arch,versions=versions,controls=controls,failure=failure)
            (home/'state.json').write_text(json.dumps(state));env=dict(os.environ,NATIVE_INSTALL_TEST=str(home),PATH=str(binaries)+':'+os.environ['PATH'])
            subprocess.run([str(binaries/kind)],env=env,check=True,capture_output=True)
            (home/'arch').write_text(arch+'\n');(home/'variant').write_text('base\n');(home/'openwrt_release').write_text("DISTRIB_RELEASE='"+('25.12.6' if kind=='apk' else '24.10.4')+"'\nDISTRIB_ARCH='"+arch+"'\n")
            sums=''.join(hashlib.sha256((assets/n).read_bytes()).hexdigest()+'  '+n+'\n' for n in controls)
            if failure=='checksum':sums=sums.replace(sums[:64],'0'*64,1)
            (assets/'SHA256SUMS').write_text(sums)
            source=SOURCE
            mappings={'/etc/openwrt_release':'openwrt_release','/lib/apk/db/installed':'installed','/usr/lib/opkg/status':'status','/usr/lib/opkg/info':'info','/etc/apk/arch':'arch','/etc/apk/world':'world','/usr/share/loki-core/variant':'variant','/var/lock/loki-package-install.lock':'lock','/etc/config/loki':'config/loki','/etc/init.d/loki':'init/loki','/usr/bin/loki':'owned-bin/loki','/usr/lib/loki':'owned-lib/loki','/usr/share/loki':'owned-share/loki','/www/luci-static/resources/view/loki':'owned-www/loki','/etc/loki-core':'core-config'}
            for original,relative in mappings.items():source=source.replace(original,str(home/relative))
            source=source.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin','PATH='+shlex.quote(str(binaries))+':/usr/sbin:/usr/bin:/sbin:/bin',1)
            shell=home/'install.sh'
            shell.write_text(source+f'''
LOG={shlex.quote(str(home/'log'))}
id() {{ echo 0; }}
uci() {{ echo en; }}
pidof() {{ return 1; }}
free_kb() {{ echo 1048576; }}
mem_available_kb() {{ echo 65536; }}
fetch_release() {{ F_VERSION=2.0.2; F_TAG=2.0.2; F_CORE_MIN=1.14.4-r9; C_VERSION=1.14.4-r10; C_TAG=2.0.2; C_LOKI_MIN=2.0.2; cp {shlex.quote(str(assets/'SHA256SUMS'))} "$WORK/$1.sums"; }}
fetch() {{ cp {shlex.quote(str(assets))}/"${{1##*/}}" "$2"; }}
asset_url() {{ printf 'https://fixture.invalid/%s' "$2"; }}
# Network and package scripts are exercised separately; this fixture delegates PM decisions.
check_config() {{ :; }}
network_hint() {{ echo fixture; }}
main {'--uninstall' if uninstall else ''} --lang en
''')
            done=subprocess.run(['/bin/sh',str(shell)],env=env,capture_output=True,text=True,timeout=15)
            final=json.loads((home/'state.json').read_text())['versions'];events=[json.loads(x) for x in (home/'events').read_text().splitlines()]
            self.assertEqual(final['unrelated'],'42')
            if failure:
                self.assertNotEqual(done.returncode,0,done.stdout+done.stderr)
                self.assertNotIn('loki',final)
            elif uninstall:
                self.assertEqual(done.returncode,0,done.stdout+done.stderr)
                self.assertFalse({'loki','luci-app-loki','loki-core'}&final.keys())
                self.assertIn('ucode-mod-socket',final)
            else:
                self.assertEqual(done.returncode,0,done.stdout+done.stderr)
                self.assertEqual(final['loki'],'2.0.2');self.assertEqual(final['loki-core'],'1.14.4-r10')
                self.assertIn('ucode-mod-socket',final)
                if not current and not outdated:self.assertTrue(any(any(arch in arg for arg in event if '.apk' in arg or '.ipk' in arg) for event in events))
            self.assertFalse(any('--nodeps' in e or '--force-overwrite' in e for e in events))
            return events

    def test_native_installation_uses_architecture_and_both_package_managers(self):
        for kind in ['apk','opkg']:
            for arch in ['aarch64_cortex-a53','aarch64_generic','arm_cortex-a7_neon-vfpv4','mipsel_24kc','mips_24kc','x86_64']:
                with self.subTest(kind=kind,architecture=arch):self.run_case(kind,arch)

    def test_checksum_simulation_and_dependency_failures_never_report_an_installation(self):
        for kind in ['apk','opkg']:
            for failure in ['checksum','plan','dependency','apply']:
                with self.subTest(kind=kind,failure=failure):self.run_case(kind,'x86_64',failure=failure)

    def test_current_version_and_removal_preserve_other_packages(self):
        for kind in ['apk','opkg']:
            with self.subTest(kind=kind):
                self.run_case(kind,'x86_64',outdated=True)
                self.run_case(kind,'x86_64',current=True)
                self.run_case(kind,'x86_64',current=True,uninstall=True)


if __name__=='__main__':
    if sys.platform!='linux':raise SystemExit('Run on the Linux test server')
    unittest.main()
