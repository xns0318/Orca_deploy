# Orca Windows 单网关多容器自动同步实施任务书（零改 Orca 源码版）

> 本文档替代原“魔改 Windows Orca 源码 + Hub 应用层 RPC 中继”方案。  
> 核心原则：**0 行 `stablyai/orca` 源码改动**，100% 复用官方签名版 Windows Orca、官方 `orca-server`、现有 `orca-gateway` 与 `orca-hub`，全部改动收敛在本仓库（`Orca_deploy`）内。

---

## 1. 目标、运行前提与范围边界

### 1.1 场景与核心需求
- **客户端规模**：约 **3 台远程 Windows x64 电脑**，无法 SSH 访问 Linux 宿主机，但均接入同一个 Tailscale 网络（tailnet）。
- **单入口复用网关**：每台远程 Windows 只需绑定一次现有 `orca-gateway` 入口，后续在宿主机登记新业务容器后，官方 Windows Orca 自动发现并加载该容器，无需再手工导出/传输 `server.pairing.json`。
- **完整桌面能力**：文件读写与监听（`files.write` / `files.watch`）、Git、高性能终端（`terminal.multiplex`）、Agent 会话与容器内账号均由官方 Windows Orca 端到端直连业务容器原生提供，不经应用层 RPC 改写。
- **不破坏现有能力**：现有手机单 Hub 通道（`:6768`）、离线 Hub 镜像导出导入（`hub/export-image.sh` + `--image-archive`）、无 Docker socket 安全模型、用户本地项目和手工直连节点全部保持兼容。

### 1.2 目标拓扑

```text
远程 Windows #1 / #2 / #3（官方签名版 Orca + 轻量 Sync.ps1，无需 SSH，无需 172.17 子网路由）
  │  所有流量仅访问唯一网关 IP: <gateway-tailscale-ip>:6769
  ▼
orca-gateway（复用现有 Tailscale 网关容器，仅增开 1 个私网 Tailscale Serve TCP 端口）
  ├── :6768 ──→ orca-hub（现有手机单 Hub 通道，原封不动）
  └── :6769 ──→ gateway-bridge.cjs（纯 Node，跑在 orca-hub 同容器内，无新依赖、无 Docker socket）
                  ├── HTTP /sync/*        ──→ 独立 Token 鉴权，下发节点清单与待认领凭证（ack 后焚毁）
                  └── WS   /node/<容器名> ──→ 透明 TCP/Upgrade 转发到容器当前内网 IP:6768（E2EE 透传）
                                                ├── 2-machine-dev (172.17.0.x:6768)
                                                ├── csmar-harness (172.17.0.y:6768)
                                                └── 后续新增业务容器 ...
```

### 1.3 首版显式边界
- **做**：单层网关路径反代（`/node/<name>`）、多 Windows 独立凭证签发与按需补签、Windows 定时自动同步与托管节点清理、容器重启换 IP 无感刷新、单台 Windows 独立撤销、离线 Hub 镜像兼容。
- **不做**：不 fork/编译自定义 Orca 客户端或服务端；不向 `orca-hub`/`orca-gateway` 挂载 Docker socket；不启用公网 Tailscale Funnel；不自动接管/删除用户手工添加的非托管远端环境；不要求远程 Windows 开启 `172.17.0.0/16` 子网路由。

---

## 2. 基线与已核对的协议事实

| 项目 | 基线值 |
| :--- | :--- |
| 部署仓库 | `xns0318/Orca_deploy`（基线提交 `23924900ad870d0a9a7930417bf6b8eea8c43f3c`） |
| 锁定 Orca 版本 | `v1.4.259`（见 `versions.lock.env`） |
| 现有网关入口 | `100.69.64.76`（`orca-gateway.tailffcaaf.ts.net`） |
| 现有手机 Hub 端口 | `6768`（保持不变） |
| 新增桌面网关端口 | `6769`（私网 Tailscale Serve TCP，可通过 `--desktop-port` 覆盖） |
| 已知业务节点 | `2-machine-dev`、`csmar-harness` |

已核对的关键协议特性（并在阶段 1 使用真实 `v1.4.259` 二进制二次实测验证）：
1. **路径型 WebSocket 端点原生支持**：Orca 客户端 URL 校验与连接完整保留非根路径，支持 `ws://<gateway>:6769/node/<容器名>`。
2. **多 Windows 独立凭证机制**：业务容器 headless `orca-service cli pair` 签发无 TTL 的 `runtime` 票据；在 Hub 侧通过 Orca 原生 `exchangeCliPairingCode` + `status.get` 激活一次后即释放 pending 槽位，可连续为多台 Windows 签发各自独立的 `deviceId` / `deviceToken`，互不覆盖、可独立撤销。
3. **官方桌面端热刷新**：官方 Windows Orca 监听 `%APPDATA%\orca\orca-environments.json`，外部经官方 `orca.exe environment add` / `rm` 变更后侧边栏自动刷新。

---

## 3. 详细技术设计

### 3.1 网关端口与 Tailscale Serve 配置
- 保持 `orca-gateway` 上 `6768` 端口（`orca-hub`）不变。
- `hub/install.sh` 新增 `--desktop-port`（默认 `6769`，与 `--port` 不可相同），通过 `ORCA_DESKTOP_PORT` 传入 `orca-hub` 容器，并在 `orca-gateway` 配置：
  ```sh
  docker exec "$gateway" tailscale serve --bg --yes --tcp="$desktop_port" "tcp://127.0.0.1:$desktop_port"
  ```
- 复用 `hubctl check-serve "$desktop_port"`，拒绝 Funnel 和端口冲突。
- `hub/entrypoint.sh` 并行拉起 `orca-ide serve`、`monitor.cjs` 和 `gateway-bridge.cjs`（全部复用内置 `ELECTRON_RUN_AS_NODE=1 "$app/orca-ide"`）；`hubctl health` 同步校验 bridge 健康。

### 3.2 透明 WebSocket 路径反代（`hub/gateway-bridge.cjs`）
- 仅接受 `Upgrade: websocket` 且路径严格匹配 `^/node/([a-zA-Z0-9][a-zA-Z0-9._-]{0,62})$` 的请求。
- 实时读取 `orca-environments.json` 将 `<name>` 解析为当前内网 `host:port`（如 `172.17.0.5:6768`），不存在返回 `404`，上游不可达返回 `502`。
- 建立到目标容器的原始 TCP 连接，将 HTTP Upgrade 首行路径重写为 `/`，随后双向原始 TCP 透传（不解密 E2EE、完整支持 `terminal.multiplex` 二进制帧与压缩帧）。
- 按节点名追踪活跃隧道；监控 `orca-environments.json` 变更，节点被移除或内网 IP 变更时主动断开旧隧道。

### 3.3 多 Windows 客户端管理与同步 API（`hub/bridge-store.cjs` + `hub/gateway-bridge.cjs`）
- 状态文件：`$ORCA_USER_DATA_PATH/windows-bridge.json`（权限 `0600`、原子 `.tmp` + `renameSync`、共享 `.hub-registration.lock` 互斥锁）。
- 仅存储 256-bit 同步令牌的 SHA-256 哈希，鉴权使用 `crypto.timingSafeEqual`；错误与日志严禁输出任何凭证。
- HTTP API（`:6769`，均要求 `Authorization: Bearer <token>`）：
  - `GET /sync/state`：更新客户端 `lastSeenAt`，返回当前有效节点清单与该客户端的 grant 状态（`pending` / `claimed` / `unprovisioned`）。
  - `POST /sync/claim`（`{ "node": "<name>" }`）：幂等返回待认领 `{ name, nodeId, endpoint, pairingUrl }`。
  - `POST /sync/ack`（`{ "node": "<name>", "nodeId": "<id>" }`）：标记为 `claimed` 并**清除服务端明文 `pairingUrl`**，仅保留 `deviceId` 供审计与撤销参考。
  - `GET /healthz`（仅回环地址允许）：健康检查。

### 3.4 宿主机 CLI 与脚本工作流
- `hubctl` 新增子命令：`client add <name>`、`client list [--active-names]`、`client revoke <name>`、`offer-put <client> <node>`；增强 `remove`（联动清理该节点全部 grants）与 `health`。
- 宿主机节点元数据（不含凭证）：保存在 `$XDG_DATA_HOME/orca-gateway/<gateway>/nodes.json`（`0600`），记录 `{ name -> { container, user, prefix, port, hub } }`。
- `hub/connect.sh`：完成现有手机 Hub 登记后写入节点元数据，并为所有活跃 Windows 客户端自动签发网关路径凭证（通过 `docker exec` stdin 管道，不落宿主机盘、不挂 Docker socket）；仅容器 IP 变更时不重复覆盖已 `claimed` 的客户端。
- `hub/sync-windows.sh`：新增第 2、3 台 Windows 客户端后，一次性为所有已登记的运行中容器补签独立凭证（支持 `--client`、`--node`、`--dry-run`）。

### 3.5 远程 Windows 同步脚本（`windows/Sync.ps1`）
- 仅调用官方 `orca.exe` CLI（`environment list/add/rm`、`status`），不手写 Orca 配置文件。
- 本地配置与托管状态存在 `%LOCALAPPDATA%\orca-deploy\`，Bearer Token 通过当前用户 Windows DPAPI 加密存储。
- 请求网关 `/sync/*` 默认绕过系统 HTTP 代理（兼容 Clash Verge 开启状态，同时保留 `-UseSystemProxy` 开关）。
- 冲突保护：只删除/替换 `sync-state.json` 托管集内的节点；遇同名非托管手工环境时告警跳过（提供 `-AdoptExisting` 显式接管参数）。
- 支持 `-InstallTask`（静默当前用户计划任务，默认 60 秒周期，加文件互斥锁防重入）与 `-UninstallTask`。

### 3.6 镜像指纹与离线打包兼容
- 将 `hub/gateway-bridge.cjs`、`hub/bridge-store.cjs` 加入 `hub/.dockerignore` 白名单和 `hub/image.sh` 指纹哈希计算列表，保证 `hub/export-image.sh` 与 `hub/install.sh --image-archive --recreate` 完整兼容。

---

## 4. 改动文件清单

- 新增：`hub/bridge-store.cjs`、`hub/gateway-bridge.cjs`、`hub/sync-windows.sh`、`windows/Sync.ps1`、`tests/bridge.cjs`、`docs/windows-gateway-sync.md`
- 修改：`hub/orca-api.cjs`、`hub/hubctl`、`hub/hubctl.cjs`、`hub/entrypoint.sh`、`hub/install.sh`、`hub/connect.sh`、`hub/.dockerignore`、`hub/image.sh`、`windows/OrcaDeploy.psm1`、`hub/README.md`、`README.md`、`tests/hub.sh`、`tests/hub-config.cjs`、`tests/hub-container.sh`、`tests/hub-live.cjs`、`tests/windows.ps1`、`tests/fixtures/hub-docker.cjs`

---

## 5. 分阶段实施计划与检查点

1. **阶段 1：真实 `v1.4.259` 协议验证** —— 实测路径型 WS 反代 + 3 客户端独立凭证并发连接业务容器（文件读写、Git、终端）。
2. **阶段 2：Hub 与宿主机实现** —— 完成网关桥、状态存储、`hubctl`、安装/连接/补签脚本及镜像指纹更新。
3. **阶段 3：Windows 同步脚本实现** —— 完成 `windows/Sync.ps1`、`OrcaDeploy.psm1` 及 PowerShell 单测。
4. **阶段 4：全量测试与验收记录** —— 跑通全部单测与真实 `v1.4.259` 端到端协议测试，更新文档并输出 G01–G14 验收记录。

---

## 6. 验收清单（G01–G14）

| 编号 | 验收项 | 通过标准 |
| :--- | :--- | :--- |
| G01 | 单入口初始化 | 远程 Windows 无需 SSH，单次初始化后自动拉取全部已登记容器 |
| G02 | 路径反代单 IP 闭环 | 无需 `172.17.0.0/16` 子网路由，经 `ws://<gateway>:6769/node/<名>` 稳定连接 |
| G03 | 多 Windows 独立凭证 | 3 台 Windows 同时连接同一容器并发操作，互不踢出，凭证独立 |
| G04 | 全量原生桌面操作 | 经路径反代验证文件读写、Git、终端并发收发与 Agent 会话 |
| G05 | 新增容器自动发现 | 宿主机 `hub/connect.sh` 新增容器后，所有 Windows 自动同步出现 |
| G06 | 新增第 2/3 台 Windows | 新增客户端后执行 `hub/sync-windows.sh`，自动同步全部历史容器 |
| G07 | 容器换 IP 无感恢复 | 容器换内网 IP 后重跑 `hub/connect.sh`，Windows 无需重新配对即恢复 |
| G08 | 容器移除自动清理 | `hubctl remove` 立刻切断活跃隧道，Windows 下次同步自动清理托管项 |
| G09 | 非托管环境保护 | 已有手工同名环境或本地项目时告警跳过，绝不误删或静默覆盖 |
| G10 | 领完即焚与单机撤销 | `ack` 后服务端不留明文 `pairingUrl`；`client revoke` 立返 `401` 且不影响他机与手机 |
| G11 | 代理环境兼容 | Windows 开启 Clash Verge 系统代理时同步与连接正常 |
| G12 | 手机通道零回归 | 原有 `:6768` 手机配对、发现与终端链路全通过 |
| G13 | 安全最小权限基线 | 无 Docker socket、非 root `10001`、只读根 FS、无 Funnel、零凭证泄露 |
| G14 | 离线镜像升级与回退 | 离线镜像导出校验通过、`--recreate` 保留卷与手机配对、回退步骤可验证 |
