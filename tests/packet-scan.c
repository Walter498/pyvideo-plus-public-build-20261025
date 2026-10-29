#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>
#include <limits.h>
#include <string.h>
typedef struct { void *buf; int64_t pts,dts; uint8_t *data; int size,index,flags; } Packet;
__attribute__((constructor)) static void scan(void){
 const char *path=getenv("PVX_PACKET_SCAN");if(!path)return;
 FILE *log=fopen(getenv("PVX_PACKET_LOG"),"w");if(!log)_exit(80);setvbuf(log,NULL,_IOLBF,0);
 int(*op)(void**,const char*,void*,void**)=dlsym(RTLD_DEFAULT,"avformat_open_input");
 int(*info)(void*,void**)=dlsym(RTLD_DEFAULT,"avformat_find_stream_info");
 int(*dict)(void**,const char*,const char*,int)=dlsym(RTLD_DEFAULT,"av_dict_set");
 int(*readp)(void*,Packet*)=dlsym(RTLD_DEFAULT,"av_read_frame");
 Packet*(*alloc)(void)=dlsym(RTLD_DEFAULT,"av_packet_alloc");void(*unref)(Packet*)=dlsym(RTLD_DEFAULT,"av_packet_unref");
 void(*closep)(void**)=dlsym(RTLD_DEFAULT,"avformat_close_input");
 if(!op||!info||!dict||!readp||!alloc||!unref||!closep){fprintf(log,"missing exports\n");_exit(81);}
 void *ctx=NULL,*opt=NULL;dict(&opt,"protocol_whitelist","file,crypto",0);dict(&opt,"allowed_extensions","ALL",0);
 int rc=op(&ctx,path,NULL,&opt);fprintf(log,"open=%d\n",rc);if(rc<0)_exit(82);
 rc=info(ctx,NULL);fprintf(log,"info=%d\n",rc);if(rc<0)_exit(83);
 unsigned char *c=ctx;uint32_t ns=*(uint32_t*)(c+0x2c);void **ss=*(void***)(c+0x30);fprintf(log,"nb_streams=%u\n",ns);
 for(unsigned i=0;i<ns&&i<8;i++){unsigned char*s=ss[i],*par=*(void**)(s+0x10);fprintf(log,"stream=%u tb=%d/%d codec=%d type=%d\n",i,*(int*)(s+0x20),*(int*)(s+0x24),*(int*)(par+4),*(int*)par);}
 Packet *p=alloc();int64_t last[64];for(int i=0;i<64;i++)last[i]=INT64_MIN;long n=0,bad=0;
 while((rc=readp(ctx,p))>=0){n++;int ix=p->index;
  if(n<=40)fprintf(log,"packet=%ld index=%d pts=%lld dts=%lld size=%d\n",n,ix,(long long)p->pts,(long long)p->dts,p->size);
  if(ix>=0&&ix<64&&p->dts!=INT64_MIN){if(last[ix]!=INT64_MIN&&p->dts<=last[ix]){bad++;if(bad<=20)fprintf(log,"BAD packet=%ld index=%d prev=%lld dts=%lld\n",n,ix,(long long)last[ix],(long long)p->dts);}last[ix]=p->dts;}
  unref(p);if(n%100000==0)fprintf(log,"progress=%ld bad=%ld\n",n,bad);
 }
 fprintf(log,"end=%d packets=%ld bad=%ld\n",rc,n,bad);closep(&ctx);fclose(log);_exit(0);
}
