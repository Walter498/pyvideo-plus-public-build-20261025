# beta2 视频后台重生根因

2026-10-23 通过 SSH 只读取得现有 worker 日志，没有安装、重启、杀进程或写真机文件。完整探测文件 device-worker-*.json / device-installed/sandyd 等位于本 evidence。

运行日志每约5秒重复 `PyVideo worker storage: 无法取得 PyVideo 目录权限，请检查 libSandy 与插件安装。`，同时出现对 com.opa334.sandyd 的 XPC activation。launchd runs928→1032、lastExit1，main原版在 startWorker 返回false时退出1。

PVPrepareStorage0x10019a82c：先jbroot解路径，0x10019aa10 dlopen libsandy，0x10019aa30 dlsym libSandy_applyProfile，0x10019aa44调用profile PyVideo，非0走0x10019aa54上述错误；此分支发生在目录mkdir循环之前。故不能把memory-policy历史ready当作当前启动已成功，也不是现有目录模式直接造成的mkdir报错。

原 Agent CodeDirectory Identifier为 com.crctdd.pyvideo，已装 Agent为 PyVideoAgent。Info.plist bundleID和application-identifier entitlement仍是com.crctdd.pyvideo，三者不能互换。

真机已装sandyd的resolveCaller0x100005a7c取auditToken、0x100005a9c SecTaskCreateWithAuditToken、0x100005aac SecTaskCopySigningIdentifier；isProfileAllowed0x10000609c读AllowedProcesses、0x1000060dc containsObject caller ID。当前profile仅允许com.apple.mobilesafari和com.crctdd.pyvideo，没有PyVideoAgent。getProcessExtensions0x100006414校验false返回空扩展，libsandy因此apply失败。

beta2 package.py重签只传ldid -S导致默认CodeDirectory使用文件名。这是确定打包缺陷，已改为 `ldid -Icom.crctdd.pyvideo -S<entitlements> <agent>`，并新增直接解析每一个CodeDirectory的Identifier强制断言。未扩大沙箱白名单，未绕过PVPrepareStorage。

证据边界：运行时已证实storage错误出口；已装CodeDirectory身份和sandyd校验规则均已证实；未抓本次apply具体整数码。csops只读查询返回空缓冲区，不能用其当有效内核身份。修复候选包后仍需实际部署确认服务稳定，不能仅依静态签名检查声称真机已跑通。
