# Codex Bridge for Android

个人远程编码工作台，**非官方 Codex 客户端**。Flutter 负责移动界面，TypeScript Bridge 在自己的 Windows/Linux 主机上运行真正的 Codex App Server。

## 已实现

- HTTPS/WSS 连接、多主机、二维码或手动配对、证书固定、设备撤销。
- 项目与任务列表、搜索、分页、新建、恢复、分叉、重命名、归档和还原。
- 流式 Markdown、执行过程、文件改动、模型/推理强度/协作模式选择。
- 运行中追加指令、停止任务、审批/追问/权限请求、Skills 与 MCP 列表。
- PNG/JPEG 图片输入、文件引用、UTF-8 编辑器、冲突保护、Git 状态和 Diff。
- 真正的 PTY 终端：输入、Ctrl+C、尺寸变化、离开页面后重新附着。
- SQLite 请求日志与事件恢复；手机离线不结束主机任务。进程崩溃时不自动重跑操作。
- 深浅色主题、手机单栏、平板双栏、Android 8.0+。

## 环境

| 组件 | 验证基线 |
| --- | --- |
| Flutter / Dart | 3.47.5 / 3.13.4 |
| Node.js | 24 LTS，另兼容本机 Node 25 |
| Codex CLI | **0.155.1，严格校验** |
| Android | minSdk 26，Java 17；其余 SDK 版本由 Flutter 工程管理 |

Bridge 默认使用启动账户的 `CODEX_HOME`，复用该账户的登录和设置；没有登录时先在主机运行 `codex login`。不要为了启动服务而改用管理员或 root。

仓库结构：`apps/bridge` 服务端、`apps/android` 移动端、`packages/protocol` 固定版本契约、`deploy` 部署模板、`scripts` 本地辅助工具。

本次实际验证与安装包校验值见 `docs/VALIDATION.md`。已通过安卓模拟器连接真实 Codex 的完整编码闭环；未覆盖的真机与部署环境场景也在该文档中逐项列出。

## 快速开始：局域网

在仓库根目录运行：

```powershell
npm ci
npm run build
npm run bridge -- init --url https://192.168.1.20:8787 --host 192.168.1.20
npm run bridge -- serve
```

将 IP 替换为开发主机在局域网中的实际地址。仅在你需要的网卡上监听；如 Windows 防火墙阻止连接，由你为该私有网络放行端口。不要随意开放整机防火墙。

保持服务运行，在另一个终端生成一次性配对信息：

```powershell
npm run bridge -- pair
```

安卓 App → 主机 → 配对新主机 → 扫码或粘贴完整 JSON → 确认访问风险。配对码 **5 分钟有效、仅可使用一次**。连接后用顶部文件夹按钮添加主机上的绝对项目目录。

初始化只执行一次。配置保存在当前用户的 `.codex-android-bridge/config.json`，更换地址应编辑该文件并重启服务；不要反复初始化或删除配对数据库。

本地开发可用 `BRIDGE_DATA_DIR` 指定单独数据目录。`scripts/run-bridge.ps1` 可优先使用本次准备在 `.tools` 中的 Node 24；`.tools` 不进入版本控制。

## 公网连接

不提供中继或内网穿透服务。需要自己的可达主机、域名和 HTTPS 证书。

1. Bridge 仅监听 `127.0.0.1:8787`，使用自身证书。
2. 配置 `deploy/nginx.conf.example`，对外终止受信任的 HTTPS，并验证至 Bridge 的第二段 TLS。
3. 只把 Bridge 的 **公开证书** `server.pem` 复制给代理作为信任文件，不复制 `server.key`。
4. 生成公网配对信息：`npm run bridge -- pair --url https://bridge.example.com --public-ca`。

公网 CA 模式使用安卓系统信任链；自签模式用二维码里的 SHA-256 指纹。没有“信任所有证书”开关。详细边界见 `docs/SECURITY.md`。

## 设备与启动管理

```powershell
npm run bridge -- devices
npm run bridge -- revoke DEVICE_ID
```

撤销会阻止后续 HTTP/RPC 请求，现有空闲 WebSocket 最迟在下一个 15 秒检查周期关闭。已获授权并正在执行的主机操作不会因为撤销而被伪装成“从未执行”。

- Windows：手动执行 `scripts/install-startup.ps1` 注册当前用户登录后启动；默认不自动注册计划任务。
- Linux：将 `deploy/codex-bridge.service` 放入用户 systemd 目录，按实际仓库和 Node 路径编辑，然后使用 `systemctl --user` 管理。
- 服务退出或主机重启后，活动任务标记为状态未知，终端标记为丢失。先检查会话历史，再明确恢复或分叉；不保证任意主机崩溃下的无损续跑。

## 构建安卓 APK

```powershell
cd apps/android
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64 --split-per-abi
```

调试安装包：`apps/android/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk`，仅包含 ARM64-v8a。

`v0.1.1` Release 仅提供 ARM64-v8a 调试包（约 97 MiB），校验值和本次验证结果见 `docs/releases/v0.1.1.md`。如需通用包可自行运行 `flutter build apk --debug`。GitHub Release 中的调试包不代表正式签名构建。

发布版本必须自行准备签名密钥，把 `android/key.properties.example` 复制为 `android/key.properties` 并填入本地私密配置。**发布构建不会回退使用调试签名**。密钥、密码和签名配置均被忽略，不应提交。

## 测试

```powershell
npm test
npm run smoke
npm run smoke -- --agent
```

- `npm test`：真实 TLS/WebSocket 边界、配对与撤销、协议验证、请求去重、崩溃状态、事件补发、文件冲突和权限限制。
- `npm run smoke`：启动真实 Codex，检查模型/模式/历史和 PTY，不发起模型生成。
- `npm run smoke -- --agent`：在独立临时项目要求 Codex 写文件、运行验证命令，再读取并归档会话。**会消耗你的 Codex 使用额度**。
- Linux 隔离验证：`docker build -f deploy/Dockerfile.test -t codex-bridge-test:local .`，然后 `docker run --rm codex-bridge-test:local npm test` 和 `docker run --rm codex-bridge-test:local npm run smoke`。

安卓模拟器端到端流程见 `docs/TESTING.md`。界面测试使用明确的测试数据；正式 App 没有演示响应或模拟执行回退。

## 首版边界

- 不接管官方桌面端正在运行的任务。外部历史恢复要求确认其他客户端已停止，也可安全分叉为新会话。
- 不提供后台实时推送、多用户账户/隔离、插件市场、自动化调度或 Git 暂存/提交/分支 GUI。
- 编辑器仅处理 1 MiB 以内的 UTF-8 普通文件；不能作为大型文件或二进制编辑器。
- 图片仅支持 PNG/JPEG，单张最多 20 MiB，存放在项目 `.codex-bridge-uploads` 中；项目可自行将该目录加入 Git 忽略规则。
- MCP 复杂表单提供结构展示和 JSON 输入；未知或主机证明类请求安全拒绝，不擅自代答。
- 源文件保存使用版本校验、同 Bridge 内串行写入及原子替换，但不是能锁住所有外部编辑器的跨进程协作文件系统。
- Codex 版本不匹配时拒绝启动，升级必须重新生成并回归契约。不会修改或自动升级用户原有 Codex 安装。
