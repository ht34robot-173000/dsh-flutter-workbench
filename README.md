# DSH 工作台 · Flutter 版

DSH（DeepSeek Harness）桌面版的**手机端远控客户端**。用手机浏览会话、看实时输出、发消息、传文件。

Flutter 重写版，与早期 Kotlin 版并存（包名不同，可同时安装）：

| 版本 | 包名 | 状态 |
|---|---|---|
| **Flutter**（本仓库） | `com.dsh.flutter_workbench` | 主力开发 |
| Kotlin（历史备份） | `com.dsh.workbench` | 仅作参考，不再更新 |

## 它解决什么问题

DSH 跑在电脑上，人不在电脑前时看不到任务进度。这个 App 让你在手机上：

- 翻会话列表，看哪些任务在跑
- 进会话看历史，**逐字看**助手正在写什么
- 直接发消息（排队或插话）
- 浏览、预览、上传、下载宿主机的文件
- 扫二维码配对，不用手输密码

## 前置条件

需要先在电脑上装宿主插件 [`dsh-remote-workbench`](https://github.com/ht34robot-173000/dsh-remote-workbench)。

## 功能与阶段

| 阶段 | 内容 | 状态 |
|---|---|---|
| ① | 连接与配对（局域网 / 公网双地址，cookie 按 authority 隔离） | ✅ |
| ② | 会话列表（分组折叠、Mica 背景、自有矢量图标库） | ✅ |
| ③ | 对话与 SSE 实时流（status / event / chunk 三类帧，逐字显示） | ✅ |
| ④ | 文件管理（浏览、预览、编辑、新建、重命名、删除、上传、下载） | ✅ |
| ⑤ | 扫码配对（相机实时 + 图库选图解码） | ✅ |
| ⑥ | 应用内更新（查 GitHub Release、多镜像下载、拉起安装器） | ✅ |

当前版本 **0.6.0**（versionCode 600）。

## 构建

### 环境

| 项 | 版本 |
|---|---|
| Flutter | 3.35.4（Dart 3.9.2） |
| JDK | 21 |
| Android SDK | compileSdk 36，minSdk 26 |

### 命令

```bash
flutter pub get
flutter test          # 47 个用例
flutter build apk --release
```

产物在 `build/app/outputs/flutter-apk/app-release.apk`。

### 关于签名

`android/app/build.gradle.kts` 从**仓库外部**读 keystore：

```
F:/dsh-mobile-signing/keystore.properties
```

找不到就自动退回 debug 签名 —— 所以任何机器都能编出可安装的包，不会因为缺密钥而失败。
**仓库里不含任何密钥或密码。**

## 目录

```
lib/
  data/
    prefs.dart        配置落盘（地址/cookie 按模式隔离）
    ds_api.dart       /rw/api/* 封装
    live.dart         SSE 客户端
    fs_api.dart       文件接口
    scan_parse.dart   配对二维码解析
    update_api.dart   版本检查 + 多镜像下载
    installer.dart    MethodChannel 封装（安装器）
  ui/
    icons.dart        自有矢量图标库（48+ glyph，零图标包依赖）
    theme.dart        配色令牌 + Mica 背景
    session_list_page.dart
    chat_page.dart
    file_browser_page.dart
    scan_page.dart
    update_page.dart
test/                 47 个用例
  live_parse_test.dart   SSE 帧 + 两种消息结构
  fs_test.dart           文件层解析
  scan_parse_test.dart   二维码解析
  update_test.dart       版本比较 + 镜像展开
```

## 几个踩过的坑

这些都是**静默失败** —— 不报错、不写日志，只能靠实测发现。写在这里免得重蹈。

### SSE 不能用 dio

`dio.get<ResponseBody>(responseType: stream)` + `receiveTimeout: null` 只吐第一批字节就停，
宿主明明在推数据。改用 `dart:io` 的 `HttpClient` 裸连才对。

### `chunk` 帧是对象不是字符串

```json
{"chunk":{"type":"text-delta","index":0,"text":"你好"}}
```

写 `(j['chunk'] ?? '').toString()` 会得到 Dart Map 的乱码。

### 两种消息结构不一样

- `user/message` 的 `data` **本身就是消息**
- `assistant/message` 的 `data` 里还有一层 `message`

写 `data.message` 对前者永远拿到 null —— 结果是「用户自己的提问一条都不显示」。

### viewBox 的 y 原点是 -960

Material Symbols 的 `viewBox="0 -960 960 960"`，缩放后**必须**补
`canvas.translate(0, +960)`。漏了图标会向上溢出整整 960 单位，
看起来像「图标浮在文字上方」。

### file_picker 默认压缩会让 App 闪退

`allowCompression` 默认 `true`，选到图片会走 `compressImage`，
在 Android 13+ 抛 `Failed to validate`。**这个异常在后台线程抛，
Dart 侧 try/catch 接不住，进程直接被 SIG:9 杀掉。**
必须显式 `allowCompression: false`。

### GitHub 404 有两种含义

「仓库不存在」和「没发过 release」都返回 404。只看 `releases/latest`
会把前者当成后者，界面显示「已是最新」而更新通道其实早就断了。
必须先探 `/repos/{repo}` 区分。

## 许可

MIT
