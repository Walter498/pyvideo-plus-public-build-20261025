#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
static const struct mach_header *Images[4];static uint32_t Count;static void *Owner;
static uint32_t TestImageCount(void){return Count;}
static const struct mach_header *TestImageHeader(uint32_t n){return n<Count?Images[n]:NULL;}
static int TestDladdr(const void *p,Dl_info *info){(void)p;if(!Owner)return 0;info->dli_fbase=Owner;return 1;}
#define _dyld_image_count TestImageCount
#define _dyld_get_image_header TestImageHeader
#define dladdr TestDladdr
#import "PVXAgentIdentity.h"
#undef dladdr
static unsigned int Checks;
#define CHECK(c) do{Checks++;if(!(c)){fprintf(stderr,"FAIL identity line %d\n",__LINE__);return 1;}}while(0)
typedef struct{struct mach_header_64 h;struct uuid_command uuid;} Image;
static Image Make(uint32_t type){Image i={0};i.h.magic=MH_MAGIC_64;i.h.cputype=CPU_TYPE_ARM64;i.h.cpusubtype=CPU_SUBTYPE_ARM64E|0x80000000;i.h.filetype=type;i.h.ncmds=1;i.h.sizeofcmds=sizeof(i.uuid);i.uuid.cmd=LC_UUID;i.uuid.cmdsize=sizeof(i.uuid);unsigned char u[16]={0xf2,0xff,0xad,0x31,0xea,0x7d,0x31,0xf1,0xb1,0x89,0x24,0x12,0x52,0x29,0x74,0x19};memcpy(i.uuid.uuid,u,16);return i;}
int main(void){@autoreleasepool{
 Image hook=Make(MH_DYLIB),agent=Make(MH_EXECUTE),foreign=Make(MH_EXECUTE);
 Images[0]=(void *)&hook;Images[1]=(void *)&agent;Count=2;
 CHECK(PVXAgentExecutableHeader()==(void *)&agent);
 Owner=&agent;
 CHECK(PVXAgentOwnsExport((char *)&agent+0x1a81f8,"PVRemuxHLSWithCancel"));
 CHECK(PVXAgentOwnsExport((char *)&agent+0x263500,"PVXAgentRemuxMutex"));
 CHECK(!PVXAgentOwnsExport((char *)&agent+0x263508,"PVXAgentRemuxMutex"));
 CHECK(!PVXAgentOwnsExport((char *)&agent+0x1a81fc,"PVRemuxHLSWithCancel"));
 Owner=&hook;CHECK(!PVXAgentOwnsExport((char *)&agent+0x1a81f8,"PVRemuxHLSWithCancel"));
 Owner=NULL;CHECK(!PVXAgentOwnsExport((char *)&agent+0x1a81f8,"PVRemuxHLSWithCancel"));
 foreign.uuid.uuid[0]^=1;Images[2]=(void *)&foreign;Count=3;
 CHECK(PVXAgentExecutableHeader()==(void *)&agent);
 foreign.uuid.uuid[0]^=1;CHECK(PVXAgentExecutableHeader()==NULL);
 Count=2;agent.uuid.uuid[0]^=1;CHECK(PVXAgentExecutableHeader()==NULL);agent.uuid.uuid[0]^=1;
 agent.h.filetype=MH_DYLIB;CHECK(PVXAgentExecutableHeader()==NULL);agent.h.filetype=MH_EXECUTE;
 agent.uuid.cmdsize=4;CHECK(PVXAgentExecutableHeader()==NULL);agent.uuid.cmdsize=sizeof(agent.uuid);
 agent.h.sizeofcmds=4;CHECK(PVXAgentExecutableHeader()==NULL);
 printf("PASS Agent identity: %u production-helper assertions, hook at image0, Agent at image1, wrong UUID/owner/RVA/duplicate/malformed refusal\n",Checks);
 return 0;
}}
