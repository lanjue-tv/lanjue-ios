# 蓝绝TV+ iOS 自签版（打包工程）

iPhone 原生壳 + 网页内嵌。**不依赖任何服务器**：网页资源全部打进 App，App 内自带本地 HTTP 服务
（`127.0.0.1`，只监听回环地址），连跨域代理 `/p?u=` 都在本机转发。

和网页版的差别只有一点：不需要联网加载页面；片源接口和视频仍然走互联网（那是内容本身）。

---

## 一、拿到 unsigned IPA（GitHub 免费算力编译，约 4 分钟）

> 为什么不能在这里直接给你 IPA：iOS 的二进制必须用 macOS + Xcode 编译，Windows 上做不出来。
> GitHub 的 macOS 机器免费，用它编译一次就行。

### 1. 注册 GitHub

打开 https://github.com/signup ，邮箱 + 密码即可（不用实名、不绑卡）。

### 2. 新建仓库

右上角 `+` → `New repository` → 名字随便填，比如 `lanjue-ios` →
选 **Public**（私有也能用 Actions，但公开额度更宽松）→ 勾上 `Add a README file` → `Create repository`。

### 3. 上传工程文件

1. 把 `lanjue-ios-app.zip`（和这份说明放在同一层目录）解压到桌面。
2. 在仓库页面点 `Add file` → `Upload files`。
3. 把解压出来的**所有内容**（`Sources`、`Resources`、`.github`、`project.yml`）一起拖进网页。
   - Windows 如果看不到 `.github`，先在资源管理器「查看」里勾上「隐藏的项目」。
   - 拖拽整文件夹时，浏览器会保留目录结构，`.github/workflows/build-ipa.yml` 必须一起传上去。
4. 页面下方 `Commit changes`。

### 4. 等它自己编译

推送后会自动开始（仓库顶部 `Actions` → 看到 `Build IPA` 在跑）。
若无反应：`Actions` → 左侧 `Build IPA` → 右侧 `Run workflow` → 绿色按钮。

约 3~5 分钟跑完，点进那次运行，页面底部 `Artifacts` → 下载 `LanJueTV-unsigned-ipa.zip`，
解压得到 **`LanJueTV.ipa`**。

### 5. 自签安装

用你惯用的工具（Sideloadly / AltStore / TrollStore 等）把 `LanJueTV.ipa` 签上自己的证书装进手机。
Bundle ID 默认 `com.lanjue.tv.ios`，自签工具会自动改成你的，不用管。

---

## 二、装好之后你会得到

- 桌面图标「蓝绝TV+」，点开直接进超英专区，**不再有新标签页、地址栏**
- 全屏播放、横屏、画中画、AirPlay 都走原生
- 片库 / 播放进度 / 收藏存在 App 沙盒的 localStorage 里，升级重装同 Bundle ID 会保留
- 不需要输入任何激活码（这是本地版，激活门只存在于分享给别人的港剧支线 APK）

## 三、代码结构

```
project.yml                        XcodeGen 工程描述（含 Info.plist 配置）
Sources/AppDelegate.swift          入口，开屏即全屏、看片不锁屏
Sources/WebViewController.swift    WKWebView 外壳（内联播放/画中画/弹窗处理）
Sources/LocalHTTPServer.swift      本机 HTTP 服务：静态资源 + /p 同源代理
Resources/index.html               主程序（和网页版同一份，已内嵌）
Resources/Assets.xcassets          App 图标
.github/workflows/build-ipa.yml    GitHub Actions 编译脚本
```

## 四、更新内容

改 `Resources/index.html` 就行（从 `lanjue-ios/index.html` 覆盖过来），提交后自动重新编译出新 IPA。

## 五、已知限制

- 自签证书 7 天过期（免费 Apple ID 的情况），到期重新签一次；TrollStore 不受此限。
- 首次播放某部片要测速（和网页版一致，最优源确认后二次打开是秒开）。
- 本工程产物是 unsigned，**只能自己签自己装**，不能直接发给别人装。
