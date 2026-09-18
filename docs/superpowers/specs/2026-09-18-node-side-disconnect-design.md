# 节点侧断流设计

> 状态：**主线已定：补法 (a)（用户，2026-09-18）。实验 1 已在本机 WSL 实测。经两轮对抗评审（对照 v3.8.5 源码与 Xray 26.7.28 源码）。待细化为实施计划。**
> 前置：[S3 定向断连实现计划](../plans/2026-09-18-s3-targeted-disconnect.md)（本机 `DropUser`）。本设计复用它，不重复它。
> 背景事实：handoff「多节点架构、范围决定与现状核实（2026-09-18）」一节。
>
> **用户已决定（2026-09-18）：**
> 1. **采用补法 (a)：节点在处理整入站更新时，自己算出谁不再被服务并断流。** master 的推送方式保持 v3.8.5 原样（额度停用仍是整入站推送），不新增按用户推送，不重构对账。
> 2. **撤回同日早些时候「master 停用按用户下发」的决定。** 那个决定是为了避免整入站删建误伤同入站其他人；实验 1 证明删建不断开任何已开连接，理由不再成立。
> 3. **断流时限：30 秒内可以接受。**
> 4. **用量推送保持每 30 秒一次**，只作兜底。
> 5. **master 宕机期间允许用户多用**：每个账户最坏多用 (N−1) 份额度，不为「master 失联」另建机制。
> 6. **删除整个入站时不断流，第一版不加挂钩**；部署约定入站不设总流量与到期时间（第 6 节）。

## 1. 要解决的问题

用户要求：master 判定用户 A 用尽后，**所有节点断开 A 的全部连接**，且必须**断开已开连接**（30 秒内）；同入站的其他人不受影响。

S3 计划只做本机：把 `inbound_traffic_apply.go:111` 从 `RemoveUser` 改成 `DropUser`（`RemoveUser` + `SOCK_DESTROY`）。`SOCK_DESTROY` 只能销毁**它所在那台机器**内核里的 socket：用户连在远程节点上时 master 够不着，必须由节点自己执行；「独立面板服务器」拓扑下 master 本机不承载任何用户，**S3 本机断流一个人都断不掉**。所以节点侧断流必须进第一版。

**范围：Xray-core 协议**（VLESS / VMess / Trojan / Shadowsocks / Hysteria）。MTProto、AmneziaWG、TUIC 在 `inbound_traffic_apply.go:93-104` 分流到各自的 `applyLocal*`，节点 `UpdateInbound` 的 MTProto/TUIC 分支（`inbound.go:1898-1925`）也不调用 `DelInbound`，本设计不覆盖。

## 2. 实验 1：整入站更新不会断开任何已开连接（2026-09-18 实测）

**方法。** 本机 WSL 开发面板，Xray 26.7.28 `5ca6f4b`（与机器 A 同版本）。建临时入站：VLESS + REALITY + Vision，两个用户 A、B。客户端是两个独立的 Xray 进程，各开一条 60 秒的慢速下载（每 0.5 秒一行带时间戳）。下载进行中，经面板 API 对该入站做两次整入站更新：第一次把 A 停用（等同 master 的额度停用推送），第二次只改备注（等同对账重推）。

| 观察 | 结果 |
| --- | --- |
| 真的删建了入站 | 是：面板日志两次「Old inbound deleted / Updated inbound added」；监听 socket 的 inode 两次改变 |
| Xray 是否重启 | 否，进程号不变 |
| 更新后 Xray 里的用户 | 只剩 B |
| 更新后 A / B 的**新**连接 | A 被拒，B 正常 |
| **B 的已开下载**（同入站其他人） | **完好**：120/120 行，最长间隔 0.55 秒 |
| **A 的已开下载**（被停用的人） | **也完好**：120/120 行，最长间隔 0.54 秒 |

**源码印证**（评审逐行核对 Xray 26.7.28）：删入站只关监听 socket 和入站的处理对象（`app/proxyman/inbound/always.go:190-201`、`worker.go:151-166`、`transport/internet/tcp/hub.go:139-141`）；已接受的连接各自跑在独立协程里，上下文来自 Xray 启动时的 `context.Background()`（`worker.go:62`、`core/xray.go:168`），删入站时无人取消；REALITY 同样（`reality.go:53`）。VLESS 的 `Close` 不清空用户表（`proxy/vless/inbound/inbound.go:229-237`）。`AlterInbound` + `RemoveUserOperation` 只删用户表里的一项（`validator.go:47-58`），同样不断已开连接。

**结论：**
- 整入站删建**不误伤**同入站其他人。选 (a) 的前提成立。
- 整入站删建**也不断开**被停用的人。Xray 自己从不断开已开连接，**每一条停用路径都必须由节点主动销毁 socket**。
- 已开连接只会在两端关闭、出错或空闲超时时结束：默认空闲 300 秒，Vision splice 状态下 24 小时（`proxy/proxy.go:756-758`）。

**实验的局限：** 回环网络；内层是明文 HTTP，Vision 没有进入 splice（splice 状态的连接与 Xray 的耦合更少，结论只会更成立）。每次删建之间有几毫秒没有监听，这期间的新连接被拒、未被接走的排队连接被重置（推断），客户端会自动重连。

**实验中踩到的两个坑**（重做时注意）：WSL 的 `no_proxy` 含 `localhost`，curl 会绕过 SOCKS 直连，必须清掉代理变量；3x-ui 默认 freedom 出站的 `finalRules` 屏蔽私有地址，删掉该字段也仍按内置默认屏蔽，必须显式写成 `[{"action":"allow"}]`。脚本见本次会话 scratchpad `exp1/run.sh`，结束时恢复模板并删除临时入站。

## 3. 设计规则

**节点上，一个凭据在某次更新前由 Xray 服务、更新后不再服务，就视为「离开且不回来」，立即断开它的连接。不论触发原因。**

- **不按原因区分。** 已批准设计（spec:33、spec:61）要求管理员停用、到期也都要切断已开连接；S3 计划也把批量管理员停用接到了 `DropUser`。所以不需要「停用原因」字段。
- **按凭据判断，不按 email、也不按 `ClientRecord`。** 凭据指 VLESS / VMess 的 `id`、Trojan / Shadowsocks 的 `password`、Hysteria 的 `auth`。改名是「移除旧 email、加回新 email、凭据不变」，按 email 会把改名当成离开——上游 `DropsUsers()`（`internal/xray/hot_diff.go:38-54`）就是这么错的。`ClientRecord` 按 email 建唯一索引（`model.go:919`），节点上一次改名会产生新行，也不能用。
- 由此：改名、改备注、调额度不断；停用、删除、解绑、更换凭据都断。

## 4. 设计

### 4.1 断流靠哪次推送触发：master 已有的整入站推送

| 路径 | 内容 | 时效（从真正超额算起，按代码推算） |
| --- | --- | --- |
| **主路径**（v3.8.5 已有，不改） | master 每 5 秒拉一次节点用量；合计越过额度的那一轮，`AddTraffic`（`node_traffic_sync_job.go:137`）就停用该用户，并立即把**整个入站**推给每个承载它的节点（`inbound_disable.go:135-145` → `inbound_traffic.go:40` → `inbound_traffic_apply.go:71`，超时 4 秒） | 约 10–15 秒 |
| **失败重试**（已有） | 推送失败时节点在同一事务里被标脏（`inbound_traffic.go:92`），下一轮 `ReconcileNode`（`node_traffic_sync_job.go:370-372`）再整入站推送；指纹只在成功后记录（`remote.go:462-469`），所以会一直重试 | 每 5 秒一次 |
| **兜底**（已有，保持 30 秒） | 用量推送（`maybePushGlobals` → `PushGlobalClientTraffics`，`remote.go:799`），节点据合计自己判定，经 `:111` 停用 | 最坏约 40–46 秒；只在节点持续拒收入站更新、却仍接收用量推送时才起作用 |

主路径满足 30 秒要求。**不需要**新增按用户推送，也**不需要**把用量推送调快。

### 4.2 节点侧挂钩：所有停用落点都要断流

| 来源 | 节点上的落点 | 挂钩 |
| --- | --- | --- |
| master 的整入站推送：额度（流量分散在多个节点的用户）、到期、对账重推、超过 32 人的批量操作、管理员改入站、入站开关 | 节点 `InboundService.UpdateInbound`（`inbound.go:1679`），`NodeID == nil` 分支 | **补法 (a)，本设计新增**，见 4.3 |
| 节点自行判定（只在一个节点上用流量的人；兜底路径） | `inbound_traffic_apply.go:111` | S3 已改为 `DropUser` |
| master 按用户推送的管理员停用：单个停用、Telegram 机器人开关、32 人以内的批量停用、更换凭据 | `client_inbound_apply.go:1021-1029` | **本设计新增一行判断**，见 4.4 |
| master 按用户推送的删除 / 解绑（32 人以内） | `client_inbound_apply.go:1217` / `:234`；批量在 `client_bulk.go:1214`、`:1812` | S3 已改为 `DropUser` |

**(a) 与 `:111` 两个都要。** 谁先停用，另一个就看不到变化：
- 流量分散在多个节点时，master 的推送先到，节点的 `client_traffics.enable` 已被置 false，节点自己的检查只选 `enable = true` 的行（`inbound_disable.go:86`），**`:111` 永远不会执行**——只能靠 (a)。
- 只在一个节点上用流量时，节点本地计数领先，节点先经 `:111` 停用并改写自己的设置（`inbound_disable.go:135`）；master 随后的推送在节点看来「更新前就已停用」，**(a) 的差集为空**——只能靠 `:111`。

### 4.3 补法 (a) 的实现要点

- **「更新前在服务」的集合必须在 `inbound.go:1768` 之前取。** `updateClientTraffics` 在那里就会改写 `enable` 并删除被移除客户端的行；`oldSnapshot`（`:1926`）复制时 Settings 已经是新的，不能当「更新前」。
- **「在服务」按运行时的过滤规则算**（`inbound.go:2074-2079`）：settings 里 `enable` 为 true，并且 `client_traffics.enable` 不是 false。
- **断流用旧 email 与旧快照**（旧 tag、旧端口）：在线表按旧 email 记录连接，socket 落在旧端口上。
- **顺序必须是：先对旧 tag 调 `rt.RemoveUser` → 再销毁 socket → 最后 `DelInbound + AddInbound`。** 旧监听在删建之前还开着，它已接受但尚未解析完 VLESS 头的连接，会用旧的用户表认证通过（`hub.go:116-128`；`Close` 不清空用户表）；先移除用户，这些握手就会失败。
- **风险：(a) 会把 master 与节点之间的任何差异都变成断连。** 例如 master 因 `clientEmailsOwnedElsewhere`（`inbound_node.go:1241-1261`）或墓碑记录过滤掉的客户端，一次整入站推送就会被真的踢下线。实施时要有测试确认 master 推出的客户端列表等于应服务的人。

### 4.4 `:1021` 挂钩

把 `client_inbound_apply.go:1021-1029` 的按用户移除改为：

```
if oldClients[clientIndex].Enable && (!clients[0].Enable || 凭据变了) { DropUser } else { RemoveUser }
```

- 判据来自同一条目（经 `oldEmail` 与 `clientIndex` 定位），改名安全；纯编辑仍走 `RemoveUser`，S3 的 `TestEditPathStillUsesRemoveUserNotDropUser` 依然有意义。
- **今天这个缺口被默认配置掩盖了。** `restartXrayOnClientDisable` 默认开（`setting.go:172`），`:1026-1028` 会要求重启，`restartToDropClients`（`xray.go:1431-1442`）随后重启整个核心：被停用的人确实断了，但节点上所有人一起断。S3 Task 7 关掉开关后，这个缺口就露出来了。

### 4.5 其它改动

- **`DropUser` 应把 `RemoveUser` 的「找不到」当作继续销毁 socket**，而不是提前返回（S3 计划 532-535 行目前是返回）。
- **`restartXrayOnClientDisable` 必须在 master 和每个节点上都关掉。** 开着时 master 会强制重启节点的整个 Xray（`inbound_traffic.go:41-43` → `inbound_node.go:1379-1405`），节点也会自己重启（`xray_traffic_job.go:90-100`），所有人断线。**S3 Task 7 只改新数据库的默认值，已有面板数据库里存的旧值不变，要逐台显式关掉。**
- master 的推送方式、`ReconcileNode`、`nodeGlobalPushInterval` 都不改。S3 计划的 Task 5「`Remote.DropUser` 告警桩」不再需要。

### 4.6 恢复（月度重置 / 提额）

- **在 `ResetTrafficByEmail`（`client_traffic.go:15-56`）里调换顺序：** 先逐入站清零，再 `Update(Enable=true)`，作为**两次先后执行的串行写入**。不能嵌进同一个写入序列：`ClientService.Update → UpdateInboundClient → runSerializedTx` 嵌在 `submitTrafficWrite` 里会让单写者死锁。这个函数经 `clients/resetTraffic` 在节点上也会执行，一处改动同时修好 master 与节点。
- **第一版必须用客户端级周期**（`resetClientsOnTheirOwnCycle → ResetTrafficByEmail`）。入站级周期不会恢复因额度被停用的客户端。
- **残留情形一：** 清零之后 `Update` 若失败，客户端停留在「停用且用量 0」，会被读作管理员停用。要大声记日志。
- **残留情形二（已知缺口，实施计划处理）：** 重置向某个节点的传播失败时，该节点本地计数仍高：master 推去的启用会被节点立刻再次停用，而且因限额未变，这个停用会按 #4917 锁存回 master，用户被锁死。

### 4.7 与账户层的关系

按已批准设计，额度属于**账户**，一个账户可有多个 `ClientRecord`。账户层落地后：账户耗尽 → master 停用其名下所有凭据 → 经上面同样的推送与挂钩在所有节点断流。节点侧规则（第 3 节）不变。

## 5. 为什么选 (a) 而不是 (b)

| | (a) 节点接住整入站推送（采用） | (b) 对账改成按用户 |
| --- | --- | --- |
| 同入站其他人 | 不受影响（实验 1） | 不受影响 |
| 30 秒时限 | 满足（约 10–15 秒） | 满足 |
| master 端改动 | 基本不改，只关重启开关 | 重构 `ReconcileInbound` 为两层，新增启停收敛 |
| 节点端挂钩 | (a) + `:111` + `:1021` + `:1217` | `:111` + `:1021` + `:1217`（省掉 (a)） |
| 每次停用的副作用 | 该入站有几毫秒不接受新连接，客户端自动重连 | 无 |

两者都满足需求，(a) 改动小得多，符合 CLAUDE.md「改动幅度匹配问题幅度」。**会让结论翻转的情况：** 今后若发现整入站删建会断开已开连接（例如换了 Xray 版本或内层进入 splice 后表现不同），(b) 就又是必需的。

## 6. 限制与遗留

- **删除整个入站不断流（用户决定：第一版不加挂钩）。** 会删除整个入站的只有三种情况：
  1. 管理员在 master 上删入站（`inbound.go:1391`）；
  2. 情况 1 发生时节点连不上，恢复后 `ReconcileNode` 清理多余标签（`inbound_node.go:199`）；
  3. 入站自身设了总流量或到期时间，用完或到期后被自动删除（`inbound_disable.go:14-33` → `inbound_traffic_apply.go:116`）。

  里面的已开连接会继续跑到空闲超时：平时 300 秒，Vision splice 状态下最长 24 小时，期间流量仍计在该用户名下。不加挂钩的理由：
  - 与「流量用完就断」无关：用完流量走的都是用户级路径，已全部覆盖；
  - 情况 1、2 是管理员主动操作，受影响的是仍有额度的正常用户；
  - **部署约定：入站不设总流量与到期时间**（额度按用户 / 账户算），情况 3 就不会触发；
  - **需要立即断开时的手工办法：** 删完入站后在节点上重启一次 Xray，所有人自动重连。

  另两种看似删入站、其实不是缺口：在 master 上关掉节点入站的开关，推到节点走整入站更新，由 (a) 接住；`DelDepletedClients`（`inbound_traffic.go:880`，删光耗尽用户后连入站一起删）当前没有任何调用方。今后若要补，改动很小：节点删入站时，把该入站的全部凭据交给 (a) 的同一套断流逻辑。
- **Vision splice 期间的下行流量要等 splice 结束才计入**（`proxy/proxy.go:760-769`）：一条长时间 splice 的下载在结束之前对额度检测不可见，与推送设计无关（S1 实验文档已记录）。
- **按 IP 杀，同出口 IP 连带**：决定 ③ 不变；每次销毁前检测同 IP 多 email 并记日志（必做项）。
- **master 宕机期间（用户决定：允许多用）：** 冻结的 `client_global_traffics` 只拦得住宕机那一刻已经超额的用户；其他人从第一秒起只受各节点本地计数约束，每个账户最坏可超用 **(N−1) 份额度**，两节点即多用一整份。不为「master 失联」另建机制。
- **每个节点必须**：跑本 fork；内核开 `CONFIG_INET_DIAG_DESTROY`；面板进程有 `CAP_NET_ADMIN`；`restartXrayOnClientDisable` 已关。
- **全局用量按 email 字节精确匹配**：依赖「全小写不透明 handle」约定。
- **MTProto / AmneziaWG / TUIC 不在范围内**（见第 1 节）。

## 7. 其余实验

均可在本机 WSL 起两个面板完成，只有第 5 项需要真实 Linux 节点（WSL2 内核未开 `CONFIG_INET_DIAG_DESTROY`）。

1. **谁先停用：** 流量分散于两节点的用户（预期 master 先推、节点走 (a)）与只在单节点上的用户（预期节点先走 `:111`）各测一次。
2. **(a) 与 `:1021` 的挂钩选人**（不含 `SOCK_DESTROY`）：只选中不再服务的凭据；改名、调额度不误选。
3. **对账路径：** 按停用推送时让节点不可达，恢复后 `ReconcileNode` 整入站重推，确认 (a) 接住。
4. **重置：** 调序后不再被重新停用；重置向节点的传播失败时的表现（4.6 残留情形二）。
5. **在真实远程节点上 `SOCK_DESTROY`**：需要第二台真实 Linux 机器，或临时把机器 A 注册为某个 master 的节点。

## 8. 用户决定（2026-09-18，均已定）

1. **master 宕机期间允许用户多用**，每个账户最坏多用 (N−1) 份额度。
2. **删除整个入站时不断流，第一版不加挂钩**，理由与手工办法见第 6 节。

本设计已无待决项。

## 9. 相对 S3 计划新增的工作

S3 计划**原样复用**（它在每个节点上都生效），去掉其 Task 5。新增：

1. 节点 `InboundService.UpdateInbound` 的补法 (a) 挂钩（4.3）。
2. 节点 `client_inbound_apply.go:1021-1029` 的判断（4.4）。
3. `DropUser` 对「`RemoveUser` 找不到」的容忍。
4. `ResetTrafficByEmail` 调序（4.6）。
5. 部署清单：每个面板显式关闭 `restartXrayOnClientDisable`；入站不设总流量与到期时间。
6. 以上各项的测试，以及第 7 节的实验记录。

**不做：** 按用户的停用推送、对账重构、启停收敛、停用原因字段、推送间隔调快、重置后补推、节点侧恢复对账。
