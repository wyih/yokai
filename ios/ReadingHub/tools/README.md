# 微信读书上传书取回

在 Mac 上双击 `取回微信读书.command`，输入书名。首次使用会自动准备依赖，并打开独立的 Chrome 窗口；在这个窗口扫码登录微信读书。以后复用该窗口的登录状态，过期时重新扫码。

默认文件保存在 `~/Downloads/微信读书导出/`。TXT 来源同时生成 UTF-8 TXT 和带原目录的 EPUB；书房使用 EPUB 导入，以便保留目录和阅读位置。纯文字 EPUB 也支持。取回的是微信读书中处理后的正文，不保证与最初上传文件逐字节相同。

脚本保存章节缓存，中断后重跑会复用已经取得的 TXT 章节。重名书会让你选择。书目索引保存在 `~/Documents/书房/微信读书书目索引.json`，脚本优先按书名或作者查索引，直接打开对应阅读页。索引支持 TXT、EPUB 和 PDF；PDF 目前只记录书目。普通网页书架首次显示 50 本，滚动到底部会继续加载。新增书尚未入索引时，脚本会查当前网页书架；也可用 `--url` 指定实际阅读页链接。

阅读位置另存为同名 `.progress.json`。TXT 按章节和正文偏移定位；EPUB 默认定位到原章节开头，并记录原百分比。如需精确定位 EPUB，可用 `--position-quote` 提供原阅读页的一句唯一文字。含内嵌图片等尚未适配的 EPUB 会明确报错。

本机有已配对的 iPhone，且装有书房时，可加 `--device` 自动导入。导入时暂停书房，写入书籍后核验文件及书库，再打开栖页。重复导入相同文件会保留书房现有的进度、笔记和书签。

```sh
python3 weread_export.py --title '书名'
python3 weread_export.py --find --title '书名或作者'
python3 weread_export.py --title '书名' --device '已配对的设备标识'
python3 weread_export.py --capture '/完整路径/章节缓存.json'
```

浏览器取回需要 `pyppeteer==2.0.0`，启动器自动安装；缓存解码、打包、验证及手机导入只用 Python 标准库和 Apple 的 `devicectl`。手机导入需要 Xcode 和有效的设备配对。缓存仅保存书籍信息、正文和位置，不提取或保存 Cookie、认证头及请求签名。

已验证：通过当前登录的原生 Chrome 取回一本 134 章 TXT；正文有效批次累计约 146 秒，解码并打包约 0.2 秒。书房阅读引擎已验证 TXT、非零 TXT 偏移，以及 EPUB 原句位置。独立浏览器已验证启动和依赖，双击入口已验证从缓存生成文件；独立窗口登录后的全程取回仍需首次扫码后验证。上述时间不包含首次安装依赖、扫码和调试，也不代表多本书的平均值。

`weread_collect_native.mjs` 是 Codex 当前 Chrome 会话的采集适配器，产生同样的章节缓存；双击入口不依赖它。分片解码算法参考 [danleegle/wxBook](https://github.com/danleegle/wxBook)，已用实际 TXT 和 EPUB 内容验证。个人书目文件与正文保存在仓库外或忽略目录，不随代码提交。

运行小范围回归检查：

```sh
python3 -m unittest discover -s . -p 'test_weread_export.py' -v
```
