# 首版交付与实际验证记录

本记录区分已经执行的验证和仍需真机/部署环境确认的项目，不把模拟器或测试替身结果等同于全部生产场景通过。

## 已执行

| 范围 | 结果与证据 |
| --- | --- |
| Windows Bridge | Node 24.21.0：19/19 测试通过；本机 Node 25.9.0 同样通过 |
| Linux Bridge | Docker Debian、Node 24、非 root 的 node 用户：19/19 测试通过 |
| Linux 真实 App Server | Codex CLI 0.155.1 初始化、模型/协作模式、历史读取及 Bash PTY 输入/输出/尺寸/退出通过；未挂载主机登录凭证 |
| Windows 真实 Codex | 在专用项目写入 bridge-smoke.txt、执行内容验证、读取历史、停止下一轮活动任务并归档通过 |
| Flutter 静态检查 | flutter analyze 无问题 |
| Flutter 单元/界面 | 11/11 通过：事件去重、审批生命周期、离线不重发、主机/项目/任务切换隔离、配对风险确认、手机/平板/主题与终端控件 |
| Android 真实端到端 | API 36 Google APIs x86_64 模拟器，1/1 通过；连接 Windows 上 Node 24 + 真正 Codex App Server |
| 调试 APK | 正常 main.dart 入口通用包与 ARM64/ARMv7/x86_64 分架构包构建成功；通用包已安装并启动确认非测试入口 |
| APK 元数据 | 包名 dev.codexbridge.codex_bridge，版本 0.1.0，minSdk 26，targetSdk 36；apksigner 验证通过，明确为 Android Debug 签名 |
| 开发环境 | Flutter/Dart、Android SDK、Java、模拟器可用；flutter doctor 的 Android toolchain 通过 |

Android 端到端测试实际执行以下动作：

1. 从界面录入短期配对信息、勾选访问风险并完成 HTTPS/WSS 证书固定连接。
2. 验证设备连接资料写入私有存储、设备凭证写入安全存储。
3. 添加真实主机目录，从对话输入框要求 Codex 创建 android-e2e.txt 并运行校验命令。
4. 活动任务期间主动断开传输，重新连接后恢复任务与结果，读取并核对真实文件。
5. 上传 PNG、保存编辑结果、用旧版本标识再次保存并确认 FILE_CONFLICT。
6. 启动真正的 PowerShell PTY，写入命令、读取输出，断开后重新附着同一会话。
7. 运行三十秒等待命令，发送 Ctrl+C，立即执行后续命令并验证输出，再调整尺寸和结束终端。

测试代码未给正式 App 注入任何模拟响应。界面预览截图中的 Studio/测试模型/示例对话仅来自 test/support.dart 的明确 fixture。

## 安装包

本地生成位置：apps/android/build/app/outputs/flutter-apk/。

| 文件 | 字节数 | 用途 |
| --- | ---: | --- |
| app-arm64-v8a-debug.apk | 101789172 | ARM64 安卓手机，约 97 MiB |
| app-armeabi-v7a-debug.apk | 79144966 | ARMv7 设备 |
| app-x86_64-debug.apk | 88812953 | x86_64 模拟器 |
| app-debug.apk | 224620758 | 通用调试包，约 214 MiB |

SHA-256：

```text
B976D34A76AFC0B83F7027B1912FED2C6B300EBDF66BC56A6427D57BC4233615  app-arm64-v8a-debug.apk
3EA683A95F896DD626938F0F92661F803C18BCE4D462E2F1D09E412140BE8E59  app-armeabi-v7a-debug.apk
EE7FDAAF879A94E8EDB47F1528571E86C272AB82AF417E8FD85147BD5E715773  app-x86_64-debug.apk
36C7F3A302DA5743179457BB34D84C05A50A66E0306D13E420838754F7691BC5  app-debug.apk
```

这些是调试包，不是正式发布签名。分架构包的 versionCode 由 Flutter 加入 ABI 偏移；不要混用通用包与分架构包作为正式升级策略。密钥配置模板为 apps/android/android/key.properties.example。

## 仍需部署环境验收

- 真机扫码、相册权限、图片作为模型输入、中文软键盘、大字体，以及 Android 8.0 实机运行。
- 真机 Wi-Fi/移动网络切换、厂商省电策略和长时间锁屏；已经验证的主动断线不能替代这些场景。
- Linux 已验证协议、Bridge 和真实 PTY，但未在已登录的 Linux 主机进行模型生成。
- 审批恢复、限制策略和进程丢失已通过契约/状态测试；未人为修改真实组织管理策略或清除用户登录，也未覆盖所有 MCP 实际授权界面。
- 公网反向代理、证书更新、Windows 登录启动任务和 Linux 用户 systemd 的实际安装运行。
- 正式签名、发布安装与升级。首版不是安全审计或长期稳定性认证。

## 环境与清理边界

- 本次 Node 24 安装位于仓库 .tools，不替换系统 Node，也不升级原有 Codex。
- Flutter 位于 D:/flutter，Android SDK 位于 D:/Android/Sdk；用户 PATH 已包含 Flutter，旧终端需重新打开。当前窗口也可显式使用 D:/flutter/bin/flutter.bat。
- Visual Studio 缺少部分 Windows 桌面 C++ 工作负载；不影响本项目的 Android 构建，未安装无关工作负载。
- 验证专用 Bridge 仅监听回环地址，数据在 .local/integration-host；测试产物、配对材料和日志均被 Git 忽略。部署自己的主机请按 README 初始化，不复用测试配对码。
- 未注册自动启动任务、未修改防火墙、未配置公网访问、未安装为管理员/root 服务。
- 本地日志：.local/windows-node24-tests.log、linux-tests.log、linux-smoke.log、windows-agent-smoke.log、android-integration.log、flutter-analyze.log、flutter-tests.log、apk-build.log、apk-split-build.log。
