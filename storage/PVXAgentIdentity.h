#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <TargetConditionals.h>
#import <string.h>
#import <dlfcn.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif
// RootHide inserts a dylib at dyld image index zero. Enumerate and identify
// the actual executable; never confuse ordering with Mach-O identity.
static inline BOOL PVXIsExpectedExecutable(const struct mach_header *raw) {
    if(!raw||raw->magic!=MH_MAGIC_64||raw->filetype!=MH_EXECUTE)return NO;
    const struct mach_header_64 *h=(const void *)raw;
    if(h->ncmds>4096||h->sizeofcmds>1024*1024)return NO;
#if TARGET_OS_IPHONE
    if(h->cputype!=CPU_TYPE_ARM64||(h->cpusubtype&0xffffff)!=CPU_SUBTYPE_ARM64E)return NO;
    static const unsigned char expected[16]={0xf2,0xff,0xad,0x31,0xea,0x7d,0x31,0xf1,0xb1,0x89,0x24,0x12,0x52,0x29,0x74,0x19};
    BOOL uuidMatch=NO;
#endif
    const unsigned char *cursor=(const void *)(h+1),*end=cursor+h->sizeofcmds;
    for(uint32_t i=0;i<h->ncmds;i++){
        if((size_t)(end-cursor)<sizeof(struct load_command))return NO;
        const struct load_command *lc=(const void *)cursor;
        if(lc->cmdsize<sizeof(*lc)||(size_t)(end-cursor)<lc->cmdsize)return NO;
#if TARGET_OS_IPHONE
        if(lc->cmd==LC_UUID){if(lc->cmdsize!=sizeof(struct uuid_command))return NO;
            uuidMatch=!memcmp(((const struct uuid_command *)lc)->uuid,expected,16);}
#endif
        cursor+=lc->cmdsize;
    }
    if(cursor!=end)return NO;
#if TARGET_OS_IPHONE
    return uuidMatch;
#else
    return YES; // Host executables have their own build UUID; still require unique MH_EXECUTE.
#endif
}
static inline const struct mach_header *PVXAgentExecutableHeader(void) {
    const struct mach_header *found=NULL;
    uint32_t count=_dyld_image_count();
    for(uint32_t i=0;i<count;i++){
        const struct mach_header *h=_dyld_get_image_header(i);
        if(!PVXIsExpectedExecutable(h))continue;
        if(found&&found!=h)return NULL;
        found=h;
    }
    return found;
}
static inline const void *PVXSymbolLookupAddress(void *raw) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(raw,ptrauth_key_function_pointer);
#else
    return raw;
#endif
}
static inline BOOL PVXAgentOwnsExport(void *raw,const char *symbol) {
    if(!raw)return NO;
    const struct mach_header *expected=PVXAgentExecutableHeader();
    const void *address=PVXSymbolLookupAddress(raw);
    Dl_info info={0};
    if(!expected||!dladdr(address,&info)||info.dli_fbase!=(void *)expected)return NO;
#if TARGET_OS_IPHONE
    uintptr_t relative=(uintptr_t)address-(uintptr_t)expected;
    if(!strcmp(symbol,"PVRemuxHLSWithCancel")&&relative!=0x1a81f8)return NO;
    if(!strcmp(symbol,"PVXAgentRemuxMutex")&&relative!=0x263500)return NO;
#else
    (void)symbol;
#endif
    return YES;
}
