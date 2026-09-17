# Xray 账户管理项目交接

交接日期：2026-09-11。来源：Codex 任务 `xray`，ID `01a07ae9-e79d-7b01-9fcd-31594bea3acf`。

本文件是原讨论的聚焦摘要，用来补充分叉历史，并在后续上下文压缩后保留项目约束。

2026-09-14 状态更新：S0 基线验证已执行完毕（[记录](superpowers/validation/2026-09-11-xray-account-baseline.md)），S1 实验 1 与 2a 已执行（[记录](superpowers/validation/2026-09-14-xray-account-s1-experiments.md)）。实验结果**否定了第一版一项隐含前提**——现有 API 无法中断已建立的连接，详见下文「已验证的执行能力事实」。仍未实现账户管理功能，未应用任何安全补丁。

2026-09-15 状态更新：机器 A（`vm44212`）已重装为 Ubuntu 24.04、裸 Xray 已从备份恢复并经真实用户验证、3x-ui v3.7.0 已安装并加固。详见下文「机器 A 迁移进度」。

2026-09-16 状态更新：机器 A 的入站已导入面板并用约 4 MB 真实流量验证通过（临时端口 44300）。**切换到 443 仍然延后。** 用户仍由裸 Xray 26.2.6 在 443 服务，状态安全可逆。机器 B 因服务商面板故障暂时无法重装，已定位原因。

2026-09-16 **切换已完成**：机器 A 的 443 已由面板管理的 Xray 26.7.28 接管，裸 Xray 26.2.6 已 `systemctl disable --now`。实测证据：`ss -ltunp` 显示同一进程（pid 26861）同时监听 `*:443`、`127.0.0.1:62789`（api 入站）与 `127.0.0.1:11111`（metrics），裸 Xray 进程已消失。用户确认迁移成功。**机器 A 自此完全由面板管理**，后续一切入站/客户端变更都必须经面板而非 `/usr/local/etc/xray/config.json`。详见「机器 A 迁移进度」第 8 条，其中列出了尚未记录的复核项。

2026-09-17 状态更新：机器 A 新增第二个客户端 `zlz2026`，经 `rt.AddUser` 热更生效、核心未重启、现有用户未受影响。过程中对着源码核实出四条此前未知的约束（`compactOrphans` 静默剔除、30 秒自动重启窗口、`realitySettings.settings` sidecar 缺失导致链接/订阅不可用、`BulkCreate` 大小写使共享额度分裂），见下文「客户端管理的已验证事实（2026-09-17）」。当日另有一次升级评估实验，见「升级到 v3.8.x 的实测代价（2026-09-17）」——结论是 26.9.9 会切断 Shadowrocket，机器 A 暂不升级、暂不移植补丁。四条约束里第三条**曾卡住第一版目标第 1 条**，**当日已修复**——sidecar 已补齐、链接带上 `pbk`/`fp`、核心零影响，`make-inbound-payload.py` 亦已补上生成逻辑，机器 B 不会重蹈。

2026-09-16 当日三次更新（切换已解除阻塞，历史）：收窄后的必测清单 **v2rayN / Shadowrocket 2.2.92 / v2rayNG 全部通过 44300**，且是在核心版本经实测确认为 26.7.28、默认门槛活跃的前提下通过的。**机器 A 切换到 443 不再被客户端兼容性阻塞，且不需要任何配置改动。** 剩余风险与切换步骤见「客户端兼容性硬约束 → 验收结果」与「机器 A 迁移进度」。

2026-09-16 当日二次修订（重要）：升级到最新版的 Shadowrocket 2.2.92 现在能连上 44300，但追查后**本文件初版对该约束的归因是错的，结论方向也反了**，已重写「客户端兼容性硬约束」整节。三点必须先知道：(1) `minClientVer` 默认门槛由 `af7eb680`（2026-07-11）引入、存续窗口仅 **v26.7.11 … v26.7.28**，并已被上游在 **v26.9.8** 注释掉——不是本文件原先写的「在 v26.3.27 进入」；(2) 机器 A 的 443 跑的裸 26.2.6 **根本没有这道闸**，所以切到面板 26.7.28 是**给生产端口新增限制**，兼容性净减少，不是「解除阻塞」；(3) 升级到 26.9.x 更糟——换成不可配置的 X25519MLKEM768 闸，且本仓库 Clash 订阅不输出 `support-x25519mlkem768`。**mihomo 硬编码自报 1.8.2 且维护者拒绝修改，因此「要求客户端升级」对 Clash 这一路不存在可行版本。**

## 已确认的第一版目标

用户已有运行中的 Xray VLESS + REALITY 代理，希望增加：

1. 普通用户账户与登录界面，用户只能访问自己的配置和用量。
2. 每个账户上传、下载及合计流量的统计。
3. 按账户统一控制月流量额度。
4. 管理员可在账户列表多选一批账号，实时批量修改流量额度，无需逐个编辑或等到下个周期。

2026-09-11 用户确认部署规模：第一版两台代理服务器，预计 20 个账号、全系统 20 人同时使用。按双节点做第一版设计与验收；这些数字是容量目标，不是只能创建 20 个账号、每节点各 20 人、20 个连接或设备数量限制。

两台代理上的账户用量汇总到同一共享月额度。停用、恢复和批量调整需要覆盖该账户关联的全部节点并显示执行结果，不能每台服务器分别给一份完整额度；双节点验收不推迟到第二版。

2026-09-11 补充需求：上述多选、批量及实时调整能力已由用户明确提出，并随设计批准采用“统一设置月额度、保留当月已用流量、提交后立即重新判断账户可用状态”的规则。设置用于当期及后续周期，直到再次修改；不自动加入按差额增减或仅本月临时赠送流量。详见 [批量额度设计](superpowers/specs/2026-09-11-xray-account-phase1-design.md#管理员多选批量调整额度)。不能把批量写库成功等同于全部节点执行成功。

2026-09-11 最新范围决定：用户明确表示“第一版不考虑控制同时在线设备数”。第一版不实现设备身份识别、在线名额、第 11 台连接拒绝及用于释放名额的自助移除设备功能；这些不再是第一版开发或验收的阻塞项，也不改用 IP 数、连接数或订阅 HWID 限制来替代。

第一版仍需兼容 v2rayN、v2rayNG、Shadowrocket、Clash；没有授权改用自研配套客户端。

**2026-09-17 用户告知的实际客户端群体（决策级事实）：PC 端只有 v2rayN，移动端只有 Shadowrocket，没有 mihomo / Clash 用户，也不计划有。** 这条收窄了三件事：(1) 补 Clash 订阅的 `support-x25519mlkem768` 对本部署价值为零，已从待办移除；(2) 本文件中「mihomo 硬编码 1.8.2 无可行版本」那一整段分析作为上游事实仍然成立，但**对本部署不再构成约束**；(3) 升级到 ≥26.9.8 的代价从「切断 iOS 用户」升级为**切断在用客户端的一半**（Shadowrocket），使「不升级」的结论更硬。上面那行兼容清单是 2026-09-11 批准设计时的目标范围，仍是设计约束，但**验收必测矩阵按实际群体收窄为 v2rayN + Shadowrocket**；v2rayNG 保留为备用项，因为将来可能出现 Android 用户。用户于 2026-09-11 通过“确认设计文档”批准 [第一阶段设计](superpowers/specs/2026-09-11-xray-account-phase1-design.md)，采用管理员开户、UTC 自然月、整数 byte 存储/GiB 展示，以及统一设置当期和后续周期月额度且保留已用量的默认方案。无需重复请求设计批准；文中保留的连接执行、失联策略和凭据重置细节继续通过验证与细化解决。

2026-09-11 用户明确要求将以下四项写入设计，现作为已确认规则：

- **额度恢复**：新周期或提高额度后，有可用额度的账户自动解除因额度耗尽导致的停用；管理员手动停用的账户保持停用。提高后仍无剩余额度的账户不恢复，实际恢复结果以节点执行为准。
- **流量口径**：按上传加下载统计，账户所有关联配置使用同一倍率累计到共享额度，页面明确标注流量及额度单位。
- **用户界面**：第一版包含登录、用量与剩余额度、连接配置、修改密码，普通用户仅可访问自己的数据。
- **密码与代理凭据分开**：修改网页登录密码不自动更换 UUID；配置泄露后的代理凭据重置是独立操作，不能与改密码联动或混淆。

历史设备需求仅供以后恢复讨论时参考：最多 10 台同时在线，不是累计注册上限；移除一台不应影响其他设备的配置。是否恢复此功能，以及被移除设备重新认证、重新占位的规则，后续另行确定，第一版不预建设备会话系统。

没有要求支付、收款或自动售卖系统。磁力搜索项目的每月 10 美元预算、访问量和目标地区不属于本项目。

## 最新仓库与架构决定

第一版使用一个 3x-ui Fork、一个工作目录，复用它现有的 Go 后端及 React 管理界面，按模块增加账户、流量和共享额度能力。之前讨论过拆成 `3x-ui` 与 `proxy-platform` 两个仓库；用户质疑必要性后，建议已收敛为先单仓库实现，不强制拆服务。

- 工作目录：`D:\workspaces\3x-ui`，是 Noctiluca 的同级独立仓库，不是子模块。
- 开发分支：`codex/xray-account`。
- 代码基线：`v3.7.0`，SHA `f727d04f6522bb94a8fb52e8352fdcafb51c11e1`。
- 从此前只读审查的本地上游副本进行独立克隆（无硬链接），上游 remote 已指向 `https://github.com/MHSanaei/3x-ui.git`。
- 用户已创建 GitHub Fork：`zhss5/3x-ui`；`origin` 已配置为 `git@github.com:zhss5/3x-ui.git`，官方仓库保留为 `upstream`。
- 2026-09-11 已将现有基线分支 `codex/xray-account` 推送到 `origin` 并建立同名分支跟踪；后续设计及证据文件的提交、发布状态以 `git status`、本地提交和远程分支为准，基线发布不代表账户功能已经发布。
- 不自动追踪移动的 main/dev-latest；先评估基线安全问题，再移植必要修复。未部署到生产。

职责建议：账户模块负责普通用户身份、资源归属、账户计量、共享额度和用户门户；现有 3x-ui 负责代理配置、节点管理、原始流量及订阅；Xray/节点侧负责账户停用及额度耗尽后的实际连接控制。单体内优先通过模块接口整合，后续确有需要再拆成服务。

## 必须保持清楚的能力边界

3x-ui 已有管理员账户、登录、2FA、代理客户端管理、流量、额度、到期时间、订阅页面和 HWID 管理。它并非“没有界面或账户功能”。但管理员 `User` 和代理 `ClientRecord` 是两种不同身份；代理 UUID 不会自动成为具备对象隔离的普通用户网页登录账户。

需要增加普通用户认证、账户与代理客户端的映射、服务端资源归属校验，以及展示本人配置、用量和额度的用户界面。不能仅通过隐藏管理菜单来隔离普通用户权限。

第一版仍需验证账户计量及额度执行：

- 一账户下多个代理凭据的用量应汇总到同一个月额度，不能变成每个凭据各享一份完整额度。要处理节点重启、统计清零、重复读取、重复上报和月周期结算。
- 同一账户在两台代理服务器上同时产生用量时，节点来源分别计量后汇总，不能按 UUID 把两个节点的真实用量误去重，也不能重复计入同一节点的一次上报。节点失联、恢复和部分执行失败需要双节点验证。
- 定时轮询会有额度超用窗口；若要求严格硬上限，需要节点本地执行预算等额外设计。
- ~~额度耗尽需要在实际连接路径生效；不能因为面板调用 `RemoveUser` 或修改 `Enable` 就声称现有连接已停止。~~ **2026-09-14 已实测验证，见下节。结论是现有 API 确实不能停止既有连接**，此项从「待验证」转为「已确认的能力缺口」。

以下设备可行性结论保留为历史参考，不是第一版待办：

- VLESS UUID 是访问凭据，不是不可复制的物理设备身份。IP 不能当设备；一个设备也会建立许多连接。
- 3x-ui 的订阅 HWID 限制不等于代理连接时的在线设备限制。缓存的配置可以绕过只发生在订阅请求或门户页面的检查。
- 每设备独立 UUID 有助于统计和选择性撤销，但 UUID 可复制，仍不足以保证严格的物理设备上限。
- 严格控制需要可靠的设备证明/客户端配合，以及实际连接路径上的准入校验。用户已选择兼容上述通用第三方客户端；在此约束下，严格物理设备识别与准入尚无已验证的实现方案。
- 多节点环境需要按不同设备原子占用在线名额，并定义断线、重连、休眠、超时回收等规则。不能用网页心跳单独证明代理在线状态。
- 不能因为面板中调用 `RemoveUser` 或存在注释，就声称已有连接立即断开。要验证目标 Xray 版本的实际行为；踢下线必须验证定向终止及旧会话重连行为。**2026-09-14 已在 `Xray 26.7.28` 上验证：`RemoveUser` 确实不断开既有连接，见「已验证的执行能力事实」。**

目前不能宣称已经找到完全满足“原样使用任意通用客户端且严格限制 10 台物理设备”的现成方案。第一版按用户最新决定排除该功能，不因这项历史需求未实现而阻止第一版验收。

## 已验证的执行能力事实（2026-09-14）

以下四条来自真实核心实测与源码确认，不是推断。证据与边界见 [S1 实验记录](superpowers/validation/2026-09-14-xray-account-s1-experiments.md)。

1. **`RemoveUser` 不中断既有连接。** 固定版本 `Xray 26.7.28` 上，对账户 A 调用 `RemoveUser` 后 20 秒内，A 的既有连接读取 11,468,800 字节（558.3 KiB/s），与未被操作的账户 B 完全相同，逐秒计数在移除那一刻无任何变化。移除本身生效确凿（`inbounduser` 移除后只剩 B，新握手被拒）。VLESS 只在握手时认证一次，`AlterInbound` 在结构上够不到连接。
2. **被停用账户继续记账、继续显示在线。** 核心中无任何代码调用 `UnregisterCounter`，计数器在 dispatch 时已焊入 link。
3. **单面板部署无重启兜底。** `restartXrayOnClientDisable` 默认为 `"true"`，但停用客户端走 `RestartXray(false)`，热更成功即提前返回，永不重启进程。`RemoveUser` 就是全部执行手段。多节点 master 另有 `RestartXray(true)` 强制重启路径，未验证，且代价是整机所有账号掉线。
4. **流量提交失败会静默丢增量。** 每客户端 `UPDATE client_traffics` 失败只记日志、函数仍返回 nil，而内存基线已在提交前推进，下一轮算出的增量为 0。一次瞬时数据库错误即可让一段流量永久消失且无任何错误信号。

**合起来构成一个对共享月额度不利的闭环**：额度耗尽 → 停用 → 连接不断 → 继续跑流量 → 继续记账 → 超用持续扩大，而面板显示一切正常。

因此「额度耗尽即断流」在现有能力上做不到。方向选定前不应开始 S3（共享额度）实现。三个候选方向均未验证：

1. 接受可测量的超用窗口——只挡新连接，配合轮询与明示的延迟上界；
2. 在连接层扩展准入校验，使既有连接可被定向终止；
3. 整核心重启——**本文件已明确禁止**，代价是同机所有账号掉线。

顺带确认了一处既有缺陷：`internal/web/job/check_client_ip_job.go:666` 的 IP 超限功能注释写着「Remove user to disconnect all connections」，按上述结论它一条连接都断不了，该功能大概率失效。这正是本文件反复强调的「不能把注释当运行证据」。

## 安全审查已经完成到什么程度

此前审查对象是上述固定 v3.7.0 提交，原审查目录：`C:\Users\zhang\AppData\Local\Temp\codex-3x-ui-audit-20260911`。未运行安装脚本、面板服务或真实代理，也没有逐行审完全部 1701 个跟踪文件。

完整报告和原始验证文件已保留到 [审查证据目录](security/testdata/3x-ui-audit-2026-09-11/3x-ui-security-review.md)。其中 `.go` 探针放在 `testdata` 下，避免被项目 `go test ./...` 当作新增业务测试包。文件原文中的 Temp 路径是原审查来源，不代表新开发目录。

结论是已检查路径中没有发现隐蔽向作者泄露用户数据的证据，不是“绝对没有后门”或发布二进制已验证的保证。已发现问题包括：

- Docker 空数据库初始化使用默认 admin/admin，需区分安装脚本随机密码的另一条路径。
- 已登记的节点可跨入站污染客户端凭据/订阅（GHSA-rr44-v4rv-x654）；不是匿名远程 RCE。
- HWID 检查存在 raw JSON/Clash 及 HTML 路径缺口，且即使修复也不等于在线设备控制。
- 证书加载失败后回退到 HTTP；WebSocket 主要在握手时认证，未及时撤销既有连接。
- 管理员配置的外部订阅抓取缺少现有 SSRF 私网/重定向防护；存在前提，不是匿名任意 URL 入口。
- v3.7.0 数据库权限强化不足；部分安装/更新路径依赖移动分支，存在供应链边界问题。
- Telegram 数据库/配置备份属于可选且默认关闭的显式功能，但需要考虑代理凭据及额外备份加密。
- IP/客户端在线元数据和对外 IP 查询有正常功能路径；未证明隐蔽外传浏览内容。

本地实际验证仅为标准库隔离探针：直接访问 loopback 和经重定向访问 loopback 两个可达性复现通过，现有安全 guard 对相同地址的拒绝测试通过。前两个“PASS”表示问题复现成功，不是安全修复通过。未完成全项目编译/测试、Docker/Linux 权限验收、运行中的 Xray 集成验证或发行物供应链证明。

## 上游修复候选（尚未应用）

截至本次审查曾检查 main 提交 `8f162994efcf033b95efb46f188fe2403d3449f5`。后续开发前需要重新核实，不能把此快照当作一直最新。

| 候选提交 | 已检查的作用与边界 |
| --- | --- |
| `f17e4684e0029307c2447c6dd32a153aa53341cd` | 修复 raw JSON/Clash 的 HWID 检查；不覆盖 HTML 缺口，也不是在线设备认证 |
| `a31fa9abfa4d316ff77608da0326c4ade08acd84` | 限制节点认领只归属其他节点的客户端；仅确认部分边界改善，不应声称完整消除共享客户端/订阅污染 |
| `23511108bfe6919439cb2dea6d5b26fb8ac2737c` | 数据目录 0700、SQLite/WAL/SHM 文件 0600 强化，带测试 |
| `f294e1806d083d8d394558452e2402878a9c94d2` | 安装更新校验 SHA256 sidecar；旧发行版 404 时仍可警告后跳过，不是绝对完整校验链 |
| `195988bdc138` | 已看到将安装脚本/服务文件固定至发行 tag 的提交主题，未完成 diff 审查 |

这些提交都未在新目录 cherry-pick、构建或验收。官方安全公告是否有 patched release，与 main 是否存在部分代码修复是两回事。

## 源码导航

- `CLAUDE.md`、`CONTRIBUTING.md`、`docs/architecture.md`：工程和运行时分层约束，开发前按范围阅读。
- `internal/database/model/model.go`：管理员 `User` 与代理 `ClientRecord` 模型。
- `internal/web/service/panel/user.go`、`internal/web/session/session.go`：管理员认证、密码/2FA、会话 epoch。
- `internal/web/controller/client.go`、`api.go`：代理客户端接口与管理 API 权限。
- `internal/web/service/client_hwid.go`、`internal/sub/controller.go`：订阅 HWID 和各输出路径。
- `internal/web/job/check_client_ip_job.go`：IP 统计及临时断开相关实现，不能将注释当运行证据。
- `internal/web/job/xray_traffic_job.go`：流量采集。
- `internal/web/runtime/`：入站/客户端变更应经过此运行时分发，不能绕开多节点路径直接调 Xray。
- `frontend/src/routes.tsx`、`frontend/src/pages/clients/`、`frontend/src/pages/sub/SubPage.tsx`：已有管理及订阅页面。

## 部署目标的实际状态（2026-09-16 更新）

两台代理服务器**已存在并在服务真实用户**。**机器 A 自 2026-09-16 起已由 3x-ui 面板管理的 Xray 26.7.28 在 443 服务**，裸 Xray 已停用并 disable（见「机器 A 迁移进度」第 8 条）；下表「入站」一栏描述的是迁移前从裸 Xray 读到的基准配置，该配置已原样导入面板。机器 B 仍是官方 `Xray-install` 装的裸 Xray。

| | 机器 A `vm44212` / 38.59.228.104 | 机器 B `vm25394` |
| --- | --- | --- |
| 系统 | ~~CentOS 7~~ → **Ubuntu 24.04.5 LTS**（2026-09-15 重装，内核 6.17，13.49 GB 磁盘） | Debian 9 stretch（LTS 2022-06-30 EOL），**未动** |
| 架构 | x86_64 | x86_64 |
| systemd `User=` | 恢复自备份，仍是 **root**，降权三行被注释（待加固） | `nobody` + `AmbientCapabilities`，已加固 |
| 布局 | `/usr/local/bin/xray`、`/usr/local/etc/xray/config.json`、`/etc/systemd/system/xray.service` | 同左 |
| 入站 | VLESS / 443 / REALITY / **flow=`xtls-rprx-vision`** / dest=`www.apple.com:443` / serverNames=`["www.apple.com"]` / shortIds=`["38796120a33722e7"]` / **1 个客户端，无 `email` 字段** | 未逐项确认 |

机器 B 仍是 EOL 系统、包管理器源已移到 archive、面向公网。

**Xray 版本（2026-09-16 确认）**：机器 A 的裸 Xray 是 **26.2.6**（`12ee51e` / go1.25.7），面板管理的那个是 **26.7.28**（`5ca6f4b` / go1.26.5）。这个版本差决定了两个端口筛不筛客户端，见「客户端兼容性硬约束」。机器 B 的版本未确认。**这两个版本号来自 2026-09-15 的记录，不是运行中二进制的输出——任何依赖它们的判断都必须先复核。**

**本仓库钉的 Xray 版本不等于机器 A 上那个。** 二进制版本钉在三处并同步：`DockerInit.sh:35`、`.github/workflows/release.yml:127` 与 `:290`。`v3.7.0`（机器 A 安装的版本，2026-08-24）钉 **v26.7.28**；当前 `main` 自 `d0edbcec`（2026-09-09）起钉 **v26.9.9**。Go 模块 `github.com/xtls/xray-core` 只提供 config 结构体与 gRPC stats/handler/router API，不是运行时核心：v3.7.0 为 `...-5ca6f4b7d4dc`（即 26.7.28），main 为 `...-52a412d9e2f5`；间接依赖 `github.com/xtls/reality` 在 v3.7.0 是 `20260322125925`、main 是 `20260908062103`。**所以升级面板会把核心从 26.7.28 推到 26.9.9，跨过上游撤回 `minClientVer` 默认值并换上 MLKEM768 闸的那道分界线。** 面板另有独立于面板版本的 Xray 二进制切换器（`POST /server/installXray/:version`，下限 v26.6.27），但其选择不持久，下次 `x-ui update` 会被覆盖。

**分支陷阱（已经害人一次）**：本文件所在的 `codex/xray-account` 分支是从 `v3.7.0` 分出的，所以它的工作树里 `DockerInit.sh:35` 仍是 v26.7.28、`go.mod` 的 `reality` 仍是 `20260322125925`——**与 `main` 不同**。在本分支上 grep 出来的版本号不代表 `main` 会发布什么，反之亦然。判断「门槛在不在」时必须先说清问的是哪个分支、哪个发布、还是机器 A 上那个运行中的二进制，这三者当前互不相同。

**机器 B 目前无法重装系统**：服务商（hmbcloud）的 WHMCS 面板 VPS 管理区空白。已定位到具体原因——`clientarea.php?action=productdetails&id=5973&api=json&act=vpsmanage` 返回 HTTP 200 但 `"info": 0`（应为 VPS 详情对象），耗时 0.889s；同账号另一台 VPS（id 7094 / vpsid 662 / 节点 DC0605）同一接口返回完整 `info` 对象，耗时 0.542s。两者 `uid` 均为 0、`user_type` 均为 null，故**认证层无差异，认证问题已排除**。字段集合差异（异常那台多出 `pubkey`/`enable_kyc`/`vpc_attachments`/`custom_cp` 等）显示两台由不同版本的 Virtualizor 主控服务。VPS 385 本身运行正常（可 SSH、业务正常），故问题在承载它的 DC5 主控侧。前端崩溃点已定位：`map_address` 位于 `info.flags` 下，`info=0` 时 `info.flags` 为 undefined，`vpsmanage_onload` 抛 TypeError 中断整个面板渲染。已备工单文本，服务商 WAF 会拦含 HTML 标签与完整 URL 的正文，需用纯文本版本提交。

**机器 B 不重装也能装 3x-ui**：release 是 Bootlin musl 全静态链接（`release.yml` 的 `-linkmode external -extldflags '-static'`），不依赖 glibc 版本；捆绑的 xray 也是静态 Go 二进制。唯一障碍是 `install_base` 的 `apt-get update`——Debian 9 源已归档，需先把 `sources.list` 指向 `archive.debian.org` 并加 `-o Acquire::Check-Valid-Until=false`。所以重装是"应该做"而非"必须先做"。

**机器 A 的 REALITY `privateKey` 基准哈希：`2a876c1641027973`**（sha256 前 16 位）。迁移到面板后必须复核这个值不变——这是"客户端配置无需更改"的唯一判据。

**备份已于 2026-09-14 完成并取回本地**，含二进制、配置、systemd unit，哈希已核对。备份中真正不可再生的只有 REALITY 的 `privateKey`——其余字段（客户端 UUID、shortId、serverNames、端口、publicKey）在每个客户端配置里都有副本，唯独私钥只存在于服务器上。丢失即须重发全部客户端配置。

计划拓扑：机器 A 或 B 之一作 master 兼代理，另一台作子节点兼代理。面板暂在本机 Windows，后续迁到服务器。

## 迁移到 3x-ui 的已知约束（2026-09-14 调查）

这些是并行审查得出的结论，重新发现代价很高，故记录于此。

**可以分阶段切换，不必大爆炸。** 全仓库检索确认 `install.sh` 从不读写 `/usr/local/bin/xray`、`/usr/local/etc/xray/`、`xray.service`，也从不停用它们（唯一的 `pkill` 匹配 mtg 侧车）。3x-ui 装在 `/usr/local/x-ui/`，其 Xray 在 `/usr/local/x-ui/bin/`。**唯一硬冲突是端口。** 面板每秒检查 Xray、连续两次失败才重启，因此 `systemctl disable --now xray` 后端口在约 2–3 秒内被接管。

**必须走 API，不能用面板 UI 建这个入站。** `frontend/src/pages/inbounds/form/useSecurityActions.ts` 的 `onSecurityChange` 在 security 下拉框选中 reality 时会删除整个 `realitySettings`、随机化 `shortIds`、清空 `target`/`serverNames`，并**异步**拉取新密钥对覆写 `privateKey` 与 `publicKey`。该请求无防护，粘贴的真实私钥会在响应落地时被静默替换。走 `POST /panel/api/inbounds/add` 则 `streamSettings` 作为不透明字符串原样入库，前端不参与。禁忌动作只有两个：动 security 下拉框、点「获取新证书」。

**导入时每个客户端必须补 `"enable": true` 和非空 `email`。** `model.Client.Enable` 无 gorm 默认值，原生 Xray 配置没有 `enable` 字段，零值 false 会被字面写入 `client_traffics`，生成配置时 `if exists && !enable { continue }` 把每个用户都跳过——结果是 Xray 正常启动、端口与 REALITY 参数都对、**clients 数组为空**，面板显示一切正常，只有一行 info 日志。缺 `email` 的客户端在 `client_link.go` 里 `if email == "" { continue }` 被更早跳过。

**其余已识别的坑**：`install.sh` 的下载 URL 四处硬编码上游 `MHSanaei/3x-ui`，直接运行装的是上游而非本 fork（**尚未决定装哪个**）；重装后防火墙全新，Rocky 9 的 firewalld 默认 enforcing 会让「恢复成功」的服务仍被黑洞，须从机器外验证；`x-ui.sh` 的防火墙菜单硬编码 2053/2096 而非实际随机端口，且 `ufw allow ssh` 只开 22；fail2ban 为 opt-out，其 SSH 端口探测只读 `/etc/ssh/sshd_config` 不读 `sshd_config.d/`；切换收尾必须 `disable --now` 而非 `stop`，否则两个 unit 都 enabled，下次重启抢端口；删除节点的直觉顺序（先删 inbound）会把子节点上的用户一起删掉，正确顺序是先 `SetEnable(false)`；节点 tag 冲突时 adoption 只告警不报错，reconcile 扫描会在数秒后删掉子节点的入站，可用 `InboundSyncMode: selected` 规避。

## 机器 A 迁移进度（2026-09-15 起，2026-09-16 更新）

用户已重装系统并按下列顺序推进。**尚未导入入站，用户仍全程由裸 Xray 在 443 上服务，pid 1337 自始至终未变。**

已完成：

1. **系统重装** CentOS 7 → Ubuntu 24.04.5 LTS。
2. **裸 Xray 从备份恢复**，`systemctl is-enabled` 为 `enabled`，**真实用户已验证可连可用**——这同时证明备份里的 REALITY 私钥完整无损，整条「备份 → 重装 → 恢复」退路走通。
3. **3x-ui v3.7.0 安装完成**。装的是上游 `MHSanaei/3x-ui` 的 release，因为本 fork 相对 v3.7.0 **没有任何代码改动**（除 docs 与 `AGENTS.md`），二者在代码上等价。版本用 `bash install.sh v3.7.0` 显式钉死——不能用 latest，否则 S0/S1 的全部证据链失效。
4. 面板绑 `127.0.0.1:24476`，SQLite，fail2ban 跳过，`/etc/x-ui` 改 700、db 改 600。
5. **订阅服务器已关闭**（`subEnable=false`），`*:2096` 不再监听。
6. **公网唯一暴露端口现在只有 443**（裸 Xray），其余全在回环。

7. **入站已导入并验证（2026-09-16）**。走 `POST /panel/api/inbounds/add` 建在临时端口 **44300**，tag `in-vm44212-443`。**没有使用面板 UI**——UI 的 security 下拉框会异步重生成 REALITY 密钥对。用 v2rayN + Xray 26.3.27 实测通过，服务端计数器 `user>>>user1>>>traffic` 记到 **up=618,265 / down=3,607,453**（约 4 MB 真实代理流量）。

   这一组数字一次性证明了整条链路：REALITY 握手成功（`privateKey`/`shortIds`/`serverNames` 全对）、VLESS 认证成功（UUID 对）、`flow=xtls-rprx-vision` 被接受、**`enable:true` 生效**（否则客户端会被静默丢弃、计数器恒为 0）。计数器只统计通过 VLESS 认证并被实际代理的流量——被 REALITY 判为探测而转发给 `dest` 的连接不计入，所以它比"能上网"可靠。

8. **切换到 443 已完成（2026-09-16）。** 执行顺序即此前记录的那一条：`systemctl disable --now xray` → `POST /panel/api/inbounds/update/<id>` 把端口从 44300 改 443。

   **已取得的实测证据**：`ss -ltunp | grep xray` 显示 `xray-linux-amd64`（pid 26861）同时监听 `*:443`、`127.0.0.1:62789`（api 入站）、`127.0.0.1:11111`（metrics）——同一个 pid，说明 443 确由面板管理的核心接管；裸 Xray 进程已不在列表中。用户确认迁移成功。

   **切换后复核（2026-09-17 回填）**：
   - `systemctl is-enabled xray` → **`disabled`**。裸 Xray 不会在下次重启时抢回 443，两个 unit 抢端口这条风险已关闭。
   - 切换后 privateKey 的 sha256 前 16 位 **仍为 `2a876c1641027973`**，与迁移前基准一致。这是「客户端配置无需更改」的唯一判据，至此得到确认——存量客户端不需要换任何配置。

   **仍未记录**：切换后的计数器读数与实际停机时长（当时没记，事后已无法补测）。

   **回滚路径仍然有效**（反序）：先 `POST /panel/api/inbounds/update/<id>` 把面板入站挪回 44300 让出端口，再 `systemctl enable --now xray`。若切换前按流程存了 `/root/inbound-44300.json`，直接用它做 payload。

   **已知代价已经生效**：443 此前是裸 26.2.6、无 `minClientVer` 闸，现在是 26.7.28、门槛活跃。Clash / mihomo 用户从这一刻起连不上，且除显式降门槛外无服务端补救。这是 2026-09-16 收窄验收范围时接受的代价，不是故障。

**磁盘上的 `/usr/local/x-ui/bin/config.json` 会滞后，这是正常的。** 面板走热更新路径（`tryHotApply`），通过 Xray gRPC API 直接改运行中的核心，而 `Process.SetConfig`（`internal/xray/process.go:313-317`）只更新内存、不写磁盘；磁盘配置只在真正重启时（`process.go:599`）重写。反过来说：**滞后的 mtime 本身就是热更新成功的证据**——若热更新失败会回落到 `process.Stop()` + 重启，那时磁盘配置会被刷新。权威状态是「数据库 + 实际监听端口 + 计数器」，不是那个文件。

转换脚本见 [`superpowers/tools/make-inbound-payload.py`](superpowers/tools/make-inbound-payload.py)：在节点上读 `config.json`、生成 `/panel/api/inbounds/add` 所需的 payload（`settings`/`streamSettings`/`sniffing` 需为转义字符串），自动补 `enable:true` 与缺失的 `email`，拒绝使用当前生效端口，并打印脱敏预览（私钥与 UUID 只显示长度和 sha256 前 16 位）。机器 B 迁移时复用同一脚本。

### 过程中踩到并确认的操作性事实

- **`/usr/bin/x-ui` 是 shell 包装脚本，不接受 `setting` 子命令**（它自己的子命令表里是 `settings` 复数）。CLI 必须用二进制全路径 `/usr/local/x-ui/x-ui setting ...`。包装脚本内部也一律这么调。
- **交互式安装的端口输入不支持方向键**，转义序列会被原样吃进参数。而 `install.sh:1217` 是把 username/password/port/webBasePath **四项放在一条命令**里设的，Go 的 flag 是 `ExitOnError`——端口解析失败会让整条退出，**四项一个都不生效**，面板于是停留在编译内置默认值 `admin`/`admin`、端口 2053、webBasePath `/`。安装摘要打印的却是它**打算**设置的值，具有误导性。绑回环之所以仍然生效，是因为 `install.sh:993` 是一次独立调用。
- **非交互模式强制不绑回环**（`install.sh:986-987` `bind_local="n"`，注释称云镜像需保持公网可达），必须装完手工补 `-listenIP 127.0.0.1`。
- **`x-ui uninstall` 会 `rm /etc/x-ui/ -rf`**（连数据库和全部 API token 一起删），且 `x-ui.sh` 全文对裸 Xray 的三个路径零引用——所以卸载重装不会碰 443 上那个。确认提示里的 "xray will also uninstalled" 指的是面板自带的那份。
- **`POST /panel/api/setting/update` 是全量覆盖**：它绑定整个 `AllSetting` 并调 `UpdateAllSetting`。只发单个键会把其余字段写成 Go 零值。正确用法是 `POST /setting/all` 导出 → 改一处 → 整份发回，服务端的 `preserveRedactedSecrets` 支持这种往返。
- **删除 API token 需要 `expectedScope` 参数**（`admin` / `monitor` / `node-sync`，见 `api_token.go:55-66`），空值会被 `requireExpectedScope` 拒绝。安装创建的 token 名为 `install`、scope 为 `admin`。
- **`-getApiToken` 重复调用不会吊销安装时那个 token**：已有 token 时它只重建一个名为 CLI fallback 的**另一个** token（`main.go:511-525`）。要作废 `install` 那个必须显式删除，或卸载重装。**2026-09-17 补充：但它不会无限累积。** `ApiTokenService.RecreateByName`（`internal/web/service/panel/api_token.go:122`）的注释写明 "replaces any token with this name, keeping exactly one so a repeatedly-run caller cannot accumulate credentials it can never revoke"，即同名只留一个。当日实测机器 A 上**只有一个 admin scope 的 token**，无需清理。
- **token 列表接口不返回哈希，所以无法靠比对哈希识别「我正在用哪个」。** `ApiTokenView` 的 `toView`（`api_token.go:42-51`）刻意不赋 `Token` 字段，而标签是 `json:"token,omitempty"`，故该键整个不出现（明文更是只在创建时返回一次，见 `:116-117` 的 `view.Token = plaintext`）。要在多个 token 中安全地只留一个，正确做法是先 `POST /panel/api/setting/apiTokens/create` 建一个自己确知的（响应里带一次明文）、切换过去、再删其余 id。删除必须带 `expectedScope`（`requireExpectedScope` 拒空值）。
- **面板密码受 bcrypt 72 字节硬限制**（`golang.org/x/crypto@v0.55.0/bcrypt.go:96` 返回 `ErrPasswordTooLong`，不是截断）。用户名/密码除非空外无任何校验。
- **面板默认关闭 Xray 的访问日志**：模板（`internal/web/service/config.json`）里是 `"log": {"access": "none", "error": "", "loglevel": "warning"}`，而 `policy` 里 `statsUserUplink`/`statsUserDownlink` 为 true。所以**诊断"某个客户端到底连上了没有"要靠 per-user 计数器，不能靠访问日志**——日志里一条连接记录都不会有。查法：`/usr/local/x-ui/bin/xray-linux-amd64 api statsquery --server=127.0.0.1:62789 -pattern "<email>"`。计数器只统计通过 VLESS 认证并被代理的流量，被 REALITY 判为探测而转发给 `dest` 的连接不计入，因此它比访问日志更能区分"连上了"和"认证并代理成功了"。面板自身日志在 `/var/log/x-ui/3xui.log`（含以 `XRAY:` 前缀转发的核心 warning 及以上级别输出）。
- **面板模板里只有一个入站**：`dokodemo-door` 的 api 入站在 `127.0.0.1:62789`，另有 Prometheus 指标在 `127.0.0.1:11111`（无鉴权，但仅回环）。两者都不与业务端口冲突，所以装 3x-ui 不会碰 443。
- **客户端 `email` 必须标识人而不是机器**。共享额度按 email 跨节点聚合（S0 的 `TestTwoNodesShareEmail_SumsCorrectly` 即此语义）。若按节点命名，同一个人在两台机器上会变成两个独立账户、各享一份额度——正是本文件禁止的。机器 A 现有客户端没有 email 字段，导入时必须补，取值需在此刻定好。

## 客户端兼容性硬约束：REALITY 客户端闸门（2026-09-16，当日二次修订）

第一版必须兼容 v2rayN、v2rayNG、Shadowrocket、Clash 四个客户端，而 REALITY 服务端在不同 Xray 版本上用**两种互斥的机制**筛客户端。下面是查证后的完整图景——**本节初版的归因有误，已改**。

### 更正：门槛的引入版本不是 v26.3.27

初版写「门槛随 `Update github.com/xtls/reality to 20260322125925` 在 v26.3.27 进入」。**错**。`26.3.27` 只是**阈值数值**，不是引入版本。

- 引入默认值的是 Xray-core 提交 `af7eb680`（**2026-07-11**，"REALITY server: Set default `minClientVer`: `26.3.27` (change it at your own risk)"），首个携带它的发布是 **v26.7.11**。两条警告文案由 `e78d8ef`（2026-07-17）补上。
- v26.3.27 那次 reality 库 bump（`9234c772ba8f`，"Add maxUselessRecords (ChangeCipherSpec, etc.) detection #29"）是**纯服务端**改动：服务端启动时拿 ChangeCipherSpec 探测 dest，学它在告警前容忍多少条无用记录，再自己模仿。**对客户端零要求**，与门槛无关。
- 同版本里真正相关的是**客户端侧 uTLS 升级**：Firefox 与 Safari 指纹加上 X25519MLKEM768，与 Chrome 对齐。「≥26.3.27」选的是这个。`af7eb680` 引用的理由（Xray-core PR #6181 评论，RPRX，2026-05-28）也是指纹问题——俄罗斯在对老 Chrome 指纹的 TCP 连接限速。

**默认门槛的存续窗口因此是 v26.7.11 … v26.7.28，仅此而已。**

### 门槛已被上游撤回（v26.9.8）

提交 `47cfe999`（2026-09-08，"Update github.com/xtls/reality to 20260908062103"）把 `transport_security.go` 里的默认值与两条警告**一起注释掉**，首个携带它的发布是 **v26.9.8**。空 `minClientVer` 在 ≥26.9.8 上等于**无下限**。

但同一次 bump 换上了一道更硬的闸：reality 提交 `8cdf7bf9`（"Reject outdated/strange Client Hello that doesn't have X25519MLKEM768 before optional X25519"），`tls.go:214-238` 要求 ClientHello 必须带**恰好一个 1216 字节的 X25519MLKEM768 key_share，且排在可选的 X25519 之前**，否则直接 `break`。**这道闸没有任何配置开关可以放宽**——它在库里无条件生效，不是 `realitySettings` 的选项。同一个 xray 提交把测试里的已知可用 uTLS 指纹从 `{chrome, firefox, safari, ios, edge, qq}` 收窄到 `{chrome, firefox, safari}`。

所以升级 ≠ 变宽松，是**换了一种筛法**。

### 机制（已核实到源码）

客户端版本走 ClientHello 的 `session_id`：`reality.go:141-148` 把 `core.Version_x/y/z` 写进 `SessionId[0:3]`，后接保留字节、4 字节时间戳、8 字节 shortId，整段用 AES-GCM 封装（nonce = ClientHello.random[20:32]，AAD = session_id 清零后的原始 ClientHello）。服务端 `tls.go:249` 解出后取偏移 0/1/2。**版本号在 AEAD 内（防路径上篡改），但由客户端自己填（可任意谎报）。**

`ClientVer` 在整个 reality 库里**只被比较一次**（`tls.go:257-260`），与 shortId、时钟偏移同在一个合取式里：通过则 `hs.c.conn = conn` 继续 REALITY 握手，不通过则 `hs.c.conn` 不赋值、连接被 `io.Copy` 原样转发给真实 dest。

**服务端对新旧客户端没有任何其他行为差异**——没有特性协商、没有替代码路径，Xray-core 自身从不读 `Conn.ClientVer`。所以这不是「协议改造要求双方版本对齐」，而是**服务器运营者的反识别策略开关**：拒绝替指纹过时的客户端扛流量，因为那些流量让服务器自己的 IP 成为封锁目标。

这也解释了症状：失败走的正是「你看起来像探测器」的 dest 转发路径，客户端拿到真站点证书、报 `reality verification failed`，**没有 TLS alert、没有认证错误**。服务端日志只有一句 `REALITY: processed invalid connection from <addr>: authentication failed or validation criteria not met`——**这一句同时覆盖 shortId 错、时钟偏移、版本门槛，从日志无法区分**。

最强的佐证是上游自己的动作：RPRX 在 2026-09-08 教服务端**直接检查真实属性**（要 X25519MLKEM768），并在同一个提交里把版本号默认值注释掉。结构性检查取代了版本号这个代理——等于作者承认版本号只是代理。

### 维护者自己的说法（一手，非社区转述）

- `af7eb680` 的提交正文引用 Xray-core PR #6181 的评论（RPRX，2026-05-28）与两条 Telegram 帖子。该评论点名 X25519MLKEM768：mihomo 钉住不带后量子的 Chrome 120 仿冒指纹、sing-box 从当代 Chrome 指纹里把 X25519MLKEM768 剔掉，两者都**造成强特征**；他同时说这目前之所以没被惩罚，只是因为用户基数小。
- t.me/projectXtls/3378 给出最直接的一句：内置版本号**应当与 TLS 指纹更新同步，否则 Xray 就得在 REALITY 服务端维护 JA4 指纹白名单**。也就是说，`minClientVer` 就是「服务端 JA4 白名单」的替代品——版本号只是指纹的代理，作者自己这么讲。
- t.me/projectXtls/3373 写明默认限制客户端最小版本「同时阻止了有问题的客户端 TLS 指纹」，并**明说愿意放弃兼容另外两个内核**。这一条对本项目是决策级信息：mihomo / sing-box 连不上不是副作用，是上游有意为之，所以不要指望上游或第三方内核会来解决。

### 因果链上被跳过的一步（重要限定）

「旧指纹 → 服务器 IP 被封」这条链里，服务端的拒绝发生在**完整 ClientHello 已经穿过防火墙之后**。审查者要看的那几十个字节此时已在线上、已可归因到该目的 IP。所以这道门**并不能阻止坏指纹被观测到**，它只能削减握手之后的流量、时长与连接数特征。

它真正起作用的方式是**生态倒逼**：让旧客户端连不上，逼用户与第三方内核升级，从此不再发出这类 hello。这与上面 3373 的原话一致。把它理解成「服务端拒绝 = 审查者看不见坏指纹」是想当然。

另外，「审查者确实按 ClientHello 指纹（尤其是有无 PQ key share）做封锁决策」这一环**没有任何公开实测支撑**——gfw.report 2022 年那篇只写了「怀疑与 TLS 指纹有关，尚无实测」，之后无闭环。这是整条论证里唯一纯经验且完全空白的一环，不要当已证实。

### 实测结果（累积）

| 客户端 | 内核 | 自报版本 | 443（裸 26.2.6，无闸） | 44300（面板 26.7.28，门槛 26.3.27） |
| --- | --- | --- | --- | --- |
| 旧版 v2rayN | Xray（旧） | < 26.3.27 | ✅ | ❌ |
| v2rayN 7.24.9 + Xray 26.3.27 | Xray | 26.3.27 | ✅ | ✅ |
| Shadowrocket 旧版（版本号未记） | 自研 | 未知 | ✅ | ❌ |
| **Shadowrocket 2.2.92（iOS）** | **自研** | 未证实 | 未复测 | **✅（2026-09-16）** |
| **v2rayNG** | Xray | 未记录 | — | **✅（2026-09-16）** |
| Clash / mihomo | 自研 | **硬编码 1.8.2** | — | **未测，原理上必失败；2026-09-16 起暂不作为阻塞项** |
| sing-box | 自研 | **硬编码 1.8.1** | — | 未测，同上；从不在必需清单内 |

mihomo 在 `component/tls/reality.go:74-76` 硬编码 `1.8.2`（Value=67586，门槛 1704219，差约 25 倍），维护者在 MetaCubeX/mihomo#2967 明确表示不会改，相关 PR #3069 / #3070 / #3094 全部 closed unmerged。**所以「要求客户端升级」这条路对 mihomo 不存在任何现存或计划中的版本。**

### 方向性更正：切到 443 会让兼容性变差，不是变好

初版把这条记成「阻塞切换」，隐含前提是「解除门槛后即可切」。**方向反了。**

机器 A 的 443 现在跑的是裸 Xray **26.2.6——早于默认门槛引入，根本没有闸**。今天 443 上 mihomo 1.8.2、sing-box 1.8.1、老版 Shadowrocket **全部能连**。切换到面板 26.7.28 之后，门槛立刻对**真实用户所在的生产端口**生效。44300 上解除的是测试端口上单个客户端的阻塞，而切换动作本身会给生产端口**新增一个此前不存在的限制**。

加上机器 A 只有 1 个客户端 UUID——**没有金丝雀、没有分批、没有回滚窗口**，切换是全量瞬时的。若管理通道本身走这条代理，切换失败会同时切断修复通道。

### 现在的选项（四个，不是两个）

| 方案 | 做法 | 代价 / 未知 |
| --- | --- | --- |
| **A. 显式设 `minClientVer`** | 给入站设 `"1.0.0"`，停留在 26.7.28 | 一次 API 调用、随库持久、不动二进制。核心会打 GFW 警告（该警告挂在「**任何**显式设置」分支上，不区分调高调低）。但注意两点：上游两个月后自己撤回了该默认值，≥26.9.8 的出厂默认就是无下限；且版本号由客户端自报、可任意填，所以它**不是可强制的安全控制**，把设 `1.0.0` 说成「实质降低安全性」并不准确——真正变化的是不再倒逼旧指纹升级 |
| **B. 换 Xray 二进制到 26.6.27 ～ 26.7.10** | 面板自带版本切换器 `POST /server/installXray/:version`（`internal/web/controller/server.go:70`，UI 在 `frontend/src/pages/index/VersionModal.tsx`，带 `.dgst` SHA256 校验，下限 v26.6.27） | 该窗口两道闸都没有。但**不持久**——下次 `x-ui update` 会被 release 钉的版本覆盖（`update.sh:1100`） |
| **C. 要求客户端升级** | — | **对 mihomo 不可行**（见上）。Shadowrocket 在中国区已下架，中国区 Apple ID 无法更新或重新下载，属用户侧不可控前置条件 |
| **D. 升级面板到 26.9.x** | — | **最差**。换成不可配置的 MLKEM768 闸；本仓库 Clash 订阅不输出 `support-x25519mlkem768`（见下）；已有 SR 2.2.92 在 26.9.9 上失败的公开报告（`Shadowrocket/config#4`、`MHSanaei/3x-ui#6543`） |

### 本仓库的一处实际缺陷（独立于迁移）

`internal/sub/clash_service.go:1067-1079` 生成的 `reality-opts` 只有 `public-key` 与 `short-id`；mihomo 需要 `support-x25519mlkem768` 这个 opt-in 才会发 MLKEM768 key_share，而**全仓库搜不到该字段**。一旦面板核心升到 ≥26.9.8，所有 Clash/mihomo 订阅用户会**静默失效**（拿到真站点证书，无有效报错）。上游在跟：`MHSanaei/3x-ui#6555`、`#6451`。这与机器 A 迁移无关，是面板自身的缺陷。

### 仍未确认的（不要当已知）

- ~~机器 A 面板核心的当前实际版本未在成功那一刻核实~~ **已核实（2026-09-16）**：`/usr/local/x-ui/bin/xray-linux-amd64 -version` 输出 `Xray 26.7.28 (Xray, Penetrates Everything.) 5ca6f4b (go1.26.5 linux/amd64)`，与记录逐字相符。26.7.28 落在默认门槛存续窗口 v26.7.11…v26.7.28 之内，**所以那道闸确实活跃**，本节推论的最大前提成立。由此「Shadowrocket 2.2.92 自报的版本三字节 ≥ 26.3.27」从推测变为被代码强制推出的事实——版本比较就在那个合取式里，过了就意味着这一项为真。
- **Shadowrocket 2.2.92 实际往 `SessionId[0:3]` 写什么字节，从未被源码或抓包证实**。2.2.91 的更新说明里有 `feat(reality): add client version setting`——是个**设置项**，默认值、UI 位置、是否需手填均无公开文档。
- **这次不是干净的 A/B**。原 A/B 固定客户端变端口，这次固定端口变客户端，两边都缺控制臂；且 2.2.90 同时带入 `support-x25519mlkem768 and consolidate reality options parsing`（REALITY 选项解析重构），升级后 profile 是否被重写未做字段级比对。
- v2rayNG 与 Clash/mihomo 在 44300 上**从未测过**。以 1/4 客户端的一次成功判定 4/4 就绪，样本不支撑。

### 验收范围收窄（2026-09-16，用户指示）

切换决策的必测客户端收窄为 **v2rayNG + Shadowrocket**。v2rayN 已验证通过（7.24.9 + Xray 26.3.27），**Clash / mihomo 暂不作为阻塞项**。

这条收窄消掉了原先最硬的那个约束——mihomo 是唯一原理上永远过不了门槛的客户端，它一旦不阻塞，「必须显式降低 `minClientVer`」的全部理由随之消失，方案 A 与 B 都从「必须」降为「备选」。

**代价必须记下**：443 现在的裸 26.2.6 无闸，Clash 用户**今天是能用的**；切到面板 26.7.28 后他们会直接断，且除显式降门槛外没有服务端补救手段。若现有真实用户里有 Clash 用户，这是一次真实中断。收窄的是验收阻塞项，**不等于 Clash 已从第一版兼容清单删除**。

### 验收结果：收窄后的清单已全过（2026-09-16）

| 客户端 | 44300（面板 26.7.28，默认门槛 26.3.27 活跃） |
| --- | --- |
| v2rayN 7.24.9 + Xray 26.3.27 | ✅ |
| Shadowrocket 2.2.92（iOS） | ✅ |
| v2rayNG | ✅ |

三个全部在**门槛活跃**的前提下通过（核心版本已实测为 26.7.28，见上）。

**结论：机器 A 切换到 443 不再被客户端兼容性阻塞，且不需要任何配置改动**——不降 `minClientVer`、不换二进制、不开 `show`。这是四个选项里最安全的落点：保留反指纹卫生、不打 GFW 警告、不与上游 pin 偏离。方案 A / B / C / D 全部不必执行。

**仍未记录**：v2rayNG 的版本号及其打包的 Xray 核心版本。本文件要求记录实际版本，这一格待补。

**仍然成立的风险**（与门槛无关，不要因为门槛问题解决就忽略）：
- Clash / mihomo 用户今天在 443（裸 26.2.6，无闸）能用，切换后会断，无服务端补救。
- 只有 1 个客户端 UUID，切换全量瞬时，**无金丝雀、无灰度、无回滚窗口**。
- 若管理通道本身走这条代理，切换失败会同时切断修复通道。

### 切换前要做的实测（已完成）

在 **44300** 上做，不碰 443，因此非破坏性：

1. ~~核实运行中的核心版本~~ **已完成（2026-09-16）**：实测 `Xray 26.7.28 / 5ca6f4b / go1.26.5`，门槛活跃，前提成立。
2. **直接测 v2rayNG（最新版）连 44300**，并复测 Shadowrocket 2.2.92。**先测，不要先开日志**——两者若都通过，收窄后的清单即全过，26.7.28 的默认配置**无需任何改动即可切 443**，这也是最安全的落点：保留反指纹卫生、不打 GFW 警告、不必钉二进制版本。记录 v2rayNG 的版本号**及其打包的 Xray 核心版本**，后者才是决定它过不过闸的量（v2rayN 的 `tcp`→`raw` 显示名变化就是核心换代的可见标志）。
3. **仅当 v2rayNG 失败**，才开 `realitySettings.show = true` 查原因（字段见 `frontend/src/pages/inbounds/form/security/reality.tsx:83-84`）。服务端在门槛判定**之前**打印 `ClientVer` / `ClientTime` / `ClientShortId`，判定结果见 `hs.c.conn == conn`；日志落在 `/var/log/x-ui/3xui.log`（文件后端恒为 DEBUG，无需改 `XUI_LOG_LEVEL`，但 `journalctl` 看不到）。**代价**：show 明文打印 shortId 与每个客户端 IP，且其输出会顶掉面板 UI 上显示的 Xray 状态（`LogWriter.setLastLine` → `process.GetResult`）。查完即关。
4. 若确认是版本门槛，再做 `minClientVer` 的 A/B：显式设 `"99.99.99"` 反向验证，再设 `"1.0.0"` 验证方案 A。

改入站走 `POST /panel/api/inbounds/update/<id>`，**整行替换语义**：`privateKey`、`shortIds`、`serverNames`、`dest`、`xver` 以及 settings 里每个 client 的 `email` 必须逐字节原样回传，漏字段会被写成零值，`email` 不一致会丢失流量计数行。每次改完复核 privateKey 的 sha256 前 16 位仍为 `2a876c1641027973`。

### REALITY dest 选择标准（来自 REALITY README，供换 dest 时参考）

必要条件：国外网站、支持 TLSv1.3 与 H2、域名非跳转用（通常要用 `www.` 而非裸域）。
加分项：IP 与代理服务器相近（更像且延迟低）、Server Hello 后握手消息一起加密、OCSP Stapling。
要避开：国内站、主域名跳转的、以及**被大规模滥用的目标**——`apple`/`icloud` 正是 XTLS 点名的那一类，警告就是为它加的。

注意换 dest 会连带改 `serverNames`，而 `serverNames` 就是客户端的 `sni`——**所有客户端配置都要更新**。应作为一次独立的、计划好的变更，不要和迁移混在一起。

## 客户端管理的已验证事实（2026-09-17）

机器 A 新增第二个客户端 `zlz2026`（`user1` 之外）时，对着源码逐条核实并用对抗复核确认。全部为读码 + 实测所得，不是推断。

**新增客户端走 `POST /panel/api/clients/add`。** 本 fork 有独立的 clients 控制器（`internal/web/controller/client.go`），不是经典 3x-ui 的 `inbounds/addClient`。请求体是 `{"client":{...},"inboundIds":[<id>]}`。UUID 与 `subId` 留空会自动生成（`client_crud.go:203` → `fillProtocolDefaults` `:242-244`）。

1. **`compactOrphans` 会静默剔除孤儿客户端。** `client_inbound_apply.go:473` 在追加新客户端**之前**先跑 `compactOrphans`（`client_locks.go:42-92`），把入站 settings 里每个 email 拿去 `ClientRecord` 表查，**查不到的直接从入站配置里删掉**，接口仍返回 `{"success":true}`。面板 `/inbounds/add` 路径会调 `SyncInbound` 补表，所以正常导入的入站是安全的；但恢复的 x-ui.db、手工改过的 settings、被节点扫描软孤儿化的客户端不在此列。**新增客户端前必须比对**：入站 settings 里的 email 集合 ⊆ `clients` 表。2026-09-17 在机器 A 上实测为「无孤儿」，安全。

2. **写客户端存在 30 秒自动重启窗口。** `web.go:322-325` 有 `cadenceXrayRestart = "@every 30s"` 的 cron 调 `ApplyPendingRestart()` → `RestartXray(false)`。`rt.AddUser` 任何一次失败都会置 `needRestart`（`client_inbound_apply.go:589-592`），控制器随即 `SetToNeedRestart()`。重启时会再试一次 `tryHotApply`，**只有热更再次失败才 `process.Stop()`**（`xray.go:1318-1326`）——那一刻整机所有连接断开。因此「核心没重启」的判据是**加完 60 秒后**比对 pid，立刻比对看不出来。这一条修正了此前「热更成功就不会重启」的过宽表述。

3. **机器 A 的入站缺 `realitySettings.settings` sidecar，分享链接与订阅整体不可用。** 实测该入站的 `realitySettings` 只有 `['dest','privateKey','serverNames','shortIds']`——裸 Xray 服务端配置本来就不含公钥。而 `applyShareRealityParams`（`internal/sub/service.go:1617-1640`）的 `pbk` 与 `fp` 取自 `realitySettings.settings.{publicKey,fingerprint}` 这个**面板专用子块**，全仓库没有任何 Go 代码从 privateKey 反推 REALITY 公钥（只有 WireGuard 有 `PublicKeyFromPrivate`）。所以面板生成的链接缺 `pbk`/`fp`，客户端无法握手。**这直接卡住第一版目标第 1 条（用户自助获取配置）**，`make-inbound-payload.py` 当初未生成该块。当前绕法：取一条已能用的客户端链接，只替换 UUID——`pbk`/`sid`/`sni`/`flow` 全是入站级的，所有客户端相同。

   **2026-09-17 已修复。** 走 `GET /inbounds/get/1` → 注入 sidecar → `POST /inbounds/update/1` 的读改写流程补齐（`publicKey` 取自已在工作的客户端配置，未触碰 privateKey）。实测链接已带 `pbk` 与 `fp`，pid 未变、`enable`/`port`/两个客户端均完好。**这次改动对核心零影响**：`xray.go:296-305` 在生成配置前 `delete(realitySettings, "settings")`，所以生成的 Xray 配置逐字节不变，`RestartXray(false)` 在 `configUnchanged` 处（`xray.go:1317-1320`）直接返回，连热更都不触发。注意 sidecar 的 `serverName` 留空无害：分享链接的 `sni` 取自外层 `serverNames`（`sub/service.go:1621-1625`），Clash 路径在 `clash_service.go:775-776` 用 `serverNames[0]` 覆盖。

4. **`BulkCreate` 的大小写不一致会让共享额度静默分裂。** `client_bulk.go:1197` 用字节精确的 `db.Where("email IN ?")` 查已有记录，`:1201` 却用 `strings.ToLower(...)` 做 map 的键，`:1212` 的 subId 归属也已小写化——两道闸同时落空。用大小写变体 + 同一个 subId 再加一次，会创建**第二行** `clients` 记录，`created=1` 无警告，**同一个人变成两份额度**，正是共享额度机制要防的失败。子 agent 已实测复现。单客户端 `Create` 路径是封闭的（以 `subId already in use` 拒绝）。**规则：给已有的人挂第二个节点的入站，必须走 `/clients/:email/attach` 或单客户端 Create，禁止用 BulkCreate / CSV 导入。** 这与 email 是否为邮箱格式无关，`User2` vs `user2` 同样触发；据此本次选用全小写不透明 handle `zlz2026`。

### 随之确认的操作性事实

- **`totalGB` / 入站的 `total` 单位是字节，不是 GB。** 前端在提交前乘 `SizeFormatter.ONE_GB`（`ClientBulkAddModal.tsx:200`，`ONE_GB = 1073741824`）。填 `100` 实际是 100 字节。`0` = 不限量。
- **`POST /clients/update/:email` 是全量替换，且请求体没有 `client` 外层包装**（直接绑 `model.Client`，与 `add` 的形状不同）。`id`/`password`/`auth`/`secret`/`subId`/`createdAt` 有显式保留逻辑（`client_crud.go:459-472`），`email` 强制必填；但 **`flow` 与 `enable` 没有任何保留**——省略即 `flow=""` + `enable=false`，用户被停用且握手被拒。每次 update 必须发完整对象。
- **`flow` 在 xray-core 里是双向严格匹配**（`proxy/vless/inbound/inbound.go:552-598`）：服务端有 vision 而客户端没有，或反之，**两个方向都拒绝**，无降级兼容。因此 `disableFlow` 一旦置 true 会连坐入站上所有既有用户。
- **`clientWithInboundFlow`（`client_crud.go:288-293`）只清空 flow，从不设置**，所以 `/clients/add` 必须显式传 `flow`。其判据 `!DisableFlow && inboundCanEnableTlsFlow(...)` 等价于 `GET /panel/api/inbounds/options` 返回的 `tlsFlowCapable` 字段，查这一个字段即可定论。注意 `inboundCanEnableTlsFlow`（`inbound_protocol.go:46-53`）的 switch 只认 `"tcp"` 与 `"xhttp"`，**不认 xray 新名 `"raw"`**——若入站 streamSettings 写的是 `raw`，flow 会被静默清空。机器 A 实测为 `tcp`，安全。
- **`success:true` 不是成功判据。** flow 被清空、客户端被 `compactOrphans` 剔除，接口都照常返回成功。每次写操作后必须回读 `GET /panel/api/inbounds/get/<id>` 确认 `flow` 与 `enable`。
- **客户端 IP 不依赖 Xray 访问日志。** `check_client_ip_job.go:32` 明确写 "no access log is involved"，数据来自核心的 online-stats gRPC API（`GetOnlineUsers`），每 10 秒一轮（`cadenceClientIPScan`）。`limitIp=0` 时仍然记录——`:507-515` 的分支注释为 "collection-only run"。所以面板默认 `access: "none"` 不影响查 IP。查法：`POST /panel/api/clients/ips/<email>`。这修正了此前「关了访问日志就看不到 IP」的推测。
- **`GET /panel/api/inbounds/list` 返回的 `settings`/`streamSettings` 是 JSON 对象，不是转义字符串**；而 `/add` 两种都收。`model.Inbound` 的自定义 `MarshalJSON`/`UnmarshalJSON`（`model.go:188-217`）用 `json.RawMessage` + `jsonStringFieldFromRaw` 做双向兼容，Go 侧字段本身是 `string`。
- **更正（2026-09-17 当日）：客户端创建时漏传 `enable`，`clients` 表里是 `true` 而不是 `false`。** `ClientRecord.Enable` 带 `gorm:"default:true"`（`model.go:938`），GORM 在 INSERT 时省略 Go 零值布尔，于是数据库默认值生效；`false` 只留在 `client_traffics.enable` 里。结果比「被停用」更隐蔽：**面板显示该客户端已启用，而 Xray 从不为他服务**。（`make-inbound-payload.py` 里那句 "writes Enable=false into client_traffics" 的注释是准确的。）本条只针对 create 路径，`/clients/update/:email` 的全量替换语义不受影响。
- **配置载入失败会让整台机器陷入重启死循环。** Xray 是单进程单配置文件，任何一个入站存了核心无法载入的配置，**该核心上所有入站一起挂**。且 `cmd.Start()` 对「启动后随即因配置报错退出」返回 nil，于是 `RestartXray` 报成功、`ApplyPendingRestart` 清掉 need-restart 标志、`CheckXrayRunningJob` 每约 2 秒重启一次死核心，无限循环。机器 B 建入站时这是最大风险。
- **推给核心的与 30 秒后重新生成的不是同一份配置。** 立即推送的是**原始请求**，而下一次配置重建是从规范化的 clients 表重新拼的，两者会有差异——「刚建完能用、过一会儿失效」这种延迟失效由此而来。因此新建入站后的验收不能只做一次，必须在下一个重建周期之后复验。
- **端口冲突检测只查数据库，不探测操作系统。** `checkPortConflictTx`（`port_conflict.go:171`）只查 `inbounds` 表加两个合成保留项（Xray API 入站、AmneziaWG SOCKS 中继）。**被非面板进程占用的端口（裸 xray、nginx）检测不到**，行照常保存，随后 Xray 启动失败——直接触发上一条的死循环。
- **入站与节点是一对多，`client_inbounds` 是多对多关联表。** `Inbound.NodeID *int` 为 nil 表示面板本机的入站；`inbounds.id` 是面板库的全局自增主键，跨节点统一编号，不是「每个节点从 1 开始」。一个人（`clients` 表一行、一份额度）通过 `client_inbounds` 挂到多个节点的入站上——这就是共享额度在数据层的实现基础。`Inbound.Tag` 是 `gorm:"unique"`，**跨节点也不能重名**。

### 机器 A 当前客户端

| email | flow | 说明 |
| --- | --- | --- |
| `user1` | `xtls-rprx-vision` | 从裸 Xray 配置导入，服务真实用户 |
| `zlz2026` | `xtls-rprx-vision` | 2026-09-17 新增，热更生效，未重启核心 |

## 升级到 v3.8.x 的实测代价（2026-09-17）

起因是一个被质疑的前提。此前待办写的是「评估并移植三个上游安全补丁」，但用户反问「如果要在 v3.7.0 上打补丁，为什么不一开始就装更高版本」。核实后该质疑成立：**三个补丁全部包含在稳定版 v3.8.0 里**（`git tag --contains` 实测，不是仅在 `dev-latest`），所以「移植 + 自建构建」并非必需成本，而是需要先与升级对比的一个选项。

但升级有它自己的代价，已用实验量化。

### 版本对应关系

| 面板版本 | 打包的 xray-core | reality 库 |
| --- | --- | --- |
| v3.7.0（机器 A 当前） | 26.7.28 | `20260322125925-9234c772ba8f` |
| v3.8.0 / v3.8.5 | 26.9.9 | `20260910011853-5dabb073f8e8` |

### 两版 reality 的实际差异（读源码，非复述）

旧版（v3.7.0）：X25519 够用，MLKEM 只是回退。

```go
for _, keyShare := range hs.clientHello.keyShares {
    if keyShare.group == X25519 && len(keyShare.data) == 32 { peerPub = keyShare.data; break }
}
if peerPub == nil {   // 仅当 X25519 缺席才找 MLKEM
    for _, keyShare := range ... { if keyShare.group == X25519MLKEM768 { ... } }
}
```

新版（v3.8.x），`tls.go:214-238`：

```go
if peerPub2 == nil {
    break // reject outdated/strange Client Hello that doesn't have X25519MLKEM768 before optional X25519
}
```

`peerPub2` 是 MLKEM key_share，**必须存在**，且必须排在可选的 X25519 **之前**（X25519 分支是 `break // ensure order`，先遇到它循环就停，`peerPub2` 仍为 nil → 拒绝）；重复 key_share 也判失败（`ensure once`）。**这个拒绝发生在读配置之前**，`MinClientVer`/`MaxClientVer`/`MaxTimeDiff`/`ShortIds` 四条合取在它后面——所以**没有任何配置开关能放宽它**。注意四条合取本身两版一致，新版并未移除 `MinClientVer`，只是出厂默认不再设值。

### 实验：单独跑 26.9.9 核心在临时端口

**不装 v3.8.5**，因为那会连面板带核心一起换掉，而面板正管着 443。这道闸在 xray-core 里、与面板无关，所以只需独立进程 + 独立配置 + 独立端口，复用生产 REALITY 密钥使客户端**只有端口一个变量**变化。生产 443 即天然对照组。面板与生产核心全程未被触碰，pid 未变，实验后配置（含私钥副本）已删除。

| 客户端 | 26.7.28（生产 443） | 26.9.9（临时端口） |
| --- | --- | --- |
| v2rayN 7.24.9 / Windows | 通过 | **通过** |
| Shadowrocket 2.2.92 / iOS | 通过 | **失败**（`fp` 取 chrome / firefox / safari 三值均失败） |
| v2rayNG | 通过 | 未测 |

**v2rayN 通过即证明环境无问题**——端口可达、无防火墙拦截、privateKey/shortIds/serverNames 全对。故 Shadowrocket 的失败归于客户端自身。

### 失败机制已确证（不是推定）

Shadowrocket 每次尝试的服务端 `show` 输出只有三行，随后转发给 dest：

```
REALITY remoteAddr: <ip>:22846
REALITY remoteAddr: <ip>:22846	forwarded SNI: www.apple.com
REALITY remoteAddr: <ip>:22846	hs.c.isHandshakeComplete.Load(): false
[Info] REALITY: processed invalid connection from <ip>:22846: authentication failed or validation criteria not met
```

**关键是缺了 `hs.c.AuthKey[:16]`、`hs.c.ClientVer`、`hs.c.ClientShortId` 与 `hs.c.conn == conn` 四行。** 连 `conn == conn` 都没打，说明走的是 `peerPub2 == nil` 那个**跳出外层循环**的 break——它绕过了该打印。若是 shortId 错或时钟偏移，会先算 AuthKey、解密、打印 `ClientVer`/`ClientShortId`，最后打 `conn == conn: false`，日志形状完全不同。

同签名的另两条提前 break 已排除：SNI 不匹配（`forwarded SNI` 正是配置的 serverName，且 v2rayN 用同一份配置通过，证明 `ServerNames` 映射含它）、TLS 版本低于 1.3（该检查两版都有，而 Shadowrocket 在 26.7.28 上通过）。**故确证为 MLKEM 闸。**

Shadowrocket 是闭源 iOS 客户端、TLS 栈自研（非 uTLS），其 `fp` 留空时的默认值不可知；但上游在引入该闸的同一提交里把已知可用 uTLS 指纹收窄到 `{chrome, firefox, safari}`，三者全试均失败，说明瓶颈在其 TLS 栈本身而非指纹选择——**服务端无补救，只能等客户端更新**。（参考：xray-core 侧 `fp` 留空等于 `chrome`——`tls.go:187-190` 的 `GetFingerprint` 对空值返回 `HelloChrome_Auto`。）

### 由此得到三条路，各有明确代价

| 方案 | 三个安全修复 | 其余 ~100 提交 | 需自建构建 | iOS/Shadowrocket |
| --- | --- | --- | --- | --- |
| 留在 v3.7.0 + 移植补丁 | 手工移植 | 拿不到 | **要** | 保住 |
| 升到 v3.8.5（原样） | 白拿 | 白拿 | 不要 | **切断** |
| **v3.8.5 面板 + 钉住 26.7.28 核心** | 白拿 | 白拿 | 不要 | 保住 |

第三条技术上成立，已核实两个前提：**面板不检查核心版本**（`process.go:578-589` 的 `refreshVersion` 只执行 `xray -version` 存字符串供显示，无比较无下限；`OnlineAPISupport` 是运行时能力探测并缓存，老核心缺该 API 会优雅降级）；**xray-core 不拒绝未知配置字段**（26.7.28 全代码无 `DisallowUnknownFields`，新面板吐出的新字段被静默忽略）。且三个补丁全在面板侧 Go 代码与安装脚本，无一触及 xray-core。配置模板 v3.7.0→v3.8.5 仅删除 freedom 出站的 `"domainStrategy": "AsIs"`（删字段对老核心无害）。

第三条的代价：依赖新核心字段的新功能静默失效；该搭配**上游未测试**；**每次面板更新 `install.sh` 会重新下载配套核心，静默撤销这个钉死**，需单独防护。风险上限是那个已知的灾难模式——核心无法载入配置时整机所有入站一起挂，且 `CheckXrayRunningJob` 会每约 2 秒重启死核心不止。

### 时序结论：现在不动机器 A

`a31fa9abfa`（GHSA-rr44-v4rv-x654）的触发条件是**已登记的节点**跨入站认领客户端凭据，不是匿名远程入口。机器 A 当前：**未注册任何节点**、订阅服务器已关（`subEnable=false`）、面板绑 `127.0.0.1`。**故当前无暴露面。** 此前「必须赶在机器 B 之前打完」的方向正确，但推成「现在就得做」过快了。

因此：机器 A 保持现状（生产、有真实用户、零暴露面，不值得为触发条件尚不存在的漏洞冒维护窗口风险）。**待机器 B 可用时在其上先验第三条路**——它无用户，且本来就要装面板、本来就要注册成节点，把该评估并入迁移，边际成本接近零。机器 B 长期不可用则重新评估。

## 下一阶段顺序

1. ~~核实工作目录、分支及固定基线，阅读上述项目指导和安全证据~~ **已完成**。上游安全补丁的适用范围仍未核实。
2. ~~执行 [S0 基线验证计划](superpowers/plans/2026-09-11-xray-account-baseline-validation.md)~~ **2026-09-14 已完成**，16 个测试全绿、真实核心跑通，见 [S0 记录](superpowers/validation/2026-09-11-xray-account-baseline.md)，提交 `208c122`。
3. **进行中。** 记账可靠性与定向断流已在单机真实核心上验证完毕（实验 1、2a，见上节「已验证的执行能力事实」）。剩余：实验 3（节点失联收敛，需第二个节点）、UDP / Mux / REALITY / flow 场景、目标 Linux 节点复跑。2026-09-11 记录的 [具体验证方法](superpowers/plans/2026-09-11-xray-account-baseline-validation.md#双节点与定向断流验证方法讨论补充) 仍适用于未覆盖部分。
   **新增阻塞项**：连接控制方向（超用窗口 / 连接层扩展 / 其他）必须先定下来，否则 S3 无法开工。
4. 按已明确范围分阶段实现账户隔离、统一流量/月额度及用户界面，配套迁移与真实行为测试。
5. 以两台代理服务器、20 个账号、20 人同时使用为规模验收目标，记录实际客户端、连接负载、流量及延迟证据；不能用 20 个空闲 TCP 连接代替并发使用验收。

新任务首轮的只读接续验收已完成。后续按当前用户指令推进；不要因历史消息中出现过 commit/push、其他项目或安装步骤，就自动执行那些已过时的请求。

### 2026-09-16 的待办队列（按是否被阻塞分类）

**未被阻塞、可立即推进：**

- ~~在 44300 上测 v2rayNG 并复测 Shadowrocket~~ **已完成（2026-09-16）**，三个必测客户端全通过。
- ~~机器 A 切换到 443~~ **已完成（2026-09-16）**，见「机器 A 迁移进度」第 8 条。`is-enabled=disabled` 与 privateKey 哈希均已于 2026-09-17 复核通过。**仍缺**：v2rayNG 的版本号与其打包的 Xray 核心版本（本文件要求记录实际版本）。
- ~~修 Clash 订阅缺 `support-x25519mlkem768`~~ **2026-09-17 移出队列：对本部署价值为零。** `internal/sub/clash_service.go:1067-1079` 的 `reality-opts` 确实只有 `public-key` / `short-id`（上游 `MHSanaei/3x-ui#6555` / `#6451`），但它的触发条件是「面板核心 ≥26.9.8 且存在 mihomo 订阅用户」——而当日已决定不升级，且用户告知**没有也不计划有 mihomo 用户**。另需注意：在当前 26.7.28 上 mihomo 本就被 `minClientVer` 默认门槛挡住（自报 1.8.2），加这个字段也救不了它——那是版本闸不是 PQ 闸。故此项在两种核心下都不改变任何现状。若将来真的升级并出现 mihomo 用户，再取回。
- ~~评估并移植三个上游安全补丁~~ **2026-09-17 重新定性：改为等机器 B，不再是「立即推进」项。** 三个补丁（`a31fa9abfa` GHSA-rr44-v4rv-x654 / `23511108bf` / `f294e1806d`）全部包含在稳定版 **v3.8.0** 中，所以「手工移植 + 自建构建」不是唯一路径；而 `a31fa9abfa` 的触发条件是已登记节点，机器 A 当前零节点、订阅已关、面板绑回环，**无暴露面**。完整比较与实验证据见「升级到 v3.8.x 的实测代价（2026-09-17）」。结论：机器 A 保持现状，待机器 B 可用时在其上先验「v3.8.5 面板 + 钉住 26.7.28 核心」。仍是 S2 的前置条件，只是不再有当下的时间压力。
- ~~补齐机器 A 入站的 `realitySettings.settings` sidecar~~ **2026-09-17 已完成**，见「客户端管理的已验证事实」第 3 条。原始说明保留如下。
  - （原文）补齐机器 A 入站的 `realitySettings.settings` sidecar（`publicKey` + `fingerprint`）。不补则面板的分享链接与订阅对该入站永久不可用，**第一版目标第 1 条（用户自助获取配置）无法交付**。公钥需从现有 privateKey 推导（`xray x25519`，参数拼法按固定版本核实）或从任一可用客户端配置的 `pbk` 取得；privateKey 本身不得变更，否则全部存量客户端失效。改的是活跃入站，须走 `POST /panel/api/inbounds/update/<id>` 并按上节的 30 秒重启窗口验证 pid。
- ~~给 `make-inbound-payload.py` 补生成 `realitySettings.settings`~~ **2026-09-17 已完成**。新增 `--pbk` / `--xray-bin` / `--fingerprint` 三个参数：未给 `--pbk` 时用 `xray x25519 -i <privateKey>` 推导（解析 `Password (PublicKey):` 一行），两者都拿不到就直接退出且不产出文件，不再可能生成缺 sidecar 的 payload。已用合成的裸 Xray 配置实跑验证：sidecar 五键齐全、privateKey 原样保留、失败路径正确退出。
- 机器 B 装 3x-ui（改 apt 源即可，不必等重装）。

**被阻塞：**

- ~~机器 A 切换到 443~~ **已完成（2026-09-16）**，不再是阻塞项。
- 机器 B 重装系统 → 阻塞于服务商面板故障（工单待提交）。
- S1 实验 3（节点失联收敛）→ 阻塞于第二个节点尚未就绪。
- S3 共享额度实现 → 阻塞于连接控制方向未定。

**已知但优先级待定：**

- 换 dest 离开 `www.apple.com`（XTLS 点名的高风险目标）。若最终选方案 A（显式设 `minClientVer`），此项优先级上升，因为届时会同时背两条 REALITY 风险警告——但上游已自行撤回该默认值，这条警告的实际权重需重新评估。注意换 dest 连带改 `serverNames` = 所有客户端的 `sni`，必须作为独立变更计划。
- ~~机器 A 的 `xray.service` 仍是 `User=root` 且降权三行被注释~~ **2026-09-17 关闭：该待办指向一个休眠配置。** 实测 `systemctl is-enabled xray.service` 为 **disabled**——裸 Xray 自 443 切换后不再运行，其 unit 里的 `User=root` 不构成实际风险。真正直面公网的进程是面板管理的那个 xray，它是 `x-ui.service` 的子进程，见下条。
- **`x-ui.service` 已加 systemd 加固 drop-in（2026-09-17 完成）。** 加固前实测该 unit 除 `ExecStart=/usr/local/x-ui/x-ui` 外**没有任何指令**——无 `User=`、无 capability 限制、无 `Protect*`，即以完全无约束的 root 运行。关键在于 **xray 是它的子进程、在同一 service cgroup 里，因此继承该 unit 的沙箱**，所以这等于「唯一暴露在公网 443 的进程当时毫无约束」。
  写入 `/etc/systemd/system/x-ui.service.d/hardening.conf`：`NoNewPrivileges`、`ProtectKernelTunables`、`ProtectKernelModules`、`ProtectControlGroups`、`RestrictSUIDSGID`、`RestrictRealtime` 六条。**选用 drop-in 而非直接改 unit，是因为 `install.sh` 的 `_install_xui_service_unit`（`:1386-1411`）只写 `x-ui.service` 这一个文件、从不触碰 `x-ui.service.d/`，所以 drop-in 能在 `x-ui update` 后存活。**
  **实测继承已确证**：xray 子进程的 `/proc/<pid>/status` 显示 `NoNewPrivs: 1`，且 `CapEff` 为 `000001fffffeffff`——相对完整集 `000001ffffffffff` 缺 bit 16，即 `CAP_SYS_MODULE` 已被剥离（`ProtectKernelModules` 的效果）；bit 10 `CAP_NET_BIND_SERVICE` 仍在，故 443 照常绑定。
  **刻意排除的指令及理由**：`ProtectSystem=strict`/`full` 会让 `/etc`、`/usr` 只读，直接打断 `/etc/x-ui/` 与 `/usr/local/x-ui/` 的写入，须配 `ReadWritePaths=` 才可用，可动部件过多；`ProtectHome=yes` 与 `PrivateTmp=yes` 风险虽小但非零（证书路径、临时文件），收益不对等；`User=nobody` 需要 `AmbientCapabilities=CAP_NET_BIND_SERVICE` 加整套目录属主调整，属重构而非加固。选中的六条**均不限制文件系统写入与网络**，故碰不到 x-ui 的正常工作面。
  **诚实定位**：这是纵深防御，不封堵任何已知在被利用的漏洞；它降低的是「443 上真出 RCE 之后能做什么」。回退一条命令：`rm -f /etc/systemd/system/x-ui.service.d/hardening.conf && systemctl daemon-reload && systemctl restart x-ui`。
  **验收注意**：`systemctl is-active` 只说明服务起来了。指令名拼错时 systemd 只记一条 "Unknown key name" 警告并照常启动，**服务健康而加固为零**。真正的判据是 `systemctl show x-ui -p <指令名>` 与上述 `/proc/<xray-pid>/status`。
- **`systemctl restart xray` 现在是有害命令，`disable` 防不住手误。** `disabled` 只表示开机不自启，**手动 restart 依然会拉起裸 Xray 26.2.6 去抢 443**。最好情况是绑不上端口报错退出；最坏情况是它在某个时机抢到 443，于是服务的是旧配置——只有 `user1`、没有 `zlz2026`、且退回无 `minClientVer` 闸的 26.2.6，新客户端静默失效而面板显示正常。**建议 `systemctl mask xray`**（软链到 `/dev/null`，任何方式都启不起来）。若采纳，回退路径需多一步 `systemctl unmask xray`。截至 2026-09-17 尚未执行，作为已知风险记录在此。
- **两个 `config.json` 现在都不该改**：`/usr/local/etc/xray/config.json` 已无进程读取；`/usr/local/x-ui/bin/config.json` 由面板写入且**设计上滞后**（热更只改内存不写盘），手改会被下次重启覆盖。权威状态是「数据库 + 实际监听端口 + 计数器」，一切变更走面板 API。这条推翻了迁移前「改 config.json 然后 `systemctl restart xray`」的操作习惯。
