let t = require("t"), fs = require("fs"), stub = require("stub");
let pending = require("service.preflight_config").pending;
const SESSION = "uci-0123456789abcdef0123456789abcdef";

function fixture() {
    let root = stub.tmpdir();fs.chmod(root,0700);
    for(let name in ["/tmp","/tmp/run"])fs.mkdir(root+name,0755);
    fs.mkdir(root+"/tmp/run/rpcd",0700);
    fs.symlink("tmp",root+"/var");
    return root;
}

t.test("absent and empty CLI, rpcd and rollback deltas are checked without writing", () => {
    let root=fixture();
    t.eq(pending(root).state,"checked");
    for(let name in ["/tmp/.uci","/tmp/run/rpcd/"+SESSION,"/tmp/run/rpcd/snapshot-files","/tmp/run/rpcd/snapshot-delta"]) {
        fs.mkdir(root+name,0700);fs.writefile(root+name+"/dhcp","");fs.chmod(root+name+"/dhcp",0600);
    }
    let originals={};
    for(let name in ["writefile","mkdir","chmod","chown","rename","unlink","rmdir","symlink"]){originals[name]=fs[name];fs[name]=()=>die("unexpected-write");}
    let result,error;
    try {result=pending(root);}catch(e){error=e;}
    for(let name in keys(originals))fs[name]=originals[name];
    if(error!=null)die(error);
    t.eq(result,{kind:"dns-pending",object:"uci-deltas",state:"checked",reason:"uci-pending-snapshot-checked"});
    t.eq(pending(root),result,"repeat inspection preserves the stores");
});

t.test("every pending delta or possible rollback stays intact and private", () => {
    for(let name in ["/tmp/.uci","/tmp/run/rpcd/"+SESSION,"/tmp/run/rpcd/snapshot-files","/tmp/run/rpcd/snapshot-delta"]) {
        let root=fixture();fs.mkdir(root+name,0700);
        let path=root+name+"/dhcp";
        fs.writefile(path,"synthetic-private-token dns://private.example\n");fs.chmod(path,0600);
        let before=fs.readfile(path),result=pending(root);
        t.eq([result.state,result.reason],["incomplete","uci-pending-config-changes"]);
        t.eq(fs.readfile(path),before);
        for(let secret in ["synthetic-private-token","private.example",SESSION,root])t.excludes(sprintf("%J",result),secret);
    }
});

t.test("symlinks, public stores and linked deltas cannot prove an empty snapshot", () => {
    let root=fixture(),directory=root+"/tmp/.uci";
    fs.mkdir(directory,0700);
    fs.writefile(root+"/sentinel","private-sentinel");fs.symlink(root+"/sentinel",directory+"/dhcp");
    t.eq(pending(root).state,"incomplete");
    t.eq(fs.readfile(root+"/sentinel"),"private-sentinel");
    fs.unlink(directory+"/dhcp");fs.chmod(directory,0755);
    t.eq(pending(root).state,"incomplete");
    fs.chmod(directory,0700);fs.writefile(directory+"/dhcp","");fs.chmod(directory+"/dhcp",0600);
    let lstat=fs.lstat;
    fs.lstat=(path)=>{let value=lstat(path);return path==directory+"/dhcp"?{...value,nlink:2}:value;};
    let result=pending(root);fs.lstat=lstat;
    t.eq(result.state,"incomplete");
});

t.test("directory errors and the shared entry bound are incomplete without exception text", () => {
    for(let mode in ["open","read","close","limit"]) {
        let root=fixture(),path=root+"/tmp/.uci";fs.mkdir(path,0700);
        let opendir=fs.opendir,reads=0,closed=0;
        fs.opendir=(name)=>name!=path?opendir(name):mode=="open"?null:{
            read:()=>{if(mode=="read")die("synthetic-private-error");return mode=="limit"?"entry"+(++reads):null;},
            close:()=>{closed++;return mode!="close";}
        };
        let result=pending(root);fs.opendir=opendir;
        t.eq(result.state,"incomplete");t.excludes(sprintf("%J",result),"synthetic-private-error");
        t.eq(closed,mode=="open"?0:1);
        if(mode=="limit")t.eq(result.reason,"uci-pending-entry-limit");
    }
});

t.test("a new entry between inventory reads invalidates the supposedly empty snapshot", () => {
    let root=fixture(),path=root+"/tmp/.uci";fs.mkdir(path,0700);
    let opendir=fs.opendir,opens=0;
    fs.opendir=(name)=>{
        if(name==path && ++opens==2){fs.writefile(path+"/network","");fs.chmod(path+"/network",0600);}
        return opendir(name);
    };
    let result=pending(root);fs.opendir=opendir;
    t.eq([result.state,result.reason],["incomplete","uci-pending-changed"]);
    t.eq(fs.readfile(path+"/network"),"");
});

t.test("an empty delta filled during inventory verification cannot pass", () => {
    let root=fixture(),path=root+"/tmp/.uci";fs.mkdir(path,0700);
    fs.writefile(path+"/dhcp","");fs.chmod(path+"/dhcp",0600);
    let opendir=fs.opendir,opens=0;
    fs.opendir=(name)=>{
        if(name==path && ++opens==2)fs.writefile(path+"/dhcp","synthetic-private-late-change");
        return opendir(name);
    };
    let result=pending(root);fs.opendir=opendir;
    t.eq([result.state,result.reason],["incomplete","uci-pending-changed"]);
    t.eq(fs.readfile(path+"/dhcp"),"synthetic-private-late-change");
    t.excludes(sprintf("%J",result),"synthetic-private-late-change");
});

t.done();
