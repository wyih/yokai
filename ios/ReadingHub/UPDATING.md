# 本机自动更新书房

小虹已授权本机定时任务完成：拉取栖页 → 整合书房 → 检查 → 本地 Xcode 构建 → 覆盖安装已配对 iPhone → 更新续签固定包 → commit/push `wyih/yokai` 的 `codex/ios-port`。在 Codex 中每天北京时间 20:00 检查一次；安装和验证完成后才推送。可在 Codex 暂停「书房自动同步栖页」。

## 判断是否需要更新

- 栖页为相邻的 `qiye-reader` 仓库，跟踪 `origin/main`。先 fetch，再用 `git pull --ff-only` 拉取；书房也先核对远端分支。保留其他工作产生的修改，有冲突时等待处理，不 reset、stash 或覆盖它们。
- 已安装来源以 `health_monitor/private/qiye-renewal/source.ipa` 中的 `HubQiyeCommit` 为准，同时核对 `config.json`、`state.json` 与手机实际版本。比较该提交至栖页 `origin/main` 的实际差异。
- 更新范围为 `app/src/main/assets/`、`ios-app/App/`、`ios-app/Sources/`、`ios-app/Config/`、`ios-app/Package.swift` 及依赖锁定文件。仅 Android、桌面、文档或测试变化时不安装。共享发布说明或 iOS 版本变化也同步到书房。
- 有更新时递增 `generate-project.py` 的书房 patch 版本和 build，更新 README 中的来源与实际变化。临时文件及日志放在 `build/update-版本/`，设置 `TMPDIR`、`TMP`、`TEMP` 到该目录下的 `runtime/`。
- 未完成的更新记录在忽略目录 `build/auto-update/state.json`：保存来源提交、目标版本、当前阶段、改动文件清单和产物路径。设备离线时保留构建结果，下次从安装继续；若来源或本地修改变化，先核对再继续，不重复升版。

## 构建与验证

1. 运行栖页 `swift test --package-path ios-app --disable-sandbox` 和书房 `swift test --package-path ios --disable-sandbox`。按实际变动运行相关测试；共享 UI 变更时验证 iPhone 和 iPad。纯版本同步做双模块切换烟测即可。
2. 栖页和书房的源文件直接引用；用 `python3 ios/ReadingHub/generate-project.py` 生成工程。漫画运行时源码或依赖有变化时先执行 `python3 ios/Runtime/prepare.py`。
3. 本机所有 `xcodebuild` 保留 `health_monitor/scripts/signing-readonly-accounts.sb` 的账户只读保护。通过 `/usr/bin/sandbox-exec` 指定 `PREFERENCES_DOMAIN=com.apple.dt.Xcode` 和当前用户的 `Library/Preferences/com.apple.dt.Xcode.plist`；传入 `-IDEPackageSupportDisableManifestSandbox=YES` 及 `OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox`，避免嵌套沙盒冲突。保护不可用时停止，不绕过。
4. 正式构建使用 `Release`、`-sdk iphoneos`、`-destination generic/platform=iOS`、`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`，完成后单独签名。不使用命令行 `-allowProvisioningUpdates`，不触发云构建。
5. 模拟器使用 `build-for-testing`、`-sdk iphonesimulator`、`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`。依次执行 iPhone、iPad 的 `ReadingHubUITests/HubFlowTests/testReadersAndDirectURLs`；有 UI 变化时加入相应 `AppFlowTests`。沿用同一有效构建，失败先看日志再针对性重跑。
6. 可复用 `build/update-0.1.9/Device`、`build/update-0.1.9/Simulator` 的 DerivedData。正式与模拟器构建完成后分别核对版本、来源提交及 WebAssets；不得把另一轮旧产物当成本轮结果。

## 签名、安装与续签

- 签名与设备参数从相邻 `health_monitor/private/qiye-renewal/config.json` 读取。沿用同 bundle/team，安装对象必须是同时包含 `Engine.jar`、`compat.jar`、`Extensions`、`lib/lib/modules` 和 `WebAssets` 的完整 `ReadingHub.app`。
- 检查包为 iPhoneOS arm64、`HubQiyeCommit` 对应本次源码、所有共享资源内容一致、没有一次性迁移权限，正式二进制不包含测试脚本入口。签名复用有效描述文件及匹配的本地证书，只使用已批准的 application/team/get-task-allow 权限，验证 codesign 与 IPA ZIP 完整性。
- 需要续期时复用 `health_monitor/scripts/renew-qiye.py` 与 `xcode_account.py` 已有流程：检查本机登录及钥匙串状态，通过受保护 Xcode 申请描述文件，不修改或清空账户。手机离线、Mac 锁屏或证书暂不可用时保留阶段记录，留待下次继续。
- 安装前后通过 `devicectl` 只读复制两份 `Library/Application Support/{QiyeReader,Yokai}/library.json`，记录 Documents 文件路径与大小，核对保留情况。复制命令不得使用 `--remove-existing-content true`。只覆盖安装，不卸载。尝试启动；手机锁屏拒绝启动时记录真实结果，已安装版本与数据核对仍需完成。
- 安装成功且两库/文档核对通过后，在 `health_monitor/build/qiye-renewal.lock` 上取得排他锁，备份旧固定包、配置和状态到本次忽略目录，再将新 IPA 更新为 `private/qiye-renewal/source.ipa`，同步 `config.json` 与 `state.json` 的版本/build、签名到期时间和安装时间。保留设备与团队信息。最后运行普通 `python3 scripts/renew-qiye.py` 验证配置，不用 `--force` 或 `--install`。
- 自动续签任务负责已配置版本的续期；本更新任务负责更换版本。续签任务从本地配置读取当前版本，不在任务提示中重复固定版本，避免两处信息不一致。

## 提交与通知

安装完成后，在 README 记载来源提交、实际功能变化、验证和安装结果；按明确文件清单提交，不提交构建产物、个人数据、密钥或账户文件。再次核对远端并 push，确认本地 HEAD 等于远端目标分支。将阶段记录标为完成。

没有相关更新、临时离线或相同等待条件未变时安静结束。成功更新后简短报告版本、实际变化、安装及推送结果；新的实质错误或需用户介入时说明具体原因。
