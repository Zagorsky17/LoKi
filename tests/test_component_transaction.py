#!/usr/bin/env python3
"""Run the common worker with real files/leases and a confined fake package manager."""
import json
import os
import subprocess
from pathlib import Path
import sys
import unittest

import test_prepare_candidate as kits
import test_update_lock as leases


class ComponentTransaction(unittest.TestCase):
    def setUp(self):
        self.lease = leases.UpdateLease(); self.lease.setUp(); self.addCleanup(self.lease.doCleanups)
        self.kit = kits.CandidatePreparation(); self.kit.setUp(); self.addCleanup(self.kit.doCleanups)
        self.prepared = self.kit.prepare()
        for role in self.kit.components['components']:
            if role['role'] != 'core': role['version'] = '2.0.1'
        self.kit.selected = self.kit.packages(self.kit.components)
        self.kit.output = self.kit.root/'next'
        self.next = self.kit.prepare()

    def worker(self, scenario):
        if scenario == 'same-version':
            self.kit.core_body += b'# a different own core build\n'
            self.kit.core.write_bytes(self.kit.core_body)
            self.kit.selected = self.kit.packages(self.kit.components)
            self.kit.output = self.kit.root/'next-variant'
            self.next = self.kit.prepare()
        code = r'''
let fs=require("fs"),u=require("service.update"),l=require("service.lock"),e=require("core.exec"),p=require("service.preflight");
let root=ARGV[0]; assert(l.adopt(root+"/install.lock",require("core.common").own_pid()));
u.paths.lock=root+"/install.lock";u.paths.state=root+"/store/state.json";u.paths.log=root+"/logs/install.log";
u.paths.fsync=["/usr/bin/sync"];u.paths.databases.ipk=root+"/status";u.paths.cli=root+"/loki";
u.paths.configurations=[root+"/configs/loki",root+"/configs/loki-core"];u.paths.payload_root=root+"/payload";
if(fs.lstat(root+"/configs")==null)assert(fs.mkdir(root+"/configs",0700));
if(fs.lstat(root+"/cache")==null)assert(fs.mkdir(root+"/cache",0700));
let baseline="Package: libc\nVersion: 1\nStatus: install ok installed\n\n";
if(fs.lstat(root+"/status")==null){fs.writefile(root+"/status",baseline);fs.chmod(root+"/status",0600);}
let phase="install",calls=[],fault="none";
let first=ARGV[1],next=ARGV[2],first_digest=ARGV[3],next_digest=ARGV[4],scenario=ARGV[5];
function content(directory) { return json(fs.readfile(directory+"/candidate-manifest.json")).components; }
let old=content(first),new=content(next);
function payload(components) {
    for(let component in components) for(let item in component.files) {
        let path=root+"/payload"+item.path;
        assert(require("core.common").ensure_dir(require("core.common").parent_dir(path)));
        if(item.type=="directory")require("core.common").ensure_dir(path);
        else {fs.writefile(path,item.path=="/usr/bin/loki-core"?fs.readfile((phase=="install"||u.read()?.phase=="rollback"?first:next)+"/candidate-core"):"synthetic payload\n");fs.chmod(path,item.mode);}
    }
}
function installed(components) {
    return baseline+join("",map(components,(c)=>"Package: "+c.package+"\nVersion: "+c.version+"\nStatus: install ok installed\n\n"));
}
let admission_phases=[];
p.collect=(root,manifest,config,scratch,source,digest,budget_phase)=>{
    push(admission_phases,budget_phase);
    if(budget_phase=="preparing"||budget_phase=="prepared")assert(u.read().phase==budget_phase);
    else assert(budget_phase==null||budget_phase=="start");
    return {result:"checked",complete:true,install_allowed:true};
};
let run=e.run,combined=e.combined;
function fake(argv) {
    let offset=index(argv,"opkg");
    if(offset>=0) {
        push(calls,slice(argv,offset));
        let removing=index(argv,"remove")>=0;
        let parts=phase=="install"?old:new;
        let rollback=u.read()?.phase=="rollback";
        if(rollback) parts=old;
        if(index(argv,"--noaction")>=0) {
            let output=join("",map(parts,(c)=>removing?"Removing package "+c.package+" from root...\n":"Installing "+c.package+" ("+c.version+") on root.\n"));
            if(fault=="foreign-plan") output+="Installing foreign-package (1) on root.\n";
            return {status:0,output};
        }
        if(fault=="interrupted" && !rollback){fs.writefile(root+"/status",installed([parts[0]]));exit(77);}
        if(fault=="rollback" && rollback)return {status:1,output:"rollback failure"};
        if((fault=="pm" || fault=="rollback") && !rollback) { fs.writefile(root+"/status",installed([parts[0]]));return {status:1,output:"controlled failure"}; }
        fs.writefile(root+"/status",removing?baseline:installed(parts));
        if(removing && fault=="removed-conffiles")for(let path in u.paths.configurations)fs.unlink(path);
        if(!removing)payload(parts);
        if(fault=="payload" && !rollback && phase=="update")fs.writefile(root+"/payload/usr/bin/loki-core","corrupt");
        if(!removing && !rollback) {
            for(let path in u.paths.configurations) if(fs.lstat(path)==null) {fs.writefile(path,"own configuration\n");fs.chmod(path,0600);}
        }
        if(!removing && !rollback && phase=="update" && fault=="concurrent")fs.writefile(u.paths.configurations[0],"concurrent B\n");
        if(!removing && !rollback && phase=="update" && fault=="defaults")fs.writefile(u.paths.configurations[0],"synthetic payload\n");
        return {status:0,output:"package operation complete\n"};
    }
    offset=index(argv,u.paths.cli);
    if(offset>=0) {
        let verb=argv[offset+1];push(calls,["cli",verb]);
        if(verb=="start" && index(["health","rollback"],u.read()?.phase)>=0) {
            let reject=scenario=="admission-health" && phase=="update" && u.read().phase=="health";
            let child='let fs=require("fs"),u=require("service.update"),p=require("service.preflight");let root=ARGV[0];'
                +'u.paths.lock=root+"/install.lock";u.paths.state=root+"/store/state.json";u.paths.databases.ipk=root+"/status";'
                +'u.paths.payload_root=root+"/payload";u.paths.configurations=[root+"/configs/loki",root+"/configs/loki-core"];'
                +'let checks=0;p.collect=(root,manifest,config,scratch,source,digest,budget_phase)=>{checks++;assert(digest==ARGV[1]);assert(budget_phase=="start");'
                +'return ARGV[2]=="refuse"?{result:"conflict",complete:false,install_allowed:false,observations:[{state:"conflict",reason:"reserved-port-in-use"}]}:{result:"checked",complete:true,install_allowed:true};};'
                +'assert(u.start_admission()==(ARGV[2]=="refuse"?"preflight-reserved-port-in-use":null));assert(checks==1);';
            let expected=u.read().phase=="rollback"||phase=="install"?first_digest:next_digest;
            assert(run(["env","LOKI_UPDATE_CONTEXT="+u.context(u.read()),ARGV[7],"-L",ARGV[8],"-e",child,root,expected,reject?"refuse":"allow"])==0);
            if(reject)return {status:1,output:"fresh admission refused"};
        }
        if(verb=="installer_snapshot")return {status:0,output:sprintf("%J",{running:true,enabled:false,cache_path:root+"/cache/cache.db"})};
        if(verb=="start" && u.read()?.phase=="health")fs.writefile(root+"/cache/cache.db","new cache state");
        if(verb=="initd_status" && fault=="health" && u.read()?.phase=="health")return {status:1,output:"not healthy"};
        return {status:0,output:""};
    }
    return null;
}
e.combined=(argv,limit)=>fake(argv)??combined(argv,limit);
e.run=(argv)=>{let result=fake(argv);return result==null?run(argv):result.status;};
if(scenario=="recover") {
    phase="update";
    assert(u.pending());let result=u.run_recovery();assert(result.success,sprintf("%J",result));
    assert(u.read().phase=="rolled-back" && !u.pending());
    assert(fs.readfile(root+"/status")==installed(old));
    assert(fs.readfile(root+"/cache/cache.db")=="old cache state");
}
else if(scenario=="memory-budget") {
    require("service.preflight_resources").collect=(root,components)=>{
        assert(root=="/" && length(components)==length(old));
        return [{kind:"resources",object:"candidate-capacity",state:"conflict",reason:"resource-candidate-memory-insufficient"}];
    };
    let result=u.run(first,"install",first_digest);
    assert(!result.success && result.reason=="resource-candidate-memory-insufficient",sprintf("%J",result));
    assert(length(calls)==0 && u.read()==null && fs.readfile(root+"/status")==baseline);
}
else if(scenario=="preflight") {
    p.collect=()=>({result:"incomplete",complete:false,install_allowed:false});
    let result=u.run(first,"install",first_digest);assert(!result.success && result.reason=="preflight-incomplete-or-conflicting");
    assert(length(calls)==0 && fs.readfile(root+"/status")==baseline && u.read()==null);
    p.collect=()=>({result:"conflict",complete:false,install_allowed:false,observations:[{state:"conflict",reason:"reserved-port-in-use"}]});
    result=u.run(first,"install",first_digest);assert(result.reason=="preflight-reserved-port-in-use");
    for(let reason in ["synthetic-secret uri://value","valid\u0000synthetic-secret"]) {
        p.collect=()=>({result:"incomplete",complete:false,install_allowed:false,observations:[{state:"incomplete",reason}]});
        result=u.run(first,"install",first_digest);assert(result.reason=="preflight-incomplete-or-conflicting");
    }
    assert(length(calls)==0 && u.read()==null);
}
else if(scenario=="preflight-late") {
    let checks=0;
    p.collect=()=>++checks==1?{result:"checked",complete:true,install_allowed:true}:
        {result:"conflict",complete:false,install_allowed:false,observations:[{state:"conflict",reason:"reserved-port-in-use"}]};
    let result=u.run(first,"install",first_digest);
    assert(!result.success && result.reason=="preflight-reserved-port-in-use",sprintf("%J",result));
    assert(checks==2 && u.read().phase=="aborted");
    assert(length(filter(calls,(argv)=>argv[0]=="opkg" && index(argv,"--noaction")<0))==0);
    assert(fs.readfile(root+"/status")==baseline);
}
else if(scenario=="checksum") {
    let result=u.run(first,"install",sprintf("%064d",1));assert(!result.success && length(calls)==0 && u.read()==null);
}
else {
    let result=u.run(first,"install",first_digest);assert(result.success,sprintf("%J",result));
    assert(sprintf("%J",admission_phases)==sprintf("%J",[null,"preparing","prepared"]),sprintf("%J",admission_phases));
    assert(u.read().phase=="committed");
    assert(u.installed().digest==first_digest,"installed proof must bind the private kit to current files and versions");
    assert(u.start_admission()==null,"installed payload must pass the same prepared admission");
    if(scenario=="success") {
        let binary=root+"/payload/usr/bin/loki-core",body=fs.readfile(binary);
        fs.writefile(binary,"synthetic-private-corruption");
        assert(u.start_admission()=="installed-component-set-unverified");
        fs.writefile(binary,body);
        let marker=root+"/store/active.sha256",digest=fs.readfile(marker);
        assert(fs.unlink(marker) && fs.symlink(root+"/configs/loki",marker));
        assert(u.start_admission()=="installed-component-backup-unavailable");
        assert(fs.unlink(marker) && require("core.common").write_private_file(marker,digest));
        assert(u.start_admission()==null,"a repaired verified kit must be checked again");
    }
    assert(index(join(" ",map(calls,(c)=>join(" ",c))),"--nodeps")>=0);
    fs.writefile(root+"/cache/cache.db","old cache state");fs.chmod(root+"/cache/cache.db",0600);
    phase="update";fault=scenario;
    result=u.run(next,"update",next_digest);
    if(scenario=="success" || scenario=="defaults" || scenario=="same-version") {
        if(scenario=="same-version") {
            let commands=filter(calls,(command)=>command[0]=="opkg" && index(command,"install")>=0 && index(command,"--force-reinstall")>=0);
            assert(length(commands)==2,"both plan and apply must reinstall the changed same-version core");
            assert(fs.readfile(root+"/payload/usr/bin/loki-core")==fs.readfile(next+"/candidate-core"));
        }
        assert(fs.readfile(root+"/configs/loki")=="own configuration\n");
        assert(result.success,sprintf("%J",result));assert(u.read().phase=="committed");
        assert(fs.readfile(root+"/status")==installed(new));
        phase="uninstall";fault="removed-conffiles";calls=[];
        result=u.run(next,"uninstall",next_digest);assert(result.success,sprintf("%J",result));
        assert(fs.readfile(root+"/status")==baseline && fs.readfile(root+"/configs/loki")=="own configuration\n");
        assert(u.installed()==null,"uninstall must remove the active proof");
        assert(u.start_admission()=="installed-component-backup-unavailable","removed packages cannot start from retained settings alone");
        for(let command in calls)if(command[0]=="opkg" && index(command,"remove")>=0)assert(index(command,"--nodeps")<0);
        phase="install";fault="none";
        result=u.run(first,"install",first_digest);assert(result.success,sprintf("%J",result));
        phase="uninstall";fault="removed-conffiles";
        result=u.run(first,"uninstall",first_digest);assert(result.success,sprintf("%J",result));
        assert(fs.readfile(root+"/status")==baseline && fs.readfile(root+"/configs/loki")=="own configuration\n");
    }
    else if(scenario=="foreign-plan") {
        assert(!result.success && result.reason=="package-manager-plan-unverified");
        assert(fs.readfile(root+"/status")==installed(old) && fs.readfile(root+"/cache/cache.db")=="old cache state");
        assert(u.read().phase=="aborted");
    }
    else if(scenario=="rollback") {
        assert(!result.success && result.recovery_required && u.pending());
        assert(u.read().phase=="recovery-required");
    }
    else {
        if(scenario=="concurrent") {
            assert(result.reason=="configuration-changed-during-update");
            let directory=root+"/store/"+u.read().id;
            let preserved=filter(fs.lsdir(directory),(name)=>substr(name,0,15)=="changed-config.");
            assert(length(preserved)==1 && fs.readfile(directory+"/"+preserved[0])=="concurrent B\n");
            assert(fs.readfile(root+"/configs/loki")=="own configuration\n");
        }
        assert(!result.success && !result.recovery_required,sprintf("%J",result));
        assert(u.read().phase=="rolled-back");
        assert(fs.readfile(root+"/status")==installed(old));
        assert(fs.readfile(root+"/cache/cache.db")=="old cache state");
    }
}
print("transaction checked\n");
'''
        first = self.kit.root/'prepared'
        process = self.lease.spawn(code, str(self.lease.root), str(first), str(self.kit.output),
                                   self.prepared['manifest_sha256'], self.next['manifest_sha256'], scenario, self.kit.core_body.decode(), self.lease.binary, str(leases.LIBRARY))
        stdout, stderr = process.communicate(timeout=45)
        self.assertEqual(process.returncode, 77 if scenario == 'interrupted' else 0, stdout+stderr)
        if scenario == 'interrupted':
            process = self.lease.spawn(code, str(self.lease.root), str(first), str(self.kit.output),
                                       self.prepared['manifest_sha256'], self.next['manifest_sha256'], 'recover', self.kit.core_body.decode(), self.lease.binary, str(leases.LIBRARY))
            stdout, stderr = process.communicate(timeout=45)
            self.assertEqual(process.returncode, 0, stdout+stderr)
        self.assertFalse(self.kit.marker.exists(), 'package hooks/core were never authorized in this fixture')

    def test_offline_entry_compiles_and_refuses_linux_before_persistent_changes(self):
        root = Path(__file__).resolve().parents[1]
        result = subprocess.run([self.lease.binary, '-L', str(root/'loki/files/usr/lib'), '-e',
                                 'assert(loadfile(ARGV[0])!=null);', str(root/'component-update.uc')],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run(['/bin/sh', str(root/'component-update.sh'), 'install',
                                 '/synthetic-secret', '0'*64], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout), {'success': False, 'reason':
                         'root-required' if os.geteuid() else 'openwrt-required'})
        self.assertNotIn('synthetic-secret', result.stdout+result.stderr)

    def test_preflight_refusal_changes_no_packages_or_persistent_intent(self): self.worker('preflight')
    def test_bad_checksum_cannot_reach_package_manager(self): self.worker('checksum')
    def test_memory_budget_refusal_precedes_package_manager_and_persistent_intent(self): self.worker('memory-budget')
    def test_install_update_uninstall_share_own_only_commands(self): self.worker('success')
    def test_changed_environment_is_refused_after_preparation_before_package_mutation(self): self.worker('preflight-late')
    def test_foreign_package_in_plan_is_refused_before_stop(self): self.worker('foreign-plan')
    def test_partial_package_failure_restores_old_components(self): self.worker('pm')
    def test_interrupted_package_apply_has_explicit_durable_recovery(self): self.worker('interrupted')
    def test_package_defaults_do_not_replace_saved_configuration(self): self.worker('defaults')
    def test_concurrent_configuration_is_preserved_before_rollback(self): self.worker('concurrent')
    def test_failed_rollback_stays_pending(self): self.worker('rollback')
    def test_same_version_corrupt_payload_fails_health_and_rolls_back(self): self.worker('payload')
    def test_changed_same_version_core_is_reinstalled_from_the_local_kit(self): self.worker('same-version')
    def test_health_failure_restores_old_cache_before_restart(self): self.worker('health')
    def test_fresh_health_admission_can_refuse_and_rollback_rechecks_restored_payload(self): self.worker('admission-health')


if __name__ == '__main__':
    if sys.platform != 'linux': raise SystemExit('Run transaction checks on the Linux test server')
    unittest.main()
