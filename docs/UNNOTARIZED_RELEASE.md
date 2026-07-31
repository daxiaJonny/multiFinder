## 下载

请在本页的 **Assets** 区域下载 `MultiFinder.zip`。这是已经编译好的 macOS
应用安装包，解压后里面是 `MultiFinder.app`，需要 macOS 14 或更高版本。

不要下载 GitHub 自动附带的 `Source code (zip)` 或 `Source code (tar.gz)`；
它们只是源码，不能直接安装运行。

## 安装

1. 解压 `MultiFinder.zip`。
2. 将 `MultiFinder.app` 拖入“应用程序”文件夹。
3. 双击打开 MultiFinder。

这个自动构建版本采用 ad-hoc 签名，没有 Apple Developer ID 证书，也没有经过
Apple 公证。首次打开时，macOS 出现“无法验证开发者”或“Apple 无法检查是否包含
恶意软件”的提示是预期行为。

如果系统阻止打开：

1. 先在提示窗口中点“完成”或“取消”。
2. 打开“系统设置” -> “隐私与安全性”。
3. 在安全性区域找到被阻止的 MultiFinder，点击“仍要打开”。
4. 在确认窗口中再次点击“仍要打开”。

只应对从本仓库 Release 页面下载、并且校验值一致的安装包执行上述操作。

## 校验下载文件

同时下载 `MultiFinder.zip.sha256`，在两个文件所在目录运行：

```sh
shasum -a 256 -c MultiFinder.zip.sha256
```

输出 `MultiFinder.zip: OK` 才表示下载文件与发布时生成的文件一致。
