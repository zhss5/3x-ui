# Xray 账户管理项目交接

交接日期：2026-09-11。来源：Codex 任务 `xray`，ID `01a07ae9-e79d-7b01-9fcd-31594bea3acf`。

本文件是原讨论的聚焦摘要，用来补充分叉历史，并在后续上下文压缩后保留项目约束。

2026-09-14 状态更新：S0 基线验证已执行完毕（[记录](superpowers/validation/2026-09-11-xray-account-baseline.md)），S1 实验 1 与 2a 已执行（[记录](superpowers/validation/2026-09-14-xray-account-s1-experiments.md)）。实验结果**否定了第一版一项隐含前提**——现有 API 无法中断已建立的连接，详见下文「已验证的执行能力事实」。仍未实现账户管理功能，未应用任何安全补丁。

2026-09-15 状态更新：机器 A（`vm44212`）已重装为 Ubuntu 24.04、裸 Xray 已从备份恢复并经真实用户验证、3x-ui v3.7.0 已安装并加固。详见下文「机器 A 迁移进度」。

2026-09-16 状态更新：机器 A 的入站已导入面板并用约 4 MB 真实流量验证通过（临时端口 44300）。**切换到 443 仍然延后。** 用户仍由裸 Xray 26.2.6 在 443 服务，状态安全可逆。机器 B 因服务商面板故障暂时无法重装，已定位原因。

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

第一版仍需兼容 v2rayN、v2rayNG、Shadowrocket、Clash；没有授权改用自研配套客户端。用户于 2026-09-11 通过“确认设计文档”批准 [第一阶段设计](superpowers/specs/2026-09-11-xray-account-phase1-design.md)，采用管理员开户、UTC 自然月、整数 byte 存储/GiB 展示，以及统一设置当期和后续周期月额度且保留已用量的默认方案。无需重复请求设计批准；文中保留的连接执行、失联策略和凭据重置细节继续通过验证与细化解决。

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

两台代理服务器**已存在并在服务真实用户**，服务用户的都是官方 `Xray-install` 装的裸 Xray。机器 A 上已额外安装 3x-ui，但尚未接管流量（见「机器 A 迁移进度」）。

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

**未完成且已决定延后：切换到 443。** 原因见下节「客户端兼容性硬约束」。当前状态安全且可逆——面板已装好、入站已验证、裸 Xray 照常在 443 服务用户，两者并存互不干扰。

切换的剩余步骤（待约束解除后执行）：`systemctl disable --now xray`（必须是 `disable --now`，只 `stop` 会让两个 unit 都保持 enabled、下次重启抢端口）→ `POST /panel/api/inbounds/update/<id>` 把端口改 443 → 复核 privateKey 哈希 → 真实客户端验证。回滚是反序：先把面板入站挪回 44300 让出端口，再 `systemctl enable --now xray`。

**磁盘上的 `/usr/local/x-ui/bin/config.json` 会滞后，这是正常的。** 面板走热更新路径（`tryHotApply`），通过 Xray gRPC API 直接改运行中的核心，而 `Process.SetConfig`（`internal/xray/process.go:313-317`）只更新内存、不写磁盘；磁盘配置只在真正重启时（`process.go:599`）重写。反过来说：**滞后的 mtime 本身就是热更新成功的证据**——若热更新失败会回落到 `process.Stop()` + 重启，那时磁盘配置会被刷新。权威状态是「数据库 + 实际监听端口 + 计数器」，不是那个文件。

转换脚本见 [`superpowers/tools/make-inbound-payload.py`](superpowers/tools/make-inbound-payload.py)：在节点上读 `config.json`、生成 `/panel/api/inbounds/add` 所需的 payload（`settings`/`streamSettings`/`sniffing` 需为转义字符串），自动补 `enable:true` 与缺失的 `email`，拒绝使用当前生效端口，并打印脱敏预览（私钥与 UUID 只显示长度和 sha256 前 16 位）。机器 B 迁移时复用同一脚本。

### 过程中踩到并确认的操作性事实

- **`/usr/bin/x-ui` 是 shell 包装脚本，不接受 `setting` 子命令**（它自己的子命令表里是 `settings` 复数）。CLI 必须用二进制全路径 `/usr/local/x-ui/x-ui setting ...`。包装脚本内部也一律这么调。
- **交互式安装的端口输入不支持方向键**，转义序列会被原样吃进参数。而 `install.sh:1217` 是把 username/password/port/webBasePath **四项放在一条命令**里设的，Go 的 flag 是 `ExitOnError`——端口解析失败会让整条退出，**四项一个都不生效**，面板于是停留在编译内置默认值 `admin`/`admin`、端口 2053、webBasePath `/`。安装摘要打印的却是它**打算**设置的值，具有误导性。绑回环之所以仍然生效，是因为 `install.sh:993` 是一次独立调用。
- **非交互模式强制不绑回环**（`install.sh:986-987` `bind_local="n"`，注释称云镜像需保持公网可达），必须装完手工补 `-listenIP 127.0.0.1`。
- **`x-ui uninstall` 会 `rm /etc/x-ui/ -rf`**（连数据库和全部 API token 一起删），且 `x-ui.sh` 全文对裸 Xray 的三个路径零引用——所以卸载重装不会碰 443 上那个。确认提示里的 "xray will also uninstalled" 指的是面板自带的那份。
- **`POST /panel/api/setting/update` 是全量覆盖**：它绑定整个 `AllSetting` 并调 `UpdateAllSetting`。只发单个键会把其余字段写成 Go 零值。正确用法是 `POST /setting/all` 导出 → 改一处 → 整份发回，服务端的 `preserveRedactedSecrets` 支持这种往返。
- **删除 API token 需要 `expectedScope` 参数**（`admin` / `monitor` / `node-sync`，见 `api_token.go:55-66`），空值会被 `requireExpectedScope` 拒绝。安装创建的 token 名为 `install`、scope 为 `admin`。
- **`-getApiToken` 重复调用不会吊销安装时那个 token**：已有 token 时它只重建一个名为 CLI fallback 的**另一个** token（`main.go:511-525`）。要作废 `install` 那个必须显式删除，或卸载重装。
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

### 实测结果（累积）

| 客户端 | 内核 | 自报版本 | 443（裸 26.2.6，无闸） | 44300（面板 26.7.28，门槛 26.3.27） |
| --- | --- | --- | --- | --- |
| 旧版 v2rayN | Xray（旧） | < 26.3.27 | ✅ | ❌ |
| v2rayN 7.24.9 + Xray 26.3.27 | Xray | 26.3.27 | ✅ | ✅ |
| Shadowrocket 旧版（版本号未记） | 自研 | 未知 | ✅ | ❌ |
| **Shadowrocket 2.2.92（iOS）** | **自研** | 未证实 | 未复测 | **✅（2026-09-16）** |
| v2rayNG | Xray | 取决于打包核心 | — | **未测** |
| Clash / mihomo | 自研 | **硬编码 1.8.2** | — | **未测，但原理上必失败** |
| sing-box | 自研 | **硬编码 1.8.1** | — | 未测，同上 |

mihomo 在 `component/tls/reality.go:74-76` 硬编码 `1.8.2`（Value=67586，门槛 1704219，差约 25 倍），维护者在 MetaCubeX/mihomo#2967 明确表示不会改，相关 PR #3069 / #3070 / #3094 全部 closed unmerged。**所以「要求客户端升级」这条路对 mihomo 不存在任何现存或计划中的版本。**

### 方向性更正：切到 443 会让兼容性变差，不是变好

初版把这条记成「阻塞切换」，隐含前提是「解除门槛后即可切」。**方向反了。**

机器 A 的 443 现在跑的是裸 Xray **26.2.6——早于默认门槛引入，根本没有闸**。今天 443 上 mihomo 1.8.2、sing-box 1.8.1、老版 Shadowrocket **全部能连**。切换到面板 26.7.28 之后，门槛立刻对**真实用户所在的生产端口**生效。44300 上解除的是测试端口上单个客户端的阻塞，而切换动作本身会给生产端口**新增一个此前不存在的限制**。

加上机器 A 只有 1 个客户端 UUID——**没有金丝雀、没有分批、没有回滚窗口**，切换是全量瞬时的。若管理通道本身走这条代理，切换失败会同时切断修复通道。

### 现在的选项（四个，不是两个）

| 方案 | 做法 | 代价 / 未知 |
| --- | --- | --- |
| **A. 显式设 `minClientVer`** | 给入站设 `"1.0.0"`，停留在 26.7.28 | 一次 API 调用、随库持久、不动二进制。核心会打 GFW 警告，但上游两个月后自己撤回了该默认值，这条警告的权重需重新评估 |
| **B. 换 Xray 二进制到 26.6.27 ～ 26.7.10** | 面板自带版本切换器 `POST /server/installXray/:version`（`internal/web/controller/server.go:70`，UI 在 `frontend/src/pages/index/VersionModal.tsx`，带 `.dgst` SHA256 校验，下限 v26.6.27） | 该窗口两道闸都没有。但**不持久**——下次 `x-ui update` 会被 release 钉的版本覆盖（`update.sh:1100`） |
| **C. 要求客户端升级** | — | **对 mihomo 不可行**（见上）。Shadowrocket 在中国区已下架，中国区 Apple ID 无法更新或重新下载，属用户侧不可控前置条件 |
| **D. 升级面板到 26.9.x** | — | **最差**。换成不可配置的 MLKEM768 闸；本仓库 Clash 订阅不输出 `support-x25519mlkem768`（见下）；已有 SR 2.2.92 在 26.9.9 上失败的公开报告（`Shadowrocket/config#4`、`MHSanaei/3x-ui#6543`） |

### 本仓库的一处实际缺陷（独立于迁移）

`internal/sub/clash_service.go:1067-1079` 生成的 `reality-opts` 只有 `public-key` 与 `short-id`；mihomo 需要 `support-x25519mlkem768` 这个 opt-in 才会发 MLKEM768 key_share，而**全仓库搜不到该字段**。一旦面板核心升到 ≥26.9.8，所有 Clash/mihomo 订阅用户会**静默失效**（拿到真站点证书，无有效报错）。上游在跟：`MHSanaei/3x-ui#6555`、`#6451`。这与机器 A 迁移无关，是面板自身的缺陷。

### 仍未确认的（不要当已知）

- **机器 A 面板核心的当前实际版本未在成功那一刻核实**。26.7.28 来自 2026-09-15 的记录，不是运行中二进制的输出。若期间被更新到 ≥26.9.8，默认门槛已不存在，则 Shadowrocket 2.2.92 通过与客户端升级无关，本节大量推论需重做。**这正是本文件禁止的「把旧记录当运行证据」。**
- **Shadowrocket 2.2.92 实际往 `SessionId[0:3]` 写什么字节，从未被源码或抓包证实**。2.2.91 的更新说明里有 `feat(reality): add client version setting`——是个**设置项**，默认值、UI 位置、是否需手填均无公开文档。
- **这次不是干净的 A/B**。原 A/B 固定客户端变端口，这次固定端口变客户端，两边都缺控制臂；且 2.2.90 同时带入 `support-x25519mlkem768 and consolidate reality options parsing`（REALITY 选项解析重构），升级后 profile 是否被重写未做字段级比对。
- v2rayNG 与 Clash/mihomo 在 44300 上**从未测过**。以 1/4 客户端的一次成功判定 4/4 就绪，样本不支撑。

### 解除全部未知的那一个实验（未执行）

在 **44300** 上做，不碰 443，因此非破坏性：

1. 先在机器 A 上跑 `/usr/local/x-ui/bin/xray-linux-amd64 -version`，把「服务端未漂移」变成实测而非假设；同时记 x-ui 版本与进程启动时间。
2. 给该入站的 `realitySettings` 设 `"show": true`（面板已暴露该字段，`frontend/src/pages/inbounds/form/security/reality.tsx:83-84`），这样每次连接的判定原因会进 `/var/log/x-ui/3xui.log`。
3. 做 A/B/A：`minClientVer` 依次设 `"99.99.99"` → `"1.0.0"` → 恢复空，每档都用**四个必需客户端各连一次**，逐条读日志里的 REALITY 行。`99.99.99` 下新版 Shadowrocket 若被拒则机制归属确认；`1.0.0` 下 mihomo 若通过则方案 A 同时得到验证。
4. 走 `POST /panel/api/inbounds/update/<id>`，**整行替换语义**：`privateKey`、`shortIds`、`serverNames`、`dest`、`xver` 以及 settings 里每个 client 的 `email` 必须逐字节原样回传，漏字段会被写成零值，`email` 不一致会丢失流量计数行。每次改完复核 privateKey 的 sha256 前 16 位仍为 `2a876c1641027973`。

### REALITY dest 选择标准（来自 REALITY README，供换 dest 时参考）

必要条件：国外网站、支持 TLSv1.3 与 H2、域名非跳转用（通常要用 `www.` 而非裸域）。
加分项：IP 与代理服务器相近（更像且延迟低）、Server Hello 后握手消息一起加密、OCSP Stapling。
要避开：国内站、主域名跳转的、以及**被大规模滥用的目标**——`apple`/`icloud` 正是 XTLS 点名的那一类，警告就是为它加的。

注意换 dest 会连带改 `serverNames`，而 `serverNames` 就是客户端的 `sni`——**所有客户端配置都要更新**。应作为一次独立的、计划好的变更，不要和迁移混在一起。

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

- **在 44300 上做四客户端 × 三档 `minClientVer` 的 A/B/A 实验**（步骤见「客户端兼容性硬约束 → 解除全部未知的那一个实验」）。前置第一步是核实机器 A 面板核心的**运行中版本**，不要沿用记录。这一次实验同时结算：机制归属、方案 A 是否救得回 mihomo、以及 4/4 客户端是否就绪。**这是切换决策的唯一依据。**
- **修 Clash 订阅缺 `support-x25519mlkem768`**（纯本机工作）：`internal/sub/clash_service.go:1067-1079` 的 `reality-opts` 只有 `public-key` / `short-id`。面板核心一旦到 ≥26.9.8，mihomo 订阅用户会静默失效。上游 `MHSanaei/3x-ui#6555` / `#6451`。与迁移无关，可独立推进。
- **评估并移植三个上游安全补丁**（纯本机工作，不需要服务器）：`a31fa9abfa`（节点跨入站污染客户端凭据，GHSA-rr44-v4rv-x654——注册机器 B 为节点正是触发该问题的配置，所以这条最紧急）、`23511108bf`（数据目录 0700 / DB 0600，带测试）、`f294e1806d`（安装更新校验 SHA256 sidecar）。这是 S2 的前置条件。
- 机器 B 装 3x-ui（改 apt 源即可，不必等重装）。

**被阻塞：**

- 机器 A 切换到 443 → 阻塞于**四个必需客户端未全部验收**。注意这不再是「等门槛解除」：443 现在的裸 26.2.6 无闸，切换本身会新增限制，所以必须先证明目标状态下 4/4 都通，再切。
- 机器 B 重装系统 → 阻塞于服务商面板故障（工单待提交）。
- S1 实验 3（节点失联收敛）→ 阻塞于第二个节点尚未就绪。
- S3 共享额度实现 → 阻塞于连接控制方向未定。

**已知但优先级待定：**

- 换 dest 离开 `www.apple.com`（XTLS 点名的高风险目标）。若最终选方案 A（显式设 `minClientVer`），此项优先级上升，因为届时会同时背两条 REALITY 风险警告——但上游已自行撤回该默认值，这条警告的实际权重需重新评估。注意换 dest 连带改 `serverNames` = 所有客户端的 `sni`，必须作为独立变更计划。
- 机器 A 的 `xray.service` 仍是 `User=root` 且降权三行被注释（恢复自备份）。机器 B 那台是 `nobody` + `AmbientCapabilities`，可直接照抄。
