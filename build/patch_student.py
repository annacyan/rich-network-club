"""Turn the demo web app into the Supabase-backed student site.

Usage: python3 patch_student.py <source index.html> <output index.html>
"""
import sys

src, out = sys.argv[1], sys.argv[2]
h = open(src, encoding="utf-8").read()


def rep(old, new, count=1):
    global h
    n = h.count(old)
    assert n == count, f"expected {count} match(es), found {n}: {old[:80]!r}"
    h = h.replace(old, new)


# 1) Libraries + config in <head>
rep(
    '<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>',
    '<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>\n'
    '<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>\n'
    '<script src="config.js"></script>',
)

# 2) Cloud data layer that speaks the same interface as LocalDB
rep(
    "var queues = {};",
    r"""function SupaDB(sb){
  var cache={}, subs=[], ready=false;
  function fire(){ subs.slice().forEach(function(s){ try{ s(); }catch(e){} }); }
  function snapDoc(path){ var v=cache[path]; return {id:path.split('/').pop(), exists:v!==undefined, data:function(){return v;}, metadata:{fromCache:!ready}}; }
  function err(e){ var x=new Error((e&&e.message)||'db'); x.code=(e&&e.code==='42501')?'invalid_argument':'unavailable'; return x; }
  function load(){
    var all=[];
    function page(from){ return sb.from('docs').select('path,data').range(from,from+999).then(function(r){ if(r.error) throw r.error; all=all.concat(r.data||[]); if((r.data||[]).length===1000) return page(from+1000); }); }
    return page(0).then(function(){ cache={}; all.forEach(function(d){ cache[d.path]=d.data; }); ready=true; fire(); });
  }
  sb.channel('rich-docs').on('postgres_changes',{event:'*',schema:'public',table:'docs'},function(p){
    if(p.eventType==='DELETE'){ if(p.old&&p.old.path){ delete cache[p.old.path]; } }
    else if(p.new&&p.new.path){ cache[p.new.path]=p.new.data; }
    fire();
  }).subscribe(function(status){ if(status==='SUBSCRIBED' && ready) load(); });
  load().catch(function(){ ready=true; S.offline=true; fire(); });
  function docRef(path){ return {
    path:path,
    get:function(){ return Promise.resolve(snapDoc(path)); },
    set:function(v){ var val=clone(v); return sb.from('docs').upsert({path:path,data:val,updated_at:new Date().toISOString()}).then(function(r){ if(r.error) throw err(r.error); cache[path]=val; fire(); }); },
    delete:function(){ return sb.from('docs').delete().eq('path',path).then(function(r){ if(r.error) throw err(r.error); delete cache[path]; fire(); }); },
    onSnapshot:function(cb){ var f=function(){ if(ready) cb(snapDoc(path)); }; subs.push(f); setTimeout(f); return function(){ subs=subs.filter(function(x){return x!==f;}); }; }
  }; }
  function colRef(path){ var n=path.split('/').length+1; return {
    doc:function(id){ return docRef(path+'/'+(id||rid())); },
    onSnapshot:function(cb){ var f=function(){ if(!ready) return; var docs=Object.keys(cache).filter(function(p){ return p.indexOf(path+'/')===0 && p.split('/').length===n; }).map(snapDoc); cb({docs:docs,size:docs.length,empty:!docs.length,metadata:{fromCache:false}}); }; subs.push(f); setTimeout(f); return function(){ subs=subs.filter(function(x){return x!==f;}); }; }
  }; }
  return { doc:docRef, collection:colRef, __supa:true };
}
var queues = {};""",
)

# 3) The old self-made account doc is not used with real accounts
rep(
    "  DB.doc('accounts/'+S.uid).onSnapshot(",
    "  if(DB.__supa){ S.loaded.account=true; } else DB.doc('accounts/'+S.uid).onSnapshot(",
)

# 4) Logout + change password go through the real account system
rep(
    "  logout:function(){ logEvent('logout');",
    "  logout:function(){ if(DB&&DB.__supa&&window.__richLogout){ logEvent('logout'); window.__richLogout(); return; } logEvent('logout');",
)
rep(
    "    if(err){ c.err=err; render(); return; }\n    hashPw(c.old||'', acc.pw.salt)",
    "    if(err){ c.err=err; render(); return; }\n"
    "    if(DB&&DB.__supa&&window.__richChangePw){ window.__richChangePw(c.old||'', c.n1).then(function(msg){ if(msg){ c.err=msg; render(); return; } logEvent('pwchange'); S.sheet=null; render(); toast('密碼已更新'); }); return; }\n"
    "    hashPw(c.old||'', acc.pw.salt)",
)

# 5) Start hook used by the login screen, and no automatic demo boot when the cloud is configured
rep(
    "var booted=false;",
    """window.__richStart=function(o){
  if(booted) return; booted=true;
  DB=SupaDB(o.sb); S.uid=String(o.uid);
  S.isAdmin=false; S.isOwner=false; S.isAdminKnown=true; S.canWrite=true;
  S.gatePass=true; S.sess=true; S.account={email:o.email, studentNo:o.studentNo, suspended:false}; S.loaded.account=true;
  S.myEmail=o.email||''; S.myName=o.name||'';
  S.mode='loading'; startSubs(); whenLoaded(); render();
};
var booted=false;""",
)
rep(
    "render();\nif(window.claude && typeof window.claude.use==='function') boot();",
    "if(window.RICH_CONFIG && window.RICH_CONFIG.url){ /* 登入畫面會在確認身分後呼叫 __richStart */ }\n"
    "else { render();\nif(window.claude && typeof window.claude.use==='function') boot();",
)
rep(
    "else { var tries=0; (function wait(){ if(window.claude&&typeof window.claude.use==='function'){ boot(); return; } if(++tries>40){ boot(); return; } setTimeout(wait,100); })(); }\n})();",
    "else { var tries=0; (function wait(){ if(window.claude&&typeof window.claude.use==='function'){ boot(); return; } if(++tries>40){ boot(); return; } setTimeout(wait,100); })(); }\n}\n})();",
)

# 6) Login / register screen
auth = open(sys.argv[3] if len(sys.argv) > 3 else "auth_shell.html", encoding="utf-8").read()
rep("</body>", auth + "\n</body>")

open(out, "w", encoding="utf-8").write(h)
print("ok", len(h))
