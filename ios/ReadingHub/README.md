# 书房：Yōkai + 栖页

原生宿主组合两个现有 iOS 阅读器。Yōkai 的 SwiftUI、Android 插件运行时和栖页的原生控制器、共享 WebAssets 直接编入同一 App；各自的书架、阅读界面、导入和同步仍使用原代码。两份独立 IPA 的构建入口保持可用。

## 使用与数据

安装名称为「书房」，独立图标将小说书页和漫画分镜放在同一本打开的书中，使用现有阅读器的紫色调。图标由内置 image_gen 生成，提示词保存在 `Design/IconPrompt.txt`。首页选择漫画或栖页；漫画的「更多」菜单和栖页书架右上角的「切换阅读器」返回首页。栖页阅读时隐藏切换按钮。

- `readinghub://yokai` 打开漫画。
- `readinghub://qiye` 打开栖页。
- 快捷指令中的「打开阅读器」可以选择模块，并提供「打开漫画」「打开栖页」App Shortcuts。

栖页原有「导入」和文件选择器保留。通过 Files/分享打开 EPUB、TXT、MOBI、AZW、AZW3、FB2、HTML 等文件时直接进入栖页；漫画备份、图片、ZIP、APK/JAR 进入漫画。共享的 PDF/CBZ 格式由用户选择目标书库。模块内的导入按钮始终使用各自原有逻辑。

本次宿主沿用 `com.wyih.qiyereader`，直接覆盖已安装的栖页，保留它的沙盒和钥匙串，只占一个免费签名 App 名额。因此这个整合版与独立栖页不能同时安装。独立栖页 IPA 仍可单独安装；切回独立版时漫画数据仍留在其沙盒内，需要先导出备份以便继续使用。

栖页保留 `Application Support/QiyeReader`、原有凭据服务和同步格式。漫画使用 `Documents/Yokai`、`Application Support/Yokai`、`com.wyih.readinghub.yokai` 设置域，两个书库各自管理 WebDAV。直接安装后不需要 LiveContainer 或 JIT。

从旧 LiveContainer 转移的数据包括漫画书库、历史、下载队列、封面与章节文件、已安装插件和设置。一次性迁移构建仅复制原 Yōkai 独立钥匙串组中的图源和 WebDAV 项目；完成后重新安装普通构建，移除该临时钥匙串权限。发布 IPA 不含用户数据、迁移权限或 LiveContainer 依赖。

## 构建

需要 macOS/Xcode、当前 Yōkai 仓库及 [tsuilf/qiye-reader](https://github.com/tsuilf/qiye-reader) 工作副本；栖页需包含宿主生命周期接口提交 [b1e4d4e](https://github.com/tsuilf/qiye-reader/commit/b1e4d4e) 或其后续版本。默认相邻目录 `../../../qiye-reader`，也可以设置 `QIYE_READER_ROOT`。生成项目引用原始源文件，WebAssets 从栖页 `app/src/main/assets` 复制至忽略的构建目录。

```sh
./build-ipa.sh
./build-ipa.sh --install
```

产物为 `build/ReadingHub.ipa`。`READING_HUB_TEAM`、`READING_HUB_DEVICE` 覆盖本机默认团队和设备。Xcode Personal Team 签名仍需定期续签。

本机已将既有 Codex 续签任务改为「Health Monitor 与书房自动续签」：仍每 6 小时检查、剩余不超过 72 小时时续签。历史脚本 `health_monitor/scripts/renew-qiye.py` 使用已验证的完整书房固定 IPA，配置及状态也已更新为 0.1.0（1）。它不会将后续工作区改动自动安装到手机；未来更新版本后需要明确更新固定包。

独立构建入口为 Yōkai 的 `../build-ipa.sh` 和栖页的 `ios-app/tools/build-ipa.sh`。宿主独有逻辑通过 `READING_HUB` 编译条件隔离；独立版保持原路径和设置域。

## 验证范围

同步及路由单元测试、栖页核心测试和宿主 UI 测试验证现有受影响流程。OpenJDK 的模拟器构建有项目已记录的 CodeCache 初始化限制；宿主路由 UI 测试在 Debug 模拟器中跳过 Java 启动，插件必须另在真机验证。Release 真机构建始终加载真实运行时。

这里保留的是两份现有 iOS 实现的功能。Yōkai iOS 与 Android 的剩余差异仍见 `../README.md`；组合宿主本身不补齐那些差异。

2026-10-08 验证：宿主和两个独立目标均通过 Release 构建；宿主签名与三个 IPA 的 ZIP 完整性通过检查。21 项 SyncCore、2 项路由测试通过；栖页核心测试执行 48 项通过、6 项跳过。宿主路由 UI 测试验证首页切换及两个 URL 入口；原栖页 UI 测试分别通过设置、阅读屏幕与缩放、多格式导入和批注流程。真机直接签名安装后，栖页 11 本书与原导入选择器保留，漫画恢复 78 条书库记录、已安装的 8 个源及离线文件；1,691 个文档文件和 14 个持久化支持文件与迁移前大小匹配，9 条钥匙串记录迁移成功。花咔能加载列表，漫蛙能加载章节列表，已下载章节能恢复 4/82 阅读位置并点按滚动。未将这些检查扩大为所有源的登录、后台下载或两端 WebDAV 全流程验证。
