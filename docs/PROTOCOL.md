# Bridge Protocol v1

传输为 HTTPS + WSS。协议版本不是 Codex CLI 版本；当前 Codex 适配器严格绑定 `0.155.1`，生成的 JSON Schema 和 TypeScript 文件保存在 `packages/protocol`。

## HTTP

| 方法与路径 | 用途 |
| --- | --- |
| `POST /v1/pair` | `{code, deviceName, acceptFullAccess:true}` → `{deviceId, token, info}` |
| `GET /v1/info` | 主机身份、能力和执行端状态 |
| `GET /v1/health` | 认证后的健康检查 |
| `POST /v1/devices/revoke` | `{deviceId}`，撤销该设备 |
| `POST /v1/uploads` | `{requestId, projectId, dataBase64}`，上传 PNG/JPEG，持久化去重 |
| `GET /v1/thread-images` | 查询参数 `projectId, threadId, itemId, contentIndex`，读取历史用户消息引用的图片，返回二进制 |
| `GET /v1/ws` | 使用 `Authorization: Bearer ...` 升级 WebSocket |

除配对接口外均需要认证。错误形状为 `{error:{code,message,details?}}`。

### 图片预览

`imageRead` 能力标记表示支持历史图片读取。`contentIndex` 是用户消息 `content` 中从零开始的位置。服务端从 `thread/read` 验证任务 ID、项目 cwd 和消息引用，仅允许 `localImage`；不接受客户端路径，也不为读取操作恢复、接管或执行任务。PNG、JPEG、WebP、GIF 通过文件签名识别，普通文件上限 20 MiB。返回图片 MIME、`Cache-Control: private, no-store` 和 `X-Content-Type-Options: nosniff`。设备在读取完成后再次验证，撤销后不得返回图片。

任务历史明确引用的项目外原图也可读取，但拒绝符号链接/junction 路径和读取期间检测到的目标替换。原文件丢失返回 `IMAGE_UNAVAILABLE`，非图片为 `INVALID_IMAGE`，超限为 `IMAGE_TOO_LARGE`，引用不匹配为 `IMAGE_NOT_FOUND`，项目不匹配为 `PROJECT_MISMATCH`。不提供任意文件下载或外部 URL 代理。

Android 对 `image.url` 的内嵌图片本地解码，外部地址仅允许 HTTPS、独立可信 TLS 客户端、无 Bridge 凭证且不跟随重定向。下载缓存只在内存中，最多 40 MiB / 48 条，按主机/项目/任务/消息隔离；切换或移除主机时清空。旧 Bridge 提示升级。上传仍使用原有接口，手机新上传照片发送时仅提交 `localImage` 路径；已有历史消息中的内嵌图片数据仍遵循原消息缓存机制。

拍照/相册恢复记录只包含原主机、项目、任务、草稿标识和临时文件路径；恢复后须主动点击上传，再点击发送。结果未知的上传保留照片并提示检查主机，不提供自动重放。

## 握手与恢复

客户端先发送：

```json
{"type":"hello","protocolVersion":1,"epoch":null,"afterSeq":0}
```

服务端发送 `hello`，含版本、能力、`ready`、`epoch`、`cursor`、`reset` 和 `runtime`。`runtime` 包含任务状态、终端状态与待审批请求。随后补发事件，最后发送：

```json
{"type":"synced","epoch":"execution-instance","cursor":123}
```

`reset:true` 表示必须刷新会话快照，不能继续拼接旧增量。客户端在 `synced` 后发送普通请求。慢客户端会被断开，可重新连接补发。

## 请求、响应、事件

```json
{"type":"request","requestId":"unique-id","method":"thread/list","params":{"projectId":"project-id","limit":50}}
```

```json
{"type":"response","requestId":"unique-id","result":{"data":[]}}
```

```json
{"type":"event","epoch":"execution-instance","seq":124,"method":"item/agentMessage/delta","params":{"threadId":"task-id","itemId":"item-id","delta":"text"}}
```

结果可能改为 `error`。不得把 `OUTCOME_UNKNOWN`、`UPSTREAM_LOST` 或超时当成“操作未执行”。同一 `requestId` 重用不同方法或内容返回 `REQUEST_CONFLICT`。

## 暴露的方法

- Bridge：`bridge/info`、`bridge/runtime`。
- 项目：`projects/list`、`projects/add`（绝对 `path`、可选 `name`）、`projects/remove`。
- 任务：`thread/list`、`thread/read`、`thread/start`、`thread/resume`、`thread/fork`、`thread/name/set`、`thread/archive`、`thread/unarchive`、`thread/delete`。
- 执行：`turn/start`、`turn/steer`、`turn/interrupt`。
- 能力：`model/list`、`collaborationMode/list`、`skills/list`、`mcpServerStatus/list`、`configRequirements/read`、`account/read`。
- 文件：`files/list`、`files/read`、`files/save`，参数为 `projectId` 与相对 `path`；保存还需要 `content`、`version`、可选 `bom`。
- Git：`git/status`，返回非 Git 标记或状态、已暂存和未暂存 Diff。
- 终端：`terminal/list`、`terminal/open`、`terminal/read`、`terminal/write`、`terminal/resize`、`terminal/close`。
- 审批：`approval/respond`，参数为 Bridge 审批 `id` 与符合对应上游 Schema 的 `result`。

任务创建/恢复/分叉要求 `projectId`，可指定 `permissionMode`：`danger-full-access`、`workspace-write`、`read-only`。Bridge 负责映射上游权限字段；不能直接注入 `config`、`developerInstructions` 等配置。外部恢复额外要求 `confirmExternalStopped:true`，活动会话仍会被拒绝。

终端写入使用 `deltaBase64`；调整尺寸使用 `cols` / `rows`。`terminal/read` 返回有界输出与 `cursor`，客户端只追加其后的输出事件。Bridge 在输出事件中附加跨 UTF-8 分片正确解码的 `textDelta`。

## 会话归档与永久删除

- Android 任务侧栏支持长按归档、恢复和删除；删除需二次确认。只允许操作 Bridge 已管理且处于空闲状态的会话，不会为了删除自动恢复、接管或停止外部会话。
- `thread/delete` 要求 `{projectId, threadId}`。Bridge 校验项目归属后调用固定版本 Codex 的原生删除接口，只转发 `{threadId}`；不接受客户端文件路径，也不直接删除历史文件或项目文件。归档/恢复同样检查归属；旧的无 `projectId` 归档请求保持兼容。
- `bridge/info` 和握手能力列表新增 `threadDelete`。旧 Bridge 的 Android 客户端仍可归档，但删除入口提示升级，不发送删除请求。
- 正在执行、启动中、同会话操作进行中返回 `THREAD_BUSY`；状态未知返回 `OUTCOME_UNKNOWN`；待审批请求未处理返回 `THREAD_PENDING_APPROVAL`；外部和跨项目分别返回 `EXTERNAL_THREAD`、`PROJECT_MISMATCH`。管理操作与启动/恢复共享会话锁。
- 删除成功会清理 Bridge 会话运行记录并发布 `thread/deleted`；上游先发同一通知时不额外发布。手机幂等清除对应历史、图片缓存及草稿恢复数据，保存按主机隔离的删除标记，阻止旧响应恢复内容。
- 归档保留历史；永久删除调用 Codex 原生语义，不等于擦除备份、Bridge 事件日志或请求去重记录。超时、断线或未知结果不自动重试；成功后的列表刷新失败单独提示，不报告为删除失败。

## 审批与兼容性

服务端请求转为 `bridge/approval`，包含 Bridge ID、上游 ID、方法及参数。响应仅可提交一次；收到上游解决通知、任务结束或进程丢失后失效。

支持命令/文件审批、澄清问题、MCP elicitation 和权限申请。无法安全处理的上游请求返回明确错误；没有“自动全部接受”兜底。

当前版本创建会话显式使用 `historyMode:legacy`，避免实验分页历史接口尚未实现的错误。尚无第一条用户消息的本进程会话允许读取元数据；只有精确匹配上游“未物化”错误时使用此回退，不吞掉其他历史错误。

协议生成脚本同样严格校验 0.155.1。升级时先在独立开发环境审查目标协议、共同调整生成脚本和适配器版本，再生成并回归 Windows/Linux 契约、真实冒烟与安卓端到端测试。不要仅修改版本字符串绕过检查。
