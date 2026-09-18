# 节点侧断流设计

> 状态：**主线已定（用户，2026-09-18）；已并入一轮对抗评审的更正（三路对照 v3.8.5 源码）。待第 7 节实验后细化为实施计划。**
> 前置：[S3 定向断连实现计划](../plans/2026-09-18-s3-targeted-disconnect.md)（本机 `DropUser`）。本设计复用它，不重复它。
> 背景事实：handoff「多节点架构、范围决定与现状核实（2026-09-18）」一节。
>
> **用户已决定：**
> 1. master 向节点下发客户端停用时**按用户操作**，不再重推整个入站。节点侧只做 `AlterInbound` + `RemoveUserOperation`，同入站其他用户不受影响。
> 2. **对账也改成按用户下发**（讨论中的「补法 (b)」，而不是在节点侧接住整入站推送的补法 (a)）。
> 3. **保留状态推送**：master 定时把所有用户的状态推给所有节点（第 4.1 节）。

## 1. 要解决的问题

用户确认的要求：master 判定用户 A 用尽后，**所有节点断开 A 的全部连接**，且必须**立即断开已开连接**；master **定时**告知各节点谁仍可用。

S3 计划只做本机：把 `inbound_traffic_apply.go:111` 从 `RemoveUser` 改成 `DropUser`（`RemoveUser` + `SOCK_DESTROY`）。但 `SOCK_DESTROY` 只能销毁**它所在那台机器**内核里的 socket：用户连在远程节点上时 master 够不着，必须由节点自己执行；「独立面板服务器」拓扑下 master 本机不承载任何用户，**S3 本机断流一个人都断不掉**。所以只要要多节点、又要立即断，节点侧断流就必须进第一版。

**范围：Xray-core 协议**（VLESS / VMess / Trojan / Shadowsocks / Hysteria）。MTProto、AmneziaWG、TUIC 在 `inbound_traffic_apply.go:93-104` 就分流到各自的 `applyLocal*`，根本不经过 `:111`，S3 与本设计都不覆盖。

## 2. 现状：谁先把 A 停掉，以及为什么不断流

v3.8.5 里 A 在节点上被停用，先后**取决于 A 的流量是否分散在多个节点**：

- **只在一个节点上用流量：** 该节点本地计数就是合计，且比 master 拉到的领先一个同步周期。节点本地判定通常先触发，**节点本机的 `:111` 会执行**——S3 在这里就能断流。
- **分散在多个节点：** 每个节点的本地份额都没到额度，只有 master 的合计到了。master 在越过额度的那一轮先调 `AddTraffic` 停用并推送（`node_traffic_sync_job.go:137`），而那条推送是**整入站** `rt.UpdateInbound`：节点执行 `UpdateInbound` → `UpdateClientStat` 置 `enable=false` → `DelInbound + AddInbound`。节点下一轮只选 `enable = true` 的客户端（`inbound_disable.go:86`），**`:111` 永远不会为 A 执行**，A 的已开连接不会被杀。

此外，master 的对账 `ReconcileNode`（`inbound_node.go:104`）逐入站调 `ReconcileInbound`（`remote.go:488`）：按内存里的指纹 `pushedFP` 判断是否变化，变了就**整入站**推送。`pushedFP` 只在内存里，**master 重启后为空，第一次对账会把每个入站整个重推一遍**。

## 3. 设计规则

**节点上，一个凭据在某次更新前由 Xray 服务、更新后不再服务，就视为「离开且不回来」，立即断开它的连接。不论触发原因。**

- **不按原因区分。** 已批准设计（spec:33、spec:61）要求管理员停用、到期也都要切断已开连接；S3 计划也把批量管理员停用接到了 `DropUser`。所以不需要「停用原因」字段——初稿要求「只有因额度停用才断流」，那会让被管理员停用的人继续连着，违反已批准设计，已删除。
- **按凭据判断，不按 email、也不按 `ClientRecord`。** 凭据指 VLESS / VMess 的 `id`、Trojan / Shadowsocks 的 `password`、Hysteria 的 `auth`。不能用 email：改名是「移除旧 email、加回新 email、凭据不变」，按 email 会把改名当成离开——上游 `DropsUsers()`（`internal/xray/hot_diff.go:38-54`）就是这么错的。也不能用 `ClientRecord`：它按 email 建唯一索引（`model.go:919`），节点上一次改名会产生新行。
- 由此：改名、改备注、调额度（凭据仍在服务）不断；停用、删除、解绑（凭据不再服务）都断。

## 4. 设计

### 4.1 两种推送

| | 内容 | 频率 | 作用 |
| --- | --- | --- | --- |
| **事件推送** | master 判定某用户停用 / 删除 / 恢复，立即按用户下发到其所在的每个节点 | 事件发生时 | **快**：约 10–12 秒内所有节点断开 |
| **状态推送 ①：用量**（已有，保留不改） | 每个用户跨节点的合计用量（`maybePushGlobals` → `PushGlobalClientTraffics`，`remote.go:799`） | 每 30 秒 | 节点据此**自己判定**谁没流量：master 的事件丢了、或 master 宕机，节点照样能停 |
| **状态推送 ②：启停收敛**（新增，即补法 b） | master 把自己库里每个用户的启停状态与节点实际状态对齐，差异按用户下发 | 每 30 秒，外加节点被标脏时 | **不漏**：丢失的事件、节点被本地改动、master 重启后，都在一个周期内纠正 |

**状态推送 ② 只推差异，效果等同「把所有用户推一遍」。** master 每 5 秒经 `FetchTrafficSnapshot`（`remote.go:751`）拉取每个节点的 `panel/api/inbounds/list`，其中含完整的客户端列表与每人的启停状态，所以 master 随时知道节点的真实状态。逐人重推未变的用户，会让每个节点每 30 秒为每个用户做一次数据库写入和 Xray 的 `RemoveUser` + `AddUser`，并与单写者争用；只推差异，结果完全相同。

`nodeGlobalPushInterval` 保持 30 秒：断流延迟来自事件推送，与推送间隔无关。

### 4.2 对账改成按用户（补法 b）

把 `ReconcileInbound` 拆成两层，比较基准从「内存指纹」改为「节点快照里的实际内容」：

- **入站级字段**（除客户端列表外的一切：监听、端口、协议、`streamSettings`、REALITY、sniffing 等）与节点实际不同 → 整入站推送。这只在管理员改入站本身时发生，不可避免。
- **只有客户端列表不同** → 逐个按用户下发：
  - 节点上缺 → `Remote.AddClient`；
  - 节点上多 → `Remote.DeleteUser`（节点落到 `client_inbound_apply.go:1217`，S3 已接 `DropUser`）；
  - 两边都有但字段不同 → `Remote.UpdateUser`（节点落到 `:1021-1029`，见 4.3）。
- **比较基准是节点快照**，所以 master 重启后不再触发整入站重推；内存指纹只保留为「未变则跳过」的快速路径。每次按用户推送成功后调现成的 `AdvancePushedInbound`（`remote.go:545`）。
- **比较时用与整入站推送相同的构造**（`buildInboundForNodePush`，含 fallbacks），否则 fallbacks 这类构造差异会被误判为入站级变化。
- **同一函数两处调用：** 节点被标脏时（现有，`node_traffic_sync_job.go:370`）；每 30 秒一次（状态推送 ②）。

**方向约束（必须遵守，否则与现有逻辑打架）：**

- **节点自己的真实停用不能被收敛「推回启用」。** 节点按与 master 相同的限额判定停用时，这个结论会锁存回 master（#4917，现有 `nodeDisableIsStale`，`inbound_node.go:253`）。收敛只在 master 的限额已变（重置、提额、延期）即节点的停用已过时，才向节点下发启用。
- **刚推送过的用户这一轮不再比较。** 快照可能早于刚完成的推送（#6228，现有 `justPushed`），直接比较会重复推送。

### 4.3 节点侧挂钩

| 来源 | 节点上的落点 | 挂钩 |
| --- | --- | --- |
| 节点自行判定（本地或合计超额） | `inbound_traffic_apply.go:111` | S3 已改为 `DropUser` |
| master 按用户停用（事件推送或收敛） | `client_inbound_apply.go:1021-1029` | `if oldClients[clientIndex].Enable && !clients[0].Enable { DropUser } else { RemoveUser }` |
| master 按用户删除 / 解绑 | `client_inbound_apply.go:1217` / `:234` | S3 已改为 `DropUser` |
| master 整入站推送（仅入站级字段变化） | 节点 `InboundService.UpdateInbound` | 不挂钩，见 4.4 |

- 第二行的判据来自同一条目（经 `oldEmail` 与 `clientIndex` 定位），改名安全；纯编辑（`enable` 不变）仍走 `RemoveUser`，S3 的 `TestEditPathStillUsesRemoveUserNotDropUser` 依然有意义。
- **`DropUser` 应把 `RemoveUser` 的「找不到」当作继续销毁 socket**，而不是提前返回（S3 计划 532-535 行目前是返回）。用户可能已被别的路径移出 Xray，但连接还在。
- **排除的挂钩位置：** `UpdateClientStat` 是按 email 的盲写 `UPDATE`，从不读旧的 `enable`，改名时整个被跳过；`hot_diff.go` 的 `RemovedUsers` 不带凭据、按 email 标识，且节点的 `UpdateInbound` 根本不经过它。

### 4.4 剩下的整入站推送

按用户下发之后，整入站推送只剩「管理员改入站本身」一种来源。

- 若同一次保存**也停用或删除了客户端**，master 先按用户下发这些离开，再推整入站——离开的人由 4.3 断流，不依赖整入站删建的副作用。
- 整入站删建本身是否断开该入站**所有人**的已开连接，是实验 1。若是：改端口、换 REALITY 密钥本来就影响全部用户，可接受，但要在界面上说明。

### 4.5 master 侧其它改动

- **停用按用户下发（已决定）。** `disableInvalidClients` 为节点入站构造的远端计划（`inbound_disable.go:135-146` → `applyTrafficRemotePlans`，`inbound_traffic_apply.go:62-84`）从 `rt.UpdateInbound` 改为 `Remote.UpdateUser`，成功后调 `AdvancePushedInbound`。
- **关闭 `restartXrayOnClientDisable`**（S3 计划 Task 7），在 master 与每个节点上都要关。
- S3 计划的 Task 5「`Remote.DropUser` 告警桩」不再需要：master 对远程节点不直接下断流命令，而是下发状态变化，由节点断流。

### 4.6 恢复（月度重置 / 提额）

- **在 `ResetTrafficByEmail`（`client_traffic.go:15-56`）里调换顺序：** 先逐入站清零，再 `Update(Enable=true)`，作为**两次先后执行的串行写入**。不能嵌套进同一个写入序列：`ClientService.Update → UpdateInboundClient → runSerializedTx` 嵌在 `submitTrafficWrite` 里会让单写者死锁。这个函数经 `clients/resetTraffic` 在节点上也会执行，一处改动同时修好 master 与节点。
- **第一版必须用客户端级周期**（`resetClientsOnTheirOwnCycle → ResetTrafficByEmail`）。入站级周期不会恢复因额度被停用的客户端。
- **残留情形一：** 清零之后 `Update` 若失败，客户端停留在「停用且用量 0」，会被读作管理员停用。要大声记日志。
- **残留情形二（状态收敛要处理）：** 重置向某个节点的传播失败时，该节点本地计数仍高：收敛推去的启用会被节点立刻再次停用，而且因限额未变，这个停用会按 #4917 锁存回 master，用户被锁死。所以**重置也要纳入收敛**：master 发现节点上某用户的本地计数与自己的重置不一致时，重发 `ResetClientTraffic`，再下发启用。判据在实施计划里定，实验 5 覆盖。

### 4.7 与账户层的关系

按已批准设计，额度属于**账户**，一个账户可有多个 `ClientRecord`。账户层落地后：账户耗尽 → master 对其名下所有凭据、在所有节点上按用户下发停用。节点侧规则（第 3 节）不变，仍按凭据执行。

## 5. 补法 (a) 与 (b) 的取舍

| | (a) 节点侧接住整入站推送 | (b) 对账改成按用户（采用） |
| --- | --- | --- |
| 改动位置 | 节点 `UpdateInbound`：事务内算出「不再服务」的凭据，在 `DelInbound` 之前断流 | master `ReconcileInbound`：拆成入站级与客户端级两层 |
| 同入站其他人 | 仍经历整入站删建（是否受影响取决于实验 1） | 不受影响 |
| master 重启后 | 每个入站仍被整个重推一次 | 按节点快照比较，不再整个重推 |
| 改动量 | 小 | 大：一次重构 |

评审曾因改动量建议 (a)。用户选择 (b)：它从根上消除「为停用某一人而删建整个入站」，与「按用户外科手术式」一致，也顺带满足「定时把所有用户状态推一遍」。

## 6. 限制与遗留（不在本设计内解决）

- **按 IP 杀，同出口 IP 连带**：决定 ③ 不变；每次销毁前检测同 IP 多 email 并记日志（必做项）。
- **秒级延迟，非字节级硬上限**：约 10–12 秒，设计文档本已写明不承诺字节级上限。
- **master 宕机期间：** 冻结的 `client_global_traffics` 只拦得住**宕机那一刻已经超额**的用户；其他人从第一秒起就只受各节点本地计数约束，每个账户最坏可超用 **(N−1) 份额度**，两节点即多用一整份。24 小时新鲜度窗口不改变这一点（初稿「节点按最后合计继续执行 24 小时」的说法有误）。
- **每个节点必须**：跑本 fork；内核开 `CONFIG_INET_DIAG_DESTROY`；面板进程有 `CAP_NET_ADMIN`。机器 A 实测满足，其它节点逐台核实。
- **全局用量按 email 字节精确匹配**：email 大小写风险面（handoff 同名一节）在此同样成立，依赖「全小写不透明 handle」约定。
- **MTProto / AmneziaWG / TUIC 不在范围内**（见第 1 节）。

## 7. 前置实验

实验 1–5 可在本机 WSL 起两个面板完成（方法见 handoff「加速」一段）；只有实验 6 需要真实 Linux 节点。

1. **整入站 `DelInbound + AddInbound` 对同入站其他用户已开连接的影响。** 决定 4.4 要不要在界面上提示；也决定机器 A 当前的 v3.7.0（仍用整入站推送停用）是否正在误伤。
2. **谁先停用：** 流量分散于两节点的用户（预期 master 先到）与只在单节点上的用户（预期节点 `:111` 先执行）各测一次。
3. **按用户停用 → 节点 `:1021-1029` 挂钩 → `DropUser`**（不含 `SOCK_DESTROY`；验证改名、调额度不误伤）。
4. **按用户对账：** 下发时让节点不可达，恢复后收敛按用户补发；重启 master 后确认不再整入站重推；在节点上手工改一个用户的启停，确认 30 秒内被纠正。
5. **重置：** 调序后不再被重新停用；重置向节点的传播失败时，收敛能否补上而不锁死用户。
6. **在真实远程节点上 `SOCK_DESTROY`**：需要第二台真实 Linux 机器，或临时把机器 A 注册为某个 master 的节点。

## 8. 还需用户决定的一项

**master 宕机期间的超用：** 宕机期间每个账户最坏可多用 (N−1) 份额度（两节点即一整份），可以接受吗？若不能接受，需要为「master 失联」另行设计机制（代码里没有现成的）。

## 9. 相对 S3 计划新增的工作

S3 计划本身**原样复用**（它在每个节点上都生效），去掉其 Task 5。新增：

1. 节点 `client_inbound_apply.go:1021-1029`：`enable` 由 true 变 false 时 `DropUser`，否则 `RemoveUser`。
2. `DropUser` 对「`RemoveUser` 找不到」的容忍。
3. master `disableInvalidClients` 的节点远端计划改为 `Remote.UpdateUser`，成功后 `AdvancePushedInbound`。
4. master `ReconcileInbound` 拆成两层，按节点快照比较，客户端差异按用户下发（4.2），含两条方向约束。
5. 每 30 秒的启停收敛（状态推送 ②），与标脏对账共用第 4 项。
6. 管理员改入站时，先按用户下发离开，再推整入站（4.4）。
7. `ResetTrafficByEmail` 调序；重置纳入收敛（4.6）。
8. 以上各项的测试，以及第 7 节的实验记录。

**初稿中已删除：** 停用原因字段及其迁移、`nodeGlobalPushInterval` 调快、重置后立即补推、节点侧恢复对账。
