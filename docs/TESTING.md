# 本地验证

## 自动化测试

仓库根目录 `npm test`；`apps/android` 中执行 `flutter analyze` 与 `flutter test`。Flutter 界面用明确标识的 fixture 数据测试，不注入正式 App。

会话管理回归：Bridge 的 `thread-actions.test.ts` 覆盖归属、项目校验、忙碌/未知状态、审批、并发锁、删除通知及请求去重；Android 的 `thread_actions_test.dart` 和 `thread_actions_widget_test.dart` 覆盖长按菜单、归档/恢复、删除确认、旧 Bridge、上下文切换、迟到响应和失败处理。图片测试另覆盖删除时的相机选择、上传、Android 恢复结果失效及定向缓存清理。深浅色菜单截图生成于 `.local/screenshots/thread-actions-*.png`。

以上自动化使用测试会话和模拟上游，不删除真实主机会话、不运行付费模型任务。真机长按手感、系统返回键、相机方向和进后台恢复需另外验收；更新运行中的 Bridge 必须另获明确重启批准。

截图输出到根目录 `.local/screenshots`。Windows 界面测试按需加载本机字体以便人工检查，CI 不依赖该路径存在。

## Android 模拟器与真实 Codex

端到端测试使用真实 HTTPS、真实 Flutter 网络栈、真实 Codex、真实项目文件和 PTY。会消耗 Codex 使用额度。当前脚本按本机 Windows + Android SDK 路径设置，仅用于验证，不是生产部署脚本。

1. 启动 Android 模拟器，确保 `adb devices` 可见。环境准备脚本 `scripts/android-validate.ps1` 安装 emulator 和 Android 36 Google APIs x86_64 镜像；需要已接受相应 Android 许可证。
2. 先运行 `npm run build`，并完成一次普通 `flutter build apk --debug`，减少首次编译时间。
3. 根目录执行 `node scripts/prepare-integration.mjs`，创建专用主机配置、测试项目和五分钟一次性配对材料。
4. 新终端将 `BRIDGE_DATA_DIR` 设为仓库 `.local/integration-host` 的绝对路径，运行 `npm run bridge -- serve`。
5. `apps/android` 中运行：

```powershell
flutter test integration_test/bridge_flow_test.dart -d emulator-5554 --dart-define-from-file=../../.local/integration.json
```

该测试通过配对界面确认风险，验证凭证持久化，发起真实编码任务，主动断开后恢复，验证图片上传、文件内容、保存冲突和 PTY 输入/输出/重新附着/Ctrl+C/调整尺寸。模拟器通过 `10.0.2.2` 访问主机回环接口，使用证书指纹而非放宽 TLS 校验。

若配对材料过期，重新运行准备脚本后重试。不要把配对文件提交仓库或发给其他人。

**端到端测试后必须重新执行正常 `flutter build apk --debug`，再分发安装包。** 集成测试会生成测试入口的 APK，不应把它当成正式工作台交付。

## Linux

```sh
docker build -f deploy/Dockerfile.test -t codex-bridge-test:local .
docker run --rm codex-bridge-test:local npm test
docker run --rm codex-bridge-test:local npm run smoke
```

容器以 `node` 用户运行，默认不挂载任何主机 Codex 登录文件。无生成的冒烟可检查接口和 PTY；Linux 上真实模型生成需在你授权的独立 Codex 环境中额外运行 `npm run smoke -- --agent`，不要把凭证烘焙进镜像。

## 发布前人工检查

- 真机扫码与相册权限；图片上传；软键盘及中文输入；深浅色和字体放大。
- 手机切换 Wi-Fi/移动网络，以及锁屏数分钟后恢复。
- 在你实际使用的 MCP 上完成需要交互的授权或表单流程。
- 公网反向代理证书更新、设备撤销及丢失手机后的恢复流程。
- 使用自己的发布签名构建、安装和升级，确认不是调试签名。

## 拍照与历史图片回归

- 自动化：`flutter test test/chat_images_test.dart` 覆盖相机/相册来源、权限与取消、上传状态、只发图片、恢复不自动上传、切换上下文、未知结果不重放、历史图片、缩放入口及 320px 深浅色布局；截图输出 `.local/screenshots/chat-images-*.png`。
- Bridge：`npm test` 覆盖项目外合法消息引用、伪造引用、跨项目、符号链接/junction、文件丢失、格式和大小检查，以及认证、设备撤销和二进制响应头。
- 真机：从“＋ → 拍照”拍摄横竖照片，返回确认缩略图，点击放大并缩放，删除/发送；相册选择保持一致。拒绝相机权限后应显示中文提示，不产生附件。
- 系统回收：在相机前台时让系统回收后台应用，完成照片后重开应用；只有原主机/项目/任务显示恢复照片，必须主动上传、发送。切换到别的任务不得收到照片。
- 历史：查看手机发送和电脑端发送的同任务图片，重新打开任务后仍显示；原文件删除应显示不可用；旧 Bridge 提示升级。所有真实任务发送均由用户明确触发，不在默认测试中消耗模型额度。
- 构建普通 `flutter build apk --debug`；不要将集成测试入口 APK 作为正式应用交付。
