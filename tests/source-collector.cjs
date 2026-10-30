'use strict';
const vm=require('vm'),fs=require('fs'),assert=require('assert');
const code=fs.readFileSync(__dirname+'/../resources/MediaCollector.js','utf8');
function anchor(attrs,text=''){return {tagName:'A',textContent:text,getAttribute:k=>attrs[k]||null,hasAttribute:k=>k in attrs,querySelectorAll:()=>[]};}
function env(nodes=[],html=''){const timers=[],events={};const document={hidden:false,title:'Source test',baseURI:'https://site.test/a/',documentElement:{outerHTML:html},body:{innerText:html},querySelectorAll:()=>nodes,addEventListener:(n,f)=>events[n]=f};const ctx={URL,Date,Math,Map,Set,WeakSet,Array,JSON,document,location:{href:'https://site.test/a/'},MutationObserver:class{observe(){}disconnect(){}},getComputedStyle:()=>({backgroundImage:'none'}),setTimeout:f=>(timers.push(f),timers.length),clearTimeout(){},addEventListener(){},webkit:{messageHandlers:{pvx_media_v1:{postMessage(){}}}}};vm.runInNewContext(code,ctx,{timeout:3000});return {ctx,scan:()=>ctx.__pvxMedia_v1.snapshot(),nodes};}
let r=env([anchor({'href':'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Named.Movie'}),anchor({'href':'https://evil.example/?next=https://pan.baidu.com/s/fake'},'百度网盘')]);let s=r.scan();assert.equal(s.cloudSources.filter(x=>x.sourceKind==='magnet').length,1);assert(!s.cloudSources.some(x=>x.sourceKind==='cloud_share'));
let c=r.ctx.__pvxMedia_v1.importSource('magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Renamed');assert.equal(c.infoHash,'0123456789abcdef0123456789abcdef01234567');assert.equal(c.label,'Named.Movie');
assert.equal(r.ctx.__pvxMedia_v1.importSource('magnet:?xt=urn:btih:bad'),null);
let page=r.ctx.__pvxMedia_v1.importSource('https://ordinary.example/download?id=1');assert.equal(page.sourceKind,'page');
let base32='AEBAGBAFAYDQQCIKBMGA2DQPCAIREEYU';let b=r.ctx.__pvxMedia_v1.importSource('magnet:?xt=urn:btih:'+base32+'&dn=Base32');assert(b&&b.infoHash.length===40);
r.nodes.length=0;r.ctx.location.href='https://site.test/spa';r.ctx.__pvxMedia_v1.scan();assert.equal(r.ctx.__pvxMedia_v1.snapshot().cloudSources.length,0);
console.log('source collector tests passed: 6');
