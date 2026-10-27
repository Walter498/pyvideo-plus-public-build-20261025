#import "PVXNativeRemux.h"
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

// Recovered from the original arm64e PyVideoAgent call site:
// (input C path, output C path, error buffer, size, cancel callback, opaque).
typedef int (*PVXRemuxFn)(const char *, const char *, char *, size_t, int (*)(void *), void *);
static PVXRemuxFn PVXRemux;
static dispatch_once_t PVXRemuxOnce;
static NSString *PVXRemuxLoadError;
static int PVXNoCancel(void *opaque){return 0;}

static BOOL PVXResolveRemux(void){
    dispatch_once(&PVXRemuxOnce, ^{
        void *p=dlsym(RTLD_DEFAULT, "PVRemuxHLSWithCancel");
        const char *e=dlerror();
        if(!p){PVXRemuxLoadError=e?[NSString stringWithUTF8String:e]:@"PVRemuxHLSWithCancel 未导出";return;}
        Dl_info info={0};
        if(!dladdr(p,&info)||info.dli_fbase!=(void *)_dyld_get_image_header(0)){
            PVXRemuxLoadError=@"PVRemuxHLSWithCancel 不属于当前 PyVideoAgent 主镜像";return;
        }
        PVXRemux=(PVXRemuxFn)p;
    });
    return PVXRemux!=NULL;
}

BOOL PVXNativeRemuxHLS(NSString *inputPath,NSString *outputPath,NSString **errorText){
    if(errorText)*errorText=nil;
    if(!PVXResolveRemux()){
        if(errorText)*errorText=PVXRemuxLoadError?:@"原生 HLS remux 导出不可用";
        return NO;
    }
    if(!inputPath.length||!outputPath.length){if(errorText)*errorText=@"remux 输入或输出路径为空";return NO;}
    char error[1024]={0};
    int rc=PVXRemux(inputPath.fileSystemRepresentation,outputPath.fileSystemRepresentation,error,sizeof(error),PVXNoCancel,NULL);
    struct stat st={0};
    BOOL outputOK=!lstat(outputPath.fileSystemRepresentation,&st)&&S_ISREG(st.st_mode)&&st.st_size>0;
    if(rc==0&&outputOK)return YES;
    NSString *detail=error[0]?[NSString stringWithUTF8String:error]:[NSString stringWithFormat:@"PVRemuxHLSWithCancel 返回 %d",rc];
    if(errorText)*errorText=detail?:@"原生 HLS remux 失败";
    unlink(outputPath.fileSystemRepresentation);
    return NO;
}
