# Yōkai Mac 版

首个 Mac 版本为 0.1.0，支持 Apple Silicon 和 macOS 14.5 及以上。解压 `outputs/desktop/Yokai-0.1.0-mac-arm64.zip`，将 `Yokai.app` 放到应用程序目录即可运行。Java 运行时和八个图源插件已包含在应用内。

Mac Catalyst 目标直接复用 iOS 的 SwiftUI 界面、漫画源引擎、书架、阅读设置、下载队列、备份和 WebDAV 协议。书架保存在 `~/Library/Application Support/com.wyih.yokai.desktop/`；图源设置、Cookie 和同步密码通过随应用打包的 macOS 组件保存在系统钥匙串。Mac 下载在应用运行时继续执行，切换窗口不触发 iOS 的后台时间限制。到期的书架更新、插件检查和自动备份每五分钟检查一次。

阅读菜单提供左右方向键、上下方向键和空格翻页；左右键跟随漫画阅读方向。`⌘←` / `⌘→` 切换章节，`⌘T` 切换阅读工具栏，`Esc` 关闭阅读器。全屏使用 macOS 窗口的绿色按钮。

构建需要 Xcode、Swift 和 Python 3.12 及以上：

```sh
./desktop/build-mac.sh
```

产物写入 `outputs/desktop/`。构建复用 `ios/Runtime/dependencies.json` 中固定版本和校验值的依赖。存在唯一有效的 Apple Development 证书时使用该证书签名，否则使用本机临时签名；可通过 `YOKAI_MAC_SIGNING_IDENTITY` 指定身份。安装包尚未经过 Apple 公证。

核心检查使用 Debug 构建，创建独立测试书架，并检查图源加载、钥匙串读写、本地 CBZ 导入和进度保存：

```sh
YOKAI_MAC_CONFIGURATION=Debug ./desktop/build-mac.sh
outputs/desktop/Yokai.app/Contents/MacOS/Yokai --desktop-check "$PWD/ios/build/mac-check" --online
```

结果写入 `ios/build/mac-check/result.json`。`--online` 额外验证热辣漫画的目录、章节、页列表和图片下载。同步合并与 WebDAV 协议沿用 `swift test --package-path ios` 的测试。
