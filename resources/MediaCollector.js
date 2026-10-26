(() => {
'use strict';
const KEY='__pvxMedia_v1';
if(globalThis[KEY]){globalThis[KEY].scan();return;}
const docID=`${Date.now()}-${Math.random().toString(36).slice(2)}`;
let timer=null,running=false,last='',lastURL=location.href,chosen=null,chosenAt=0,lastSnapshot=null;
const networkSources=new Map();
const runtimeMedia=new Map();
const mediaURL=v=>{if(typeof v!=='string'||!v.trim()||v.length>16384)return '';try{const u=new URL(v,document.baseURI);return /^https?:$/.test(u.protocol)?u.href:'';}catch{return '';}};
const classify=(url,mime='')=>{const u=String(url||'').toLowerCase(),m=String(mime||'').toLowerCase(),x=u+' '+m;if(/(?:^|[/?._-])(?:seg(?:ment)?[-_]?\d+|chunk[-_]?\d+)[^/]*\.(?:ts|m4s)(?:[?#]|$)/.test(u)||/video\/mp2t|video\/iso\.segment/.test(m)||/\.m4s(?:[?#]|$)/.test(u)||/\.ts(?:[?#]|$)/.test(u))return '';if(/mpegurl|m3u8|vnd.apple.mpegurl/.test(x))return 'hls';if(/dash\+xml/.test(m)||/\.mpd(?:[?#]|$)/.test(u))return 'dash';if(/video\//.test(m)||/\.(mp4|m4v|webm|mov|mkv)(?:[?#]|$)/.test(u))return 'video';if(/audio\//.test(m)||/\.(m4a|mp3|aac|wav|ogg)(?:[?#]|$)/.test(u))return 'audio';return '';};
function rememberNetwork(raw,mime='',headers=''){const url=mediaURL(raw),protocol=classify(url,mime);if(!url||!protocol||protocol==='audio')return;const old=networkSources.get(url)||{};networkSources.set(url,{kind:'video',url,protocol,mime:String(mime||old.mime||'').slice(0,180),headers:String(headers||old.headers||'').slice(0,1200),title:String(document.title||'影片').slice(0,180),page:location.href.slice(0,16384),at:Date.now()});schedule();}
function rememberRuntime(mime,blob=''){const key=`mse:${location.href}:${mime||'unknown'}`;runtimeMedia.set(key,{kind:'runtime',protocol:'mse',mime:String(mime||'').slice(0,180),blob:String(blob||'').slice(0,4096),page:location.href.slice(0,16384),title:String(document.title||'影片').slice(0,180)});schedule();}
function scanHtmlCandidates(){try{const html=(document.documentElement?.outerHTML||'').slice(0,2000000);const re=/https?:\/\/[^\s<>'"`\\]+/gi;for(const m of html.matchAll(re)){let u=m[0].replace(/[\],.;]+$/,'').replace(/&amp;/g,'&');if(/\.(m3u8|mpd|mp4|m4v|webm|mov)(?:[?#]|$)/i.test(u))rememberNetwork(u,'');}}catch{}}
function installNetworkProbe(){if(globalThis.__pvxNetworkProbe)return;globalThis.__pvxNetworkProbe=true;try{const oldFetch=globalThis.fetch;if(typeof oldFetch==='function')globalThis.fetch=function(input,init){try{rememberNetwork(typeof input==='string'?input:input&&input.url||'', '', init&&init.headers?JSON.stringify(init.headers):'');}catch{}const p=oldFetch.apply(this,arguments);return p.then(r=>{try{rememberNetwork(r.url,r.headers&&r.headers.get('content-type')||'',r.headers&&r.headers.get('etag')||'');}catch{}return r;});};}catch{}try{const oldOpen=XMLHttpRequest.prototype.open,oldSend=XMLHttpRequest.prototype.send;XMLHttpRequest.prototype.open=function(method,url){this.__pvxURL=url;return oldOpen.apply(this,arguments);};XMLHttpRequest.prototype.send=function(){try{rememberNetwork(this.__pvxURL||'');}catch{}this.addEventListener('readystatechange',()=>{if(this.readyState===2||this.readyState===4)try{rememberNetwork(this.responseURL||this.__pvxURL||'',this.getResponseHeader('content-type')||'',this.getResponseHeader('etag')||'');}catch{}});return oldSend.apply(this,arguments);};}catch{}try{const oldSet=HTMLMediaElement.prototype.setAttribute;HTMLMediaElement.prototype.setAttribute=function(k,v){if(String(k).toLowerCase()==='src')rememberNetwork(v,'');return oldSet.apply(this,arguments);};}catch{}try{const oldCreate=URL.createObjectURL;URL.createObjectURL=function(obj){const u=oldCreate.call(this,obj);if(typeof MediaSource!=='undefined'&&obj instanceof MediaSource)rememberRuntime('',u);return u;};}catch{}try{const oldAdd=MediaSource&&MediaSource.prototype.addSourceBuffer;if(oldAdd)MediaSource.prototype.addSourceBuffer=function(mime){const sb=oldAdd.call(this,mime);rememberRuntime(mime,'');return sb;};}catch{}try{const po=new PerformanceObserver(list=>{for(const e of list.getEntries()){if(e&&e.name)rememberNetwork(e.name,'');}});po.observe({entryTypes:['resource']});for(const e of performance.getEntriesByType('resource'))if(e.name)rememberNetwork(e.name,'');}catch{}scanHtmlCandidates();}
installNetworkProbe();
const MAX_IMAGES=300,MAX_NODES=2000,roots=new Set(),listeners=new WeakSet();
const http=v=>{if(typeof v!=='string'||!v.trim()||v.length>16384)return '';try{const u=new URL(v,document.baseURI);return /^https?:$/.test(u.protocol)?u.href:'';}catch{return '';}};
const dimensions=el=>({width:Number(el.naturalWidth||el.videoWidth||el.width||0),height:Number(el.naturalHeight||el.videoHeight||el.height||0)});
function activate(v){if(!v||v.tagName!=='VIDEO')return;chosen=v;chosenAt=Date.now();schedule();}
function tagVideo(v){if(listeners.has(v))return;listeners.add(v);for(const n of ['webkitbeginfullscreen','enterpictureinpicture','pointerdown','touchstart','play'])v.addEventListener(n,()=>activate(v),{passive:true});for(const n of ['webkitendfullscreen','leavepictureinpicture','pause','emptied'])v.addEventListener(n,schedule,{passive:true});}
function scan(force=false){
 if(timer!==null){clearTimeout(timer);timer=null;}if(!running&&!force)return;
 if(lastURL!==location.href){lastURL=location.href;chosen=null;chosenAt=0;}
 const found=new Map(),videos=new Map(),search=[document];let walked=0;
 const videoRow=v=>{const sources=new Map(),pageURL=location.href;const addSource=(raw,h)=>{const url=http(raw);if(!url||url===pageURL)return;const height=Number(h)||0;const old=sources.get(url);if(!old||old.height<height)sources.set(url,{url,height:Math.min(100000,Math.max(0,height))});};addSource(v.currentSrc||v.src||v.getAttribute('src'),v.videoHeight);for(const s of v.querySelectorAll('source'))addSource(s.src||s.getAttribute('src'),s.getAttribute('data-height')||s.getAttribute('res')||s.getAttribute('size'));const list=[...sources.values()].filter(x=>{const p=classify(x.url,String(v.getAttribute('type')||''));return p==='hls'||p==='dash'||p==='video';}).sort((a,b)=>b.height-a.height||a.url.localeCompare(b.url));if(!list.length||videos.size>=300)return;const url=list[0].url;const mime=String(v.getAttribute('type')||'').slice(0,180);if(!videos.has(url))videos.set(url,{kind:'video',url,protocol:classify(url,mime)||'video',mime,sources:list,width:Number(v.videoWidth||v.width||0),height:list[0].height||Number(v.videoHeight||0),title:String(v.title||document.title||'影片').slice(0,180),poster:http(v.poster||v.getAttribute('poster'))});};
 const add=(raw,el,title,kind)=>{const url=http(raw);if(!url||found.has(url)||found.size>=MAX_IMAGES)return;const d=el?dimensions(el):{width:0,height:0};if(d.width>0&&d.height>0&&(d.width<48||d.height<48))return;found.set(url,{url,title:String(title||document.title||'图片').slice(0,180),width:Math.min(100000,Math.max(0,d.width)),height:Math.min(100000,Math.max(0,d.height)),kind});};
 for(let ri=0;ri<search.length&&walked<MAX_NODES;ri++){
  const root=search[ri];if(!roots.has(root)){roots.add(root);try{observer.observe(root,{subtree:true,childList:true,attributes:true,attributeFilter:['src','srcset','data-src','data-original','data-lazy-src','style']});}catch{}}
  const nodes=root.querySelectorAll('*');
  for(let i=0;i<nodes.length&&walked++<MAX_NODES;i++){
   const el=nodes[i];if(el.shadowRoot&&search.length<64)search.push(el.shadowRoot);
   if(el.tagName==='VIDEO'){tagVideo(el);videoRow(el);if(el.webkitDisplayingFullscreen||el.webkitPresentationMode==='picture-in-picture'||document.pictureInPictureElement===el)activateQuiet(el);}
   if(el.tagName==='IMG'){
    add(el.currentSrc||el.src,el,el.alt||el.title,'img');
    for(const a of ['data-original','data-src','data-lazy-src'])add(el.getAttribute(a),el,el.alt||el.title,'lazy');
    const raw=el.getAttribute('srcset')||el.parentElement?.querySelector('source[srcset]')?.getAttribute('srcset')||'';
    const candidates=raw.split(',').map(s=>{const m=s.trim().match(/^(\S+)\s*(\d*\.?\d*)(w|x)?$/);return m?{u:m[1],score:Number(m[2]||1)*(m[3]==='x'?10000:1)}:null;}).filter(Boolean).sort((a,b)=>b.score-a.score);if(candidates[0])add(candidates[0].u,el,el.alt||el.title,'srcset');
   }
   if((force||el.hasAttribute('style'))&&walked<450&&found.size<MAX_IMAGES){try{const bg=getComputedStyle(el).backgroundImage;if(bg&&bg!=='none'){const rect=el.getBoundingClientRect();if(rect.width>=64&&rect.height>=64){for(const m of bg.matchAll(/url\(["']?([^"')]+)["']?\)/g))add(m[1],null,el.getAttribute('aria-label')||el.title,'background');}}}catch{}}
  }
 }
 for(const item of networkSources.values()){if(item.kind!=='video')continue;const existing=videos.get(item.url);if(existing){existing.protocol=item.protocol;existing.mime=item.mime;existing.headers=item.headers;}else videos.set(item.url,{kind:'video',url:item.url,protocol:item.protocol,mime:item.mime,headers:item.headers,sources:[{url:item.url,height:0}],height:0,title:item.title,poster:''});}
 const runtime=[...runtimeMedia.values()];
 let active=null;const v=chosen;
 if(v&&v.isConnected!==false&&(Date.now()-chosenAt<30000||v.webkitDisplayingFullscreen||v.webkitPresentationMode==='picture-in-picture'||document.pictureInPictureElement===v)){
 const source= http(v.currentSrc)||http(v.getAttribute('src'))||[...v.querySelectorAll('source')].map(s=>http(s.src||s.getAttribute('src'))).find(Boolean)||'';
  const rawCurrent=String(v.currentSrc||v.src||'');
  const sourceCandidates=[...networkSources.values()].filter(x=>x.page===location.href&&x.protocol&&x.url!==location.href).sort((a,b)=>{const rank=x=>x.protocol==='hls'||x.protocol==='dash'?0:x.protocol==='video'?1:2;return rank(a)-rank(b)||(b.at||0)-(a.at||0);}).slice(0,32).map(x=>({url:x.url,protocol:x.protocol,mime:x.mime||'',at:x.at||0}));
  active={url:source,blob:rawCurrent.startsWith('blob:'),blobURL:rawCurrent.startsWith('blob:')?rawCurrent:'',sourceCandidates,title:String(v.title||document.title||'当前播放视频').slice(0,180),at:chosenAt,fullscreen:!!v.webkitDisplayingFullscreen,pip:v.webkitPresentationMode==='picture-in-picture'||document.pictureInPictureElement===v};
 }
 const message={version:1,documentID:docID,page:location.href.slice(0,16384),images:[...found.values()],videos:[...videos.values()],runtime,active};lastSnapshot=message;
 const sig=JSON.stringify(message);if(!force&&sig===last)return;
 try{globalThis.webkit.messageHandlers.pvx_media_v1.postMessage(message);last=sig;}catch{}
}
function activateQuiet(v){chosen=v;chosenAt=Date.now();}
function schedule(){if(running&&timer===null)timer=setTimeout(()=>scan(false),400);}
const observer=new MutationObserver(schedule);
function start(){if(running||document.hidden)return;running=true;scan(true);}
function stop(){running=false;observer.disconnect();roots.clear();if(timer!==null)clearTimeout(timer);timer=null;}
for(const n of ['play','playing','webkitbeginfullscreen','enterpictureinpicture'])document.addEventListener(n,e=>activate(e.target),true);
document.addEventListener('load',schedule,true);
document.addEventListener('visibilitychange',()=>document.hidden?stop():start());
addEventListener('pagehide',stop);addEventListener('pageshow',start);
function runtimeBase64(bytes){let text='';for(let i=0;i<bytes.length;i+=0x8000)text+=String.fromCharCode.apply(null,bytes.subarray(i,i+0x8000));return btoa(text);}
function exportActiveRuntime(){const v=chosen;if(!v)return false;const blob=String(v.currentSrc||v.src||'');if(!blob.startsWith('blob:'))return false;const requestID=`${docID}-${Date.now()}-${Math.random().toString(36).slice(2)}`;const post=(action,extra={})=>{try{globalThis.webkit.messageHandlers.pvx_media_v1.postMessage(Object.assign({version:1,command:'runtimeBlob',action,requestID,page:location.href.slice(0,16384),documentID:docID,title:String(v.title||document.title||'当前播放视频').slice(0,180)},extra));return true;}catch{return false;}};const mime=String(v.getAttribute('type')||'video/mp4').slice(0,180);post('begin',{blobURL:blob,mime});const send=bytes=>post('chunk',{data:runtimeBase64(bytes),length:bytes.length});const finish=()=>post('end');const fail=e=>post('error',{error:String(e&&e.message||e||'blob读取失败').slice(0,500)});try{fetch(blob).then(r=>{if(!r.ok)throw Error(`blob HTTP ${r.status}`);if(r.body&&r.body.getReader){const reader=r.body.getReader();const pump=()=>reader.read().then(x=>{if(x.done){finish();return;}if(!send(x.value))throw Error('native chunk bridge unavailable');return pump();});return pump();}return r.arrayBuffer().then(b=>{for(let i=0;i<b.byteLength;i+=131072)if(!send(new Uint8Array(b,i,Math.min(131072,b.byteLength-i))))throw Error('native chunk bridge unavailable');finish();});}).catch(fail);return true;}catch(e){fail(e);return false;}}
globalThis[KEY]={scan:()=>scan(true),active:()=>{scan(true);return chosen;},snapshot:()=>{scan(true);return lastSnapshot;},exportActiveRuntime};start();
})();
