# Scrcpy Desk for macOS

> [官方网站](https://joker311223.github.io/scrcpy/) · [网站源码](../../../docs/) · [上游 scrcpy](https://github.com/Genymobile/scrcpy)

`Scrcpy Desk` 是基于 scrcpy 开发的 macOS SwiftUI 多设备控制台：

- 自动发现并展示 USB / Wi-Fi ADB 设备；
- 通过 IP 和端口执行 `adb connect`；
- 支持 Android 11+ 的 `adb pair` 无线配对；
- 可将任意数量的已连接设备加入右侧展示，并通过常驻横向滚动条查看；
- 每台设备都拥有独立的低延迟 scrcpy 实时会话，可以同时操作；
- 鼠标触控、滚动、键盘、快捷键、剪贴板和音频均由原 scrcpy 客户端处理；
- 支持按设备保存备注名和页面跳链，并通过 VIEW Intent 一键加载页面；
- 不创建或唤起独立的 scrcpy 窗口。

![Scrcpy Desk 多设备控制台](../../../docs/assets/product-dashboard.png)

## 环境

- macOS 13 或更高版本；
- Swift 5.10 或更高版本；
- ADB（构建脚本会将当前 PATH 中的 `adb` 复制进 App）；
- Homebrew 版 FFmpeg 与 SDL3 开发库（`brew install ffmpeg sdl3`）。

## 开发运行

```bash
./gradlew -p server assembleRelease
swift run ScrcpyDesk
```

## 构建 App

```bash
desktop/macos/ScrcpyDesk/build_app.sh
open "desktop/macos/ScrcpyDesk/dist/Scrcpy Desk.app"
```

也可传入自定义输出目录：

```bash
desktop/macos/ScrcpyDesk/build_app.sh /tmp/scrcpy-desk
```

## 连接设备

USB 设备只需启用开发者选项和 USB 调试，连接后会自动出现在左侧。

已有 ADB TCP/IP 地址时，点击“添加设备”，填写 IP 和连接端口（传统模式一般为 `5555`）。Android 11+ 首次使用无线调试时，打开“首次无线配对”，使用手机弹窗中显示的配对端口和六位配对码完成配对，再填写无线调试页显示的连接端口进行连接。

## 多设备展示

每个已连接设备在左侧都有“展示”按钮。加入展示后，右侧会为该设备创建独立 scrcpy 会话；多台设备以固定宽度横向排列，不会因窗口宽度变化而压缩或拉伸。

点击设备卡片右上角的关闭按钮只会将其移出展示并结束对应会话，不会断开 ADB。需要断开网络设备时，可在左侧设备上点击右键并选择“断开连接”。

## 设备备注与页面跳链

在左侧设备上点击右键，可以修改设备备注名或配置该设备专属的页面跳链。配置完成后，点击右侧预览卡片上的页面加载按钮，会执行等价于以下命令的 ADB 调用：

```bash
adb -s <设备序列号> shell am start \
  -a android.intent.action.VIEW \
  -d "<配置的 URL>"
```

跳链以独立进程参数传递，支持 HTTP(S) 地址、自定义 Scheme 和查询参数；备注名、跳链及展示状态均按设备序列号持久保存。

## 嵌入实现

App 与 scrcpy C 客户端被编译进同一个进程。每个已展示设备都有独立的会话与无边框子渲染面，绑定在 SwiftUI 主窗口的对应卡片上；SDL3 只管理这些渲染面，不会创建独立应用窗口，也不会改变主界面布局。scrcpy 的服务端、视频解码器、音频播放器、输入管理器和控制通道保持不变；共享事件队列由 macOS 主事件循环驱动，AppKit 的鼠标、滚轮、键盘和输入法事件则按设备显式转发到正确会话。
