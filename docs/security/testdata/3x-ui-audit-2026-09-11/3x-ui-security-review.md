# 3x-ui v3.7.0 源码安全与隐私初筛

审查日期：2026-09-11。仓库：MHSanaei/3x-ui。版本：v3.7.0。固定提交：`f727d04f6522bb94a8fb52e8352fdcafb51c11e1`。

本次针对登录/API/订阅/WebSocket、外发请求、连接记录、凭据、安装更新与 Docker 默认值进行静态追踪，并核对官方安全公告。不是完整渗透测试，也没有检查用户正在运行的服务器。

**判断：在已检查的路径中，未发现把客户数据秘密上传给作者或不明收件方的证据。但发现了可实际影响部署的安全问题，以及需要运营者明确选择的隐私行为。不能因此保证整个项目、第三方依赖或发布二进制没有后门。**

**优先处理的安全问题**

| 编号 | 判断 | 必要条件 | 影响 |
|---|---|---|---|
| S1 | 高：默认管理员凭据 | 官方 Docker 空库首次启动、端口可达、尚未改密 | 获得面板管理权限 |
| S2 | 中：官方已公开的节点同步越权 | 接入的子节点恶意或被攻陷 | 跨节点覆盖客户凭据、污染订阅配置 |
| S3 | 中：HWID 限制覆盖不完整 | 知道有效订阅 URL，启用 HWID 限制 | 设备满额后仍能取得配置 |
| S4 | 中：TLS 加载失败继续提供 HTTP | 配置的证书/私钥加载失败并启动服务 | 出现意外的明文入口 |
| S5 | 中：WebSocket 会话撤销不完整 | 事先获得有效管理会话并维持连接 | 改密等操作后仍接收实时数据 |
| S6 | 中，条件性：外部订阅抓取无私网隔离 | 管理员配置外部来源，来源可控制响应/DNS | 让面板请求本机/内网 HTTP 服务 |
| S7 | 供应链风险 | 管理员发起更新，或构建时上游内容发生不可信变化 | 审过的稳定版与实际执行脚本/制品脱节 |

严重性为本次初筛判断，不是新增 CVSS/CVE；S2 的官方评级为 Moderate。

**S1：默认 Docker 初始账户为 admin/admin**

数据库空用户表会用固定的 `admin/admin` 创建管理员。Docker 入口直接初始化并启动应用，没有生成随机账户或强制完成改密后才能访问 API。Compose 发布 `2053:2053`，默认监听地址为空、路径为根路径、未设置 TLS、2FA 关闭；若外部网络可达，任何知道默认凭据的人都能登录。

证据：[internal/database/db.go:60](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/database/db.go#L60)、[internal/database/db.go:1150](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/database/db.go#L1150)、[DockerEntrypoint.sh:81](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/DockerEntrypoint.sh#L81)、[docker-compose.yml:48](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/docker-compose.yml#L48)、[internal/web/service/setting.go:44](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/setting.go#L44)、[internal/web/controller/api.go:63](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/controller/api.go#L63)。

边界：已有数据库沿用原有凭据；原生安装脚本会生成随机用户名、密码与路径，不能把这个问题概括为所有安装方式都有默认弱口令。见 [install.sh:1065](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/install.sh#L1065)。这里是静态确认的启动链，未实际启动 Docker。

处理：首次启动就要求提供安全凭据或生成一次性随机凭据；完成初始化前仅绑定本地/受控管理网络。现有部署应在开放公网入口之前修改凭据，启用 2FA，并限制管理端访问范围。

**S2：已公开的节点同步越权影响本次版本**

官方于 2026-09-08 发布 GHSA-rr44-v4rv-x654，标记受影响版本为 `<=3.7.0`，在本次查询时修复版本为 None。前提是已接入的子节点恶意或失陷，不是匿名互联网访问即可利用。[官方公告](https://github.com/MHSanaei/3x-ui/security/advisories/GHSA-rr44-v4rv-x654)。

本次独立源码核对发现：子节点上报的配置被写入主库；客户合并按全局 email 查找，没有以报告节点约束对象范围；非空 UUID/Password 会覆盖原记录。因此子节点可影响主节点或其它节点的客户凭据。节点提供的端点也可能进入相关用户的订阅，诱导客户端连接非预期代理。

证据：[internal/web/service/inbound_node.go:669](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/inbound_node.go#L669)、[internal/web/service/client_link.go:120](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/client_link.go#L120)、[internal/web/service/client_link.go:23](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/client_link.go#L23)、[internal/web/service/xray.go:183](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/xray.go#L183)。

边界：本次未对真实节点实施攻击；主节点生成 Xray 配置会跳过远端入站，不能把该链夸大为已证实的主机 RCE。见 [internal/web/service/xray.go:174](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/xray.go#L174)。

处理：修复前避免使用该版本聚合不完全可信的子节点；需要在同步入库时落实节点归属校验、字段权限和跨节点客户隔离。TLS/mTLS 或让失陷节点签名，均不能单独解决“合法节点越权修改其它节点数据”的问题。

另一个历史公告 GHSA-jm48-m3rr-9hgg / CVE-2026-55477 影响 <=3.3.0，官方给出修复版本 3.3.1；不把它算作 v3.7.0 的未修复发现。[官方历史公告](https://github.com/MHSanaei/3x-ui/security/advisories/GHSA-jm48-m3rr-9hgg)。

**S3：HWID 不能成为“最多 10 台设备”的安全边界**

JSON/Clash 的 raw 下载分支先返回完整配置，再到达普通分支的 `enforceHwid`；HTML 订阅页也在 HWID 检查之前返回，并嵌入连接链接。持有有效订阅 URL 的访问者，即使没提交 HWID、设备已满，仍有其它方式得到代理凭据。

证据：[internal/sub/controller.go:387](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/sub/controller.go#L387)、[internal/sub/controller.go:559](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/sub/controller.go#L559)、[internal/sub/controller.go:709](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/sub/controller.go#L709)、[internal/sub/controller.go:761](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/sub/controller.go#L761)。

边界：JSON/Clash 需启用相应格式；HTML 豁免是明确的现有设计，有测试确保信息页不受 HWID 限制。见 [internal/sub/hwid_controller_test.go:124](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/sub/hwid_controller_test.go#L124)。它不是未知订阅 ID 的枚举证明，也不是后台管理员认证绕过。

处理：若希望限制配置分发，要统一所有返回凭据的入口。即使补齐该检查，也只能限制订阅获取；已经拿到 UUID 的客户端仍可直接连 Xray。此前需求中的“同时在线 10 台”仍需可靠的设备身份及连接准入/撤销机制，不能依赖订阅页检查代替。

**S4：配置 TLS 后加载失败，会继续提供 HTTP**

设置了证书或私钥，但 `tls.LoadX509KeyPair` 失败时，应用只写错误日志并沿用普通 TCP listener。面板和订阅服务均如此。证书路径错误、文件权限问题或证书/私钥不匹配后重启，可使原本预期的 HTTPS 服务出现 HTTP 入口。

证据：[internal/web/web.go:577](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/web.go#L577)、[internal/web/web.go:612](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/web.go#L612)、[internal/sub/sub.go:351](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/sub/sub.go#L351)。面板对 Secure Cookie/HSTS 的选择也与是否成功加载直接 TLS 有关：[internal/web/web.go:143](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/web.go#L143)。

边界：HTTPS 客户端连接会失败，不是浏览器必然自动降级；只有访问 HTTP 才发生明文传输。主动配置“无 TLS 后端 + HTTPS 反代”是另一种合理部署方式，不算此缺陷。

处理：当已显式设置 TLS 时，加载失败应停止启动并报警。反代场景隔离后端，并正确设置 HTTPS、HSTS 与 Secure Cookie。

**S5：改密/会话到期后，既有 WebSocket 不立即失效**

WebSocket 只在握手时检查登录。连接管理只绑定随机 client ID；Ping/Pong 可持续续期，没有再次核对用户 LoginEpoch 或会话到期。HTTP API 虽然每次检查 epoch，已经建立的 WebSocket 并不因此关闭。

证据：[internal/web/controller/websocket.go:65](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/controller/websocket.go#L65)、[internal/web/service/panel/websocket.go:40](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/panel/websocket.go#L40)、[internal/web/service/panel/websocket.go:67](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/panel/websocket.go#L67)、[internal/web/service/panel/websocket.go:94](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/panel/websocket.go#L94)。其广播可包含客户在线状态、最后在线时间和流量：[internal/web/job/xray_traffic_job.go:198](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/job/xray_traffic_job.go#L198)。

边界：攻击者需要事先持有有效会话并建立连接；WebSocket 当前丢弃用户输入帧，这不是任意后台写入。断线、连接清理或服务重启会终止订阅。启用 2FA 若附带其它重启操作，也会因重启断开；这里指缺少基于认证撤销的连接失效机制。

处理：把用户、会话到期和 epoch 绑定到连接；撤销认证时主动断开，并在广播/心跳周期复核。泄漏处置不能只改密，还需关闭既有连接。

**S6：客户外部订阅抓取未使用已有 SSRF 防护**

`normalizeExternalLinks` 对“subscription”仅验证 URL 为 HTTP(S) 且有 host；实际客户端只有超时，没有私网 IP 校验或 redirect 约束。读取有效用户订阅时会展开管理员配置的外部订阅。

证据：[internal/web/service/client_external_link.go:49](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/client_external_link.go#L49)、[internal/web/service/client_external_link.go:81](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/client_external_link.go#L81)、[internal/sub/external_subscription.go:29](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/sub/external_subscription.go#L29)、[internal/sub/external_subscription.go:146](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/sub/external_subscription.go#L146)、[internal/sub/external_config.go:84](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/sub/external_config.go#L84)。

对照：另一处 outbound subscription 已使用 `netsafe.SSRFGuardedDialContext` 并验证重定向，支持显式 AllowPrivate；远程路由也有防护。见 [internal/web/service/outbound_subscription.go:308](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/outbound_subscription.go#L308)、[internal/sub/remote_routing.go:462](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/sub/remote_routing.go#L462)。因此不是全项目的抓取都不设防，而是这条路径遗漏。

影响条件：管理员接入了不可信或后来失陷的订阅来源；该服务的重定向或 DNS 响应可能让抓取触达服务器可访问的内网地址。直接设置 URL 需要管理权限，不是匿名访客能随意指定抓取地址的接口。响应只保留类似分享链接的行，且有 2 MiB/6 秒限制，未证明任意内网数据都能被回显或窃取。

局部验证：从当前固定版本抽取原有抓取、解码、URL 校验函数及防护 dialer，使用标准库与两台仅监听 loopback 的测试 HTTP 服务检查直接访问及重定向。验证结论见同目录 `verification.txt`；未启动完整面板，也未访问真实内网/云元数据目标。

处理：复用公共地址校验和拨号时 IP 防护，覆盖每次重定向；内网来源需要明确的管理员 opt-in，并结合出口网络规则。

**S7：更新链对可变脚本的信任超过固定版本**

网页更新入口从 `main/update.sh` 下载并执行脚本，稳定通道也一样；该脚本的下载只检查状态、大小与非空，没有与已审核 tag/commit 绑定。部分发布包/构建工具下载也没有统一验证流程。

证据：[internal/web/service/panel/panel.go:43](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/panel/panel.go#L43)、[internal/web/service/panel/panel.go:236](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/panel/panel.go#L236)、[internal/web/service/panel/panel.go:374](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/panel/panel.go#L374)、[update.sh:984](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/update.sh#L984)、[DockerInit.sh:28](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/DockerInit.sh#L28)。

边界：管理员主动更新或构建时才触发；HTTPS 和 API 权限控制存在，未发现“互联网匿名用户直接执行命令”的链，也没有证据称官方仓库已经遭篡改。网页 Xray 核心更新另有版本白名单、摘要校验、大小限制与固定文件提取，不能写成“所有更新都无校验”。见 [internal/web/service/server.go:944](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/server.go#L944)、[internal/web/service/server.go:1009](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/server.go#L1009)。

处理：部署固定已审核的镜像 digest/制品，脚本与依赖绑定具体版本；使用受信签名或预先审核的摘要验证，更新纳入变更流程。

**隐私行为：默认、可选及本地记录要分开看**

| 行为 | 默认/触发 | 数据与接收者 | 判断 |
|---|---|---|---|
| 公网 IP 查询 | 后台状态首次解析，结果缓存；依次尝试成功即停止 | ipify 等查询服务看到出口 IP、时间及请求元数据；未附加客户列表/UUID | 常规外发，不是零外联 |
| Telegram 机器人与完整备份 | Bot 与自动备份默认关闭；启用后可定时或主动发送 | 配置的 Telegram/自定义 Bot API 与聊天收到完整数据库、config.json，可能还有登录通知与日志 | 高影响的可选导出 |
| 客户 IP/last-seen | 支持 online-stats 的 Xray 运行，默认启用相关采集；约 10 秒扫描 | 本地数据库中的客户标识、IP、最近出现时间、节点归属 | 即使 access log 关闭也存在 |
| 外部流量通知 | 默认关闭，URL 空 | 自定义接收方收到客户标识、上下行及入站流量 | 必须按实际接收者评估 |
| SMTP/LDAP/节点集成 | 需要管理员配置；SMTP/LDAP 默认关闭 | 指定认证/通知/节点端接收相应数据 | 可选业务功能 |
| WARP/Nord/PIA | 主动使用相关集成 | 各服务接收注册、公钥或用户提供的服务凭据 | 不是固定作者收件地址 |
| 版本、规则及核心下载 | 查询或更新功能触发 | GitHub 等看到请求路径及出口 IP | 常规供应链外联 |

公网 IP 查询证据：[internal/web/service/server.go:363](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/server.go#L363)、[internal/web/service/server.go:399](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/server.go#L399)。它采用普通 HTTP client，未使用项目的面板出站代理；项目的面板代理在 Xray/桥接不可用时还会回退直连。因此“设置了面板代理”不是禁止直连的保证。见 [internal/web/service/setting.go:473](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/setting.go#L473)、[internal/web/service/setting.go:520](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/setting.go#L520)。

Telegram 默认值与备份证据：[internal/web/service/setting.go:74](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/setting.go#L74)、[internal/web/service/tgbot/tgbot_report.go:419](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/tgbot/tgbot_report.go#L419)。这里的上传没有应用层备份密码加密/脱敏，**不等于 HTTPS 传输是明文**。数据库含可恢复的代理凭据、订阅标识和集成 secret；管理员密码本身是 bcrypt 哈希，不是明文。

IP 记录证据：[internal/web/web.go:296](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/web.go#L296)、[internal/web/job/check_client_ip_job.go:57](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/job/check_client_ip_job.go#L57)、[internal/web/job/check_client_ip_job.go:100](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/job/check_client_ip_job.go#L100)、[internal/web/job/check_client_ip_job.go:507](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/job/check_client_ip_job.go#L507)。正常带时间戳的 IP 数据约保留 30 分钟、每 5 分钟清理；旧版无时间戳行会跳过该清理。该结论只针对这类 IP 行，不代表所有日志、备份和在线统计都只有同样保留期，也不等于记录了网页正文或完整浏览历史。参见 [internal/web/service/inbound_client_ips.go:240](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/inbound_client_ips.go#L240)。

**另外需要落地验证的存储风险**

SQLite 初始化以 0755 建目录后直接打开数据库，没有强制主库文件为 0600：[internal/database/db.go:2080](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/database/db.go#L2080)。若最终文件权限允许同机其它账户读取，UUID/订阅链接/集成密钥可能暴露。**本次未在 Linux 实测文件最终模式，不能把 0644 当成已经观测到的结果。** 应检查实际目录、主库、WAL/SHM 和备份权限；PostgreSQL 后端不适用同一文件权限结论。

**已有防护，避免把正常功能全部视为漏洞**

- 管理员密码使用 bcrypt；新 API token 只存哈希，支持 scope/到期。[internal/database/db.go:1157](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/database/db.go#L1157)、[internal/web/service/panel/api_token.go:81](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/panel/api_token.go#L81)。
- 登录有限速，CSRF 覆盖登录/退出及会话写请求；HTTP 会话逐请求校验用户与 epoch。[internal/web/controller/login_limiter.go:9](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/controller/login_limiter.go#L9)、[internal/web/session/csrf.go:19](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/session/csrf.go#L19)、[internal/web/session/session.go:27](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/session/session.go#L27)。
- API 使用 monitor/node-sync 白名单，未知 scope 默认拒绝；这不代替节点对象级权限校验。[internal/web/controller/api.go:118](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/controller/api.go#L118)。
- 自带面板前端检查中未发现第三方分析 SDK 或自动加载的外部脚本/字体；响应设置 CSP 与 no-referrer。[internal/web/middleware/security.go:14](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/middleware/security.go#L14)。
- Xray 运行配置有 0600 和原子写入保护；设置视图会隐藏若干 secret，但整库备份不受视图脱敏保护。[internal/xray/process.go:599](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/xray/process.go#L599)、[internal/web/service/setting.go:267](https://github.com/MHSanaei/3x-ui/blob/f727d04f6522bb94a8fb52e8352fdcafb51c11e1/internal/web/service/setting.go#L267)。

**对当前账户管理项目的建议**

3x-ui 可继续作为候选，但不要原样把默认 Docker 管理端发布到公网。先解决初始化凭据与管理端隔离；明确 TLS 失败行为、备份收件方和数据保留；多节点方案先处理 S2；设备管理仍需独立设计与连接层验证。面板管理 API 应仅由可信后台调用，不向普通客户直接开放管理员能力。

本次未修改上游源码、未运行安装器或完整面板、未扫描公网实例、未向维护者发信/提交问题。未完成依赖递归漏洞审计、发布制品与源码一致性验证、实际 Docker/Linux 权限和运行流量抓包。本报告是可继续验证的初筛结果，不是“安全认证”。
