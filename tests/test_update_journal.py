#!/usr/bin/env python3
"""Exercise durable update intents under the real inherited kernel lease."""

import json
import shlex
import sys
import unittest

import test_update_lock as lease_tests


class UpdateJournal(unittest.TestCase):
    def setUp(self):
        self.lease = lease_tests.UpdateLease()
        self.lease.setUp()
        self.addCleanup(self.lease.doCleanups)
        self.state = self.lease.root/'store/state.json'

    def worker(self, body):
        expression = '''
            let fs=require("fs"), l=require("service.lock"), u=require("service.update"), exec=require("core.exec");
            assert(l.adopt(ARGV[0],require("core.common").own_pid()));
            u.paths.lock=ARGV[0];u.paths.state=ARGV[1];u.paths.fsync=["/usr/bin/sync"];
            let plan=sprintf("%064d",1);
        ''' + body
        process=self.lease.spawn(expression,str(self.lease.lock),str(self.state),self.lease.binary,str(lease_tests.LIBRARY))
        stdout,stderr=process.communicate(timeout=15)
        self.assertEqual(process.returncode,0,stderr)
        self.assertEqual(stderr,'')
        return stdout

    def test_complete_intents_authorize_only_matching_live_worker_context(self):
        self.worker('''
            let value=u.begin("update",plan);assert(value!=null && u.pending());
            let child='let u=require("service.update");u.paths.lock=ARGV[0];u.paths.state=ARGV[1];assert(u.allowed()===(ARGV[2]=="yes"));';
            for(let valid in [false,true]) {
                let command=["env","LOKI_UPDATE_CONTEXT="+(valid?u.context(value):"wrong"),ARGV[2],"-L",ARGV[3],"-e",child,ARGV[0],ARGV[1],valid?"yes":"no"];
                assert(exec.run(command)==0);
            }
            assert(u.begin("update",plan)==null);
            assert(u.advance(value,"committed")==null);
            value=u.advance(value,"prepared");assert(value!=null);
            let stale=value;value=u.advance(value,"applying");assert(value!=null);
            assert(u.advance(stale,"applying")==null);
            value=u.advance(value,"health");assert(value!=null);
            value=u.advance(value,"committed");assert(value!=null && !u.pending());
            l.release(ARGV[0],require("core.common").own_pid());assert(u.allowed());
        ''')
        record=json.loads(self.state.read_text())
        self.assertEqual(record['phase'],'committed')
        self.assertEqual(self.state.stat().st_mode&0o777,0o600)

    def test_corrupt_duplicate_nul_or_truncated_records_never_grant_permission(self):
        self.worker(r'''
            let value=u.begin("install",plan);assert(value!=null);
            let saved=fs.readfile(ARGV[1]);
            let bad_owner=replace(saved,'"owner":'+sprintf("%J",value.owner),'"owner":'+sprintf("%J",value.owner+"\u0000"));
            let bad_hash=replace(saved,'"plan":'+sprintf("%J",plan),'"plan":'+sprintf("%J",substr(plan,0,30)+"\u0000"+substr(plan,31)));
            let cases=["{",saved+"synthetic-private-data",bad_owner,bad_hash,
                substr(saved,0,length(saved)-2)+',"phase":"committed"}\n'];
            for(let body in cases) {
                fs.writefile(ARGV[1],body);
                assert(u.read().error===true && u.pending() && !u.allowed());
                assert(u.start_admission()=="component-transaction-recovery-required");
                assert(u.begin("update",plan)==null);
                assert(fs.readfile(ARGV[1])==body);
            }
            fs.writefile(ARGV[1],saved);
            assert(u.advance(value,"aborted")!=null);
        ''')

    def test_worker_context_cannot_replace_verified_payload_and_fresh_admission(self):
        self.worker('''
            let value=u.begin("install",plan);assert(value!=null);
            let child='let u=require("service.update");u.paths.lock=ARGV[0];u.paths.state=ARGV[1];'
                +'let result=u.start_admission();assert(ARGV[2]=="missing-proof"?result!=null:result===ARGV[2]);';
            for(let phase in ["preparing","prepared","applying","health","rollback"]) {
                if(phase!="preparing"){value=u.advance(value,phase);assert(value!=null);}
                for(let valid in [false,true]) {
                    let expected=!valid?"component-transaction-recovery-required":
                        index(["health","rollback"],phase)>=0?"missing-proof":"component-transaction-start-not-ready";
                    assert(exec.run(["env","LOKI_UPDATE_CONTEXT="+(valid?u.context(value):"wrong"),
                        ARGV[2],"-L",ARGV[3],"-e",child,ARGV[0],ARGV[1],expected])==0);
                }
            }
            assert(u.advance(value,"rolled-back")!=null);
            assert(u.start_admission()=="installed-component-backup-unavailable");
        ''')

    def test_foreign_storage_and_failed_sync_preserve_data_without_an_intent(self):
        store=self.state.parent;store.mkdir(mode=0o700)
        foreign=store/'foreign';foreign.write_text('foreign-sentinel')
        self.worker('assert(u.begin("install",plan)==null);')
        self.assertEqual(foreign.read_text(),'foreign-sentinel')
        self.assertEqual(set(p.name for p in store.iterdir()),{'foreign'})
        foreign.unlink()
        self.worker('u.paths.fsync=["/bin/false"];assert(u.begin("install",plan)==null);assert(u.read()==null);')
        self.assertFalse(self.state.exists())
        self.worker('let v=u.begin("install",plan);assert(v!=null);assert(u.advance(v,"aborted")!=null);')

    def test_failed_parent_sync_retains_intent_and_new_worker_must_recover(self):
        sync=self.lease.root/'sync.sh'
        sync.write_text('if [ "$1" = '+shlex.quote(str(self.state.parent))+' ] && [ -f "$1/state.json" ]; then exit 1; fi\nexec /usr/bin/sync "$1"\n')
        self.worker('u.paths.fsync=["/bin/sh",'+json.dumps(str(sync))+'];'
                    'assert(u.begin("update",plan)==null);assert(u.read().phase=="preparing");assert(u.pending());')
        previous=json.loads(self.state.read_text())
        self.worker('let old=u.read();assert(!u.allowed());assert(u.advance(old,"aborted")==null);'
                    'let recovered=u.recover();assert(recovered!=null);'
                    'assert(recovered.id==old.id && recovered.owner!=old.owner);'
                    'assert(u.recover()==null);assert(u.advance(recovered,"aborted")!=null);')
        current=json.loads(self.state.read_text())
        self.assertEqual(current['id'],previous['id'])
        self.assertEqual(current['phase'],'aborted')

    def test_owned_temporary_is_cleaned_but_foreign_symlink_is_preserved(self):
        self.worker('let v=u.begin("install",plan);assert(v!=null);'
                    'fs.writefile(require("core.common").parent_dir(ARGV[1])+"/.state.new","partial");'
                    'fs.chmod(require("core.common").parent_dir(ARGV[1])+"/.state.new",0600);'
                    'assert(u.advance(v,"prepared")!=null);')
        foreign=self.lease.root/'foreign';foreign.write_text('foreign-sentinel')
        temporary=self.state.parent/'.state.new';temporary.symlink_to(foreign)
        self.worker('let v=u.recover();assert(v==null);assert(u.pending());')
        self.assertTrue(temporary.is_symlink())
        self.assertEqual(foreign.read_text(),'foreign-sentinel')

    def test_reboot_epoch_invalidates_old_context_even_when_pid_is_still_live(self):
        boot=self.lease.root/'boot';boot.write_text('00000000-0000-0000-0000-000000000001\n')
        self.worker('u.paths.boot='+json.dumps(str(boot))+';'
                    'let v=u.begin("update",plan);assert(v!=null);'
                    'fs.writefile(u.paths.boot,"00000000-0000-0000-0000-000000000002\\n");'
                    'assert(u.advance(v,"aborted")==null);'
                    'let next=u.recover();assert(next!=null && next.epoch!=v.epoch);'
                    'assert(u.advance(next,"aborted")!=null);')

    def test_no_owned_lease_cannot_create_an_intent_or_storage(self):
        result=self.lease.run_ucode('let u=require("service.update");u.paths.lock=ARGV[0];u.paths.state=ARGV[1];'
                                    'assert(u.allowed());assert(u.begin("install",sprintf("%064d",1))==null);',
                                    str(self.lease.lock),str(self.state))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.state.parent.exists())

    def test_failed_terminal_sync_keeps_the_recovery_barrier_after_owner_exit(self):
        sync=self.lease.root/'terminal-sync.sh'
        sync.write_text('if [ -f "$1/state.json" ] && grep -q \'"phase":"committed"\' "$1/state.json"; then exit 1; fi\nexec /usr/bin/sync "$1"\n')
        self.worker('u.paths.fsync=["/bin/sh",'+json.dumps(str(sync))+'];'
                    'let v=u.begin("update",plan);assert(v!=null);'
                    'v=u.advance(v,"prepared");assert(v!=null);'
                    'v=u.advance(v,"applying");assert(v!=null);'
                    'v=u.advance(v,"health");assert(v!=null);'
                    'assert(u.advance(v,"committed")==null);'
                    'assert(u.read().phase=="committed" && u.pending());assert(u.begin("update",plan)==null);')
        self.worker('assert(u.pending() && !u.allowed());let v=u.recover();'
                    'assert(v!=null && v.phase=="recovery-required");'
                    'v=u.advance(v,"rollback");assert(v!=null);'
                    'assert(u.advance(v,"rolled-back")!=null && !u.pending());')


if __name__=='__main__':
    if sys.platform!='linux':
        raise SystemExit('Run update journal checks only on the Linux test server')
    unittest.main()
