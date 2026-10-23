# Safari 地址/搜索栏菜单实现证据

## 交付与范围

- 实现：`src/Menus.m`；入口：`PVXInstallMenuHooks()`。
- 新 UIAction 标题：`下载视频与图片`；标识：`com.crctdd.pyvideo.plus.address-downloads`；动作在主队列异步调用 `PVXOpenDownloads()`。
- 仅 Safari bundle `com.apple.mobilesafari`；仅下列两个地址栏专有类，不 hook 全局 UIMenu、UIContextMenuConfiguration、UIView、UIResponder、BrowserController 或 SFBarRegistration。
- 原有 SFBarRegistration 标签按钮菜单和原始 PyVideo 二进制均不修改。
- 未运行、注入或安装到设备；全部结果是公开头文件研究、源码静态检查和交叉编译，不能当作 iOS17.3 实机验证。

## 确认的真实选择器及固定版本来源

研究实际通过 git/curl 获取文件，不依据猜测命名。以下链接固定 commit，可重现。

### 主路径：胶囊地址栏长按上下文菜单，iOS15.5 / 16.4 / 17

类：`CapsuleNavigationBarViewController`，位于 MobileSafariUI 私有 framework。
方法：`- _contextMenuActionProvider`，返回 block。

1. iOS15.5：
   https://raw.githubusercontent.com/lechium/iPhone_OS_15.5/0f4def7da3cad33a6ea5a4224f4ec3526f3e73f8/System/Library/PrivateFrameworks/MobileSafariUI/CapsuleNavigationBarViewController.h
   声明第67行：`- (CDUnknownBlockType)_contextMenuActionProvider;`
   第68行：`- (id)contextMenuInteraction:(id)arg1 configurationForMenuAtLocation:(struct CGPoint)arg2;`
   该类明确遵循 `UIContextMenuInteractionDelegate`，含 `_contextMenuInteraction` 和 `_showingContextMenu` ivar。
   SHA256：`99938fbe6ffe960fad48ebc70a283ce767ccf7fea3b024a44fc26a9d269f2169`。
2. iOS16.4：
   https://raw.githubusercontent.com/lechium/iPhone_OS_16.4_20E247/6e936b9f702d6d5746430d3d918709479dffafb5/System/Library/PrivateFrameworks/MobileSafariUI/CapsuleNavigationBarViewController.h
   第55行同名 block-return 方法；第56行同名菜单配置 delegate 方法。
   SHA256：`6c41742420360517d62331ec96d8804356834e1d1d4648c0397dbd9084beb981`。
3. iOS17：
   https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/d1d960dfaa4107765dd7fcf891e4967c0930d5fd/PrivateFrameworks/MobileSafariUI.framework/CapsuleNavigationBarViewController.h
   声明：`- (id /* block */)_contextMenuActionProvider;`，同类也有 `contextMenuInteraction:configurationForMenuAtLocation:`、`updateVisibleContextMenu`、`selectedItemNavigationBar`、`unifiedField`。
   SHA256：`8d7178837068d34f21cc477b617fe9c259540f1ddcbe2b7cdc21266920af822c`。

此路径是地址栏控制器自己的 action provider，不是 tab switcher provider。Hook 先调用原方法，再包装其原 block；每次 UIKit 调用包装 block 时，原 provider 恰好调用一次，原 suggestedActions 原样传入，然后在其返回 UIMenu 上追加。

头文件没有 provider 函数体，因此不能据此声称已经动态确认截图中 Paste and Go / Voice Search / Move to Tab Group 的完整内容或 iOS17.3 的实际调用栈。这是有强类/协议/selector 证据的定向接入点，而不是已完成的真机覆盖保证。

### 第二路径：传统/顶部 URL 按钮的 edit menu，iOS16.4 / 17

类：`_SFNavigationBarURLButton`，SafariServices framework。
方法：`- editMenuInteraction:menuForConfiguration:suggestedActions:`。

- iOS16.4 固定来源：
  https://raw.githubusercontent.com/lechium/iPhone_OS_16.4_20E247/6e936b9f702d6d5746430d3d918709479dffafb5/System/Library/Frameworks/SafariServices/_SFNavigationBarURLButton.h
  第30行：`- (id)editMenuInteraction:(id)arg1 menuForConfiguration:(id)arg2 suggestedActions:(id)arg3;`
  该类有 UIEditMenuInteraction ivar，及 `pasteAndGo:`、`pasteAndSearch:`、`_handleLongPress:`。
  SHA256：`85b3397384786145182f9d3eaa230d3791d58420a0e7170f3f9a3387752ec87e`。
- iOS17 固定来源：
  https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/d1d960dfaa4107765dd7fcf891e4967c0930d5fd/Frameworks/SafariServices.framework/_SFNavigationBarURLButton.h
  同名方法，该类显式遵循 `UIEditMenuInteractionDelegate`，保留上述粘贴和长按方法。
  SHA256：`d30273997a06588e0f2c9c16142b095851fc9b44a42ee1e3524c81173becf6a7`。
- iOS15.5 对照：
  https://raw.githubusercontent.com/lechium/iPhone_OS_15.5/0f4def7da3cad33a6ea5a4224f4ec3526f3e73f8/System/Library/Frameworks/SafariServices/_SFNavigationBarURLButton.h
  没有该 UIEditMenu delegate 方法，只有旧式 copy/paste/long-press 方法；因此该分支在 iOS15 不安装，而不是伪造 selector 或全局拦截 UIMenuController。
  SHA256：`ffb429d66c46c64281fd59d2a2614e122a6bba190db42dee0c005c4df4ed93d4`。

## ABI、防重复与原菜单保真

- Method 运行时检查参数数量、object 返回、self/object 参数及 SEL 参数；provider 方法还要求返回类型恰为 `@?`。
- provider 返回对象须为 NSBlock 子类，使用 Clang Blocks ABI 的 signature descriptor 验证 block 返回 object、参数为隐式 `@?` 加一个 object，然后才转成 UIContextMenuActionProvider 调用。若签名缺失或不符，原样返回原 provider。
- UIKit 已安装 SDK 的 UIContextMenuConfiguration.h 第30行确认公开 typedef：`UIMenu * _Nullable (^UIContextMenuActionProvider)(NSArray<UIMenuElement *> *suggestedActions)`。
- Blocks ABI 参考：https://clang.llvm.org/docs/Block-ABI-Apple.html 。仅读取 descriptor，不修改 invoke 指针，不进行 ptrauth 操作。
- 使用 `menuByReplacingChildren:` 保留原 root metadata；原 children 实例、原 action handler、disabled/destructive attributes、deferred elements 保留，不重建原菜单；nil/non-UIMenu/off-main 返回原值。
- 按唯一 identifier 递归检查已物化的子菜单；再次构建菜单不会重复追加。不会按本地化标题误删别人的动作。原有 PyVideo tab entry 保留，不尝试跨菜单移除。
- 不改任何 completion handler，不重建 UIContextMenuConfiguration，因此原 preview/provider/dismissal 行为不受主动替换。
- dyld image notification 只排队 main-queue 安装，避免在 dyld lock 下访问 ObjC/hook；atomic 合并重复通知。安装状态由 original IMP 标识，所有 hook 安装串行。支持后加载 Safari frameworks。
- 日志只包含固定类名/状态，不记录网页 URL、cookie 或媒体签名 URL。

## 运行时限制和待验收项

- iOS17.3 未取得对应系统头文件/调用栈，只能依据 iOS17 公共 dump 和实际运行时 presence/type gating。任何 ABI 改变都 fail closed。
- iOS15 旧式顶部 URL 按钮 UIMenuController 路径没有可靠的 per-instance UIMenu 接入点，本模块不声称覆盖；iOS15 胶囊地址栏主路径有明确头文件支持。
- 不修改 iPad unified tab-strip/tab overview 菜单，也不冒充地址栏 hook；这些布局可能不经过本模块的两条路径。不能承诺所有 Safari UI 布局都有新增项。
- dedup 不主动解析未展开的 UIDeferredMenuElement；该模块自身总是在已返回 root 添加，因此本模块重复经过两个路径仍会识别已有 root action。
- 若 NSBlock 的 signature metadata 不可用，主 provider 原样保留且不注入；没有危险的猜测 ABI fallback。
- 真机验收仍需授权的测试者手动执行：顶部/底部地址栏长按、空/非空剪贴板、语音搜索可用/不可用、不同标签组、取消/重新打开、原标签按钮入口、关闭/重开 Safari、非地址栏网页/收藏/标签菜单无污染，以及下载面板能否正确展示。此任务未执行任何这些设备操作。

## 已执行的静态验证

工具：Alpine clang 19.1.4；target arm64-apple-ios15.0；ARC + blocks。

1. SDK26.5 严格语法：exit 0，无 diagnostics：
   `clang -target arm64-apple-ios15.0 -isysroot /root/.ios-sdk/iPhoneOS26.5.sdk -F/root/.ios-sdk/iPhoneOS26.5.sdk/System/Library/SubFrameworks -fobjc-arc -fblocks -fsyntax-only -Wall -Wextra -Werror src/Menus.m`
2. SDK16.5 严格语法：exit 0，无 diagnostics：
   `clang -target arm64-apple-ios15.0 -isysroot /root/theos/sdks/iPhoneOS16.5.sdk -fobjc-arc -fblocks -fsyntax-only -Wall -Wextra -Werror src/Menus.m`
3. SDK26.5 object 编译 `-c -o /tmp/pvx-Menus.o`：exit 0；file 识别为 `Mach-O 64-bit arm64 object`。未 link、签名、安装或执行。
4. Python 源码断言12/12 PASS：两个显式 hook、未触及 SFBarRegistration、无全局 UIKit 菜单 hook、provider 原参数单次转发、edit callback 原参数转发、nil 保持、原 children/metadata 保持、递归 identifier dedup、方法与 block 签名检查、Safari bundle gate、主队列下载动作、后加载 image 支持。这些是 source-invariant 检查，不是 UIKit 行为测试。

Menus.m SHA256：`b06b7c1bf60fbc713bb7df555d277380554d9aaf702e8ce4270c8c3572250f96`。
