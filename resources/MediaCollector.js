(() => {
'use strict';
const KEY='__pvxMedia_v1';
if(globalThis[KEY]){globalThis[KEY].scan();return;}
const docID=`${Date.now()}-${Math.random().toString(36).slice(2)}`;
let timer=null,running=false,last='',lastURL=location.href,chosen=null,chosenAt=0;
const MAX_IMAGES=300,MAX_NODES=2000,roots=new Set(),listeners=new WeakSet();
const http=v=>{if(typeof v!=='string'||!v.trim()||v.length>16384)return '';try{const u=new URL(v,document.baseURI);return /^https?:$/.test(u.protocol)?u.href:'';}catch{return '';}};
const dimensions=el=>({width:Number(el.naturalWidth||el.videoWidth||el.width||0),height:Number(el.naturalHeight||el.videoHeight||el.height||0)});
function activate(v){if(!v||v.tagName!=='VIDEO')return;chosen=v;chosenAt=Date.now();schedule();}
function tagVideo(v){if(listeners.has(v))return;listeners.add(v);for(const n of ['webkitbeginfullscreen','enterpictureinpicture','pointerdown','touchstart','play'])v.addEventListener(n,()=>activate(v),{passive:true});}
function scan(force=false){
 if(timer!==null){clearTimeout(timer);timer=null;}if(!running)return;
 if(lastURL!==location.href){lastURL=location.href;chosen=null;chosenAt=0;}
 const found=new Map(),search=[document];let walked=0;
 const add=(raw,el,title,kind)=>{const url=http(raw);if(!url||found.has(url)||found.size>=MAX_IMAGES)return;const d=el?dimensions(el):{width:0,height:0};if(d.width>0&&d.height>0&&(d.width<48||d.height<48))return;found.set(url,{url,title:String(title||document.title||'图片').slice(0,180),width:Math.min(100000,Math.max(0,d.width)),height:Math.min(100000,Math.max(0,d.height)),kind});};
 for(let ri=0;ri<search.length&&walked<MAX_NODES;ri++){
  const root=search[ri];if(!roots.has(root)){roots.add(root);try{observer.observe(root,{subtree:true,childList:true,attributes:true,attributeFilter:['src','srcset','data-src','data-original','data-lazy-src','style']});}catch{}}
  const nodes=root.querySelectorAll('*');
  for(let i=0;i<nodes.length&&walked++<MAX_NODES;i++){
   const el=nodes[i];if(el.shadowRoot&&search.length<64)search.push(el.shadowRoot);
   if(el.tagName==='VIDEO'){tagVideo(el);if(el.webkitDisplayingFullscreen||el.webkitPresentationMode==='picture-in-picture'||document.pictureInPictureElement===el)activateQuiet(el);}
   if(el.tagName==='IMG'){
    add(el.currentSrc||el.src,el,el.alt||el.title,'img');
    for(const a of ['data-original','data-src','data-lazy-src'])add(el.getAttribute(a),el,el.alt||el.title,'lazy');
    const raw=el.getAttribute('srcset')||el.parentElement?.querySelector('source[srcset]')?.getAttribute('srcset')||'';
    const candidates=raw.split(',').map(s=>{const m=s.trim().match(/^(\S+)\s*(\d*\.?\d*)(w|x)?$/);return m?{u:m[1],score:Number(m[2]||1)*(m[3]==='x'?10000:1)}:null;}).filter(Boolean).sort((a,b)=>b.score-a.score);if(candidates[0])add(candidates[0].u,el,el.alt||el.title,'srcset');
   }
   if((force||el.hasAttribute('style'))&&walked<450&&found.size<MAX_IMAGES){try{const bg=getComputedStyle(el).backgroundImage;if(bg&&bg!=='none'){const rect=el.getBoundingClientRect();if(rect.width>=64&&rect.height>=64){for(const m of bg.matchAll(/url\(["']?([^"')]+)["']?\)/g))add(m[1],null,el.getAttribute('aria-label')||el.title,'background');}}}catch{}}
  }
 }
 let active=null;const v=chosen;
 if(v&&v.isConnected!==false&&(Date.now()-chosenAt<30000||v.webkitDisplayingFullscreen||v.webkitPresentationMode==='picture-in-picture'||document.pictureInPictureElement===v)){
  const source=http(v.currentSrc)||http(v.getAttribute('src'))||[...v.querySelectorAll('source')].map(s=>http(s.src||s.getAttribute('src'))).find(Boolean)||'';
  active={url:source,blob:!source&&String(v.currentSrc||v.src||'').startsWith('blob:'),title:String(v.title||document.title||'当前播放视频').slice(0,180),at:Date.now(),fullscreen:!!v.webkitDisplayingFullscreen,pip:v.webkitPresentationMode==='picture-in-picture'||document.pictureInPictureElement===v};
 }
 const message={version:1,documentID:docID,page:location.href.slice(0,16384),images:[...found.values()],active};
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
globalThis[KEY]={scan:()=>scan(true),active:()=>{scan(true);return chosen;}};start();
})();
