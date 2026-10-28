'use strict';
setImmediate(function(){
 try {
  const ex=n=>Module.getGlobalExportByName(n);
  const dlsym=new NativeFunction(ex('dlsym'),'pointer',['pointer','pointer']);
  const dladdr=new NativeFunction(ex('dladdr'),'int',['pointer','pointer']);
  const header=new NativeFunction(ex('_dyld_get_image_header'),'pointer',['uint']);
  const name=new NativeFunction(ex('_dyld_get_image_name'),'pointer',['uint']);
  const count=new NativeFunction(ex('_dyld_image_count'),'uint',[]);
  const read=p=>p.isNull()?null:p.readUtf8String();
  function owner(p){const b=Memory.alloc(Process.pointerSize*4);b.writeByteArray(new Uint8Array(Process.pointerSize*4));const rc=dladdr(p,b);return {rc:rc,path:read(b.readPointer()),base:b.add(8).readPointer().toString(),symbol:read(b.add(16).readPointer()),symbolAddress:b.add(24).readPointer().toString()};}
  const records=[];
  for(const s of ['PVRemuxHLSWithCancel','PVXAgentRemuxMutex','PVStateDirectory']){
   const p=dlsym(ptr(-2),Memory.allocUtf8String(s));
   records.push({name:s,raw:p.toString(),stripped:p.strip().toString(),rawOwner:owner(p),strippedOwner:owner(p.strip())});
  }
  const images=[];
  for(let i=0;i<count();i++){const n=read(name(i));if(i===0||(n&&/PyVideo/.test(n))) {const h=header(i);images.push({index:i,name:n,base:h.toString(),filetype:h.add(12).readU32(),cpu:h.add(4).readU32(),subtype:h.add(8).readU32()});}}
  const exeBuffer=Memory.alloc(4096),exeSize=Memory.alloc(4);exeSize.writeU32(4096);
  const exeResult=new NativeFunction(ex('_NSGetExecutablePath'),'int',['pointer','pointer'])(exeBuffer,exeSize);
  send({event:'resolver-readonly',pid:Process.id,executablePath:exeResult===0?exeBuffer.readUtf8String():null,main:Process.mainModule,images:images,symbols:records});
 }catch(e){send({event:'error',detail:String(e),stack:e.stack});}
});
