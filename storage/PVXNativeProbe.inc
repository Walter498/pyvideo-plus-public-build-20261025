// Opaque libav API diagnostics only: never assumes AVFormatContext layout.
static void *PVXAgentExport(const char *name) {
    (void)dlerror();void *p=dlsym(RTLD_DEFAULT,name);const char *e=dlerror();Dl_info info={0};
    return !e&&p&&dladdr(p,&info)&&info.dli_fbase==(void *)_dyld_get_image_header(0)?p:NULL;
}
static NSDictionary *PVXInputProbe(const char *path) {
    int (*openInput)(void **,const char *,const void *,void **)=PVXAgentExport("avformat_open_input");
    int (*findInfo)(void *,void **)=PVXAgentExport("avformat_find_stream_info");
    void (*closeInput)(void **)=PVXAgentExport("avformat_close_input");
    int (*setOption)(void **,const char *,const char *,int)=PVXAgentExport("av_dict_set");
    void (*freeOptions)(void **)=PVXAgentExport("av_dict_free");
    if(!openInput||!findInfo||!closeInput||!setOption||!freeOptions)return @{@"available":@NO};
    void *context=NULL,*options=NULL;
    setOption(&options,"protocol_whitelist","file,crypto",0);
    setOption(&options,"allowed_extensions","ALL",0);
    setOption(&options,"probesize","1048576",0);
    setOption(&options,"analyzeduration","3000000",0);
    int opened=openInput(&context,path,NULL,&options);
    freeOptions(&options);
    NSMutableDictionary *details=[@{@"available":@YES,@"openReturn":@(opened),
        @"scope":@"independent-input-probe-not-original-internal-stage"} mutableCopy];
    if(opened>=0)details[@"streamInfoReturn"]=@(findInfo(context,NULL));
    closeInput(&context);
    return details;
}
