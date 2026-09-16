# Xray 账户管理 S1 实验记录（实验 1 与 2a）

承接 [S0 基线验证记录](2026-09-11-xray-account-baseline.md) 与 [S0 计划](../plans/2026-09-11-xray-account-baseline-validation.md) Task 4 Step 3 锁定的 S1 范围。
只记录已实际执行的内容。实验 3（节点失联收敛）需要第二个节点，尚未执行。

## 执行标识

| 项 | 值 |
| --- | --- |
| 执行日期 | 2026-09-14 |
| 分支 | `codex/xray-account` |
| 执行时 HEAD | `208c122`（S0 记录提交） |
| 源码基线 | `f727d04f6522bb94a8fb52e8352fdcafb51c11e1`（v3.7.0） |
| 执行平台 | Windows 11 / amd64，Go 1.27.0，CGO gcc 16.1.0 |
| 真实核心 | 由 `go.mod` 固定模块自编，自报 `Xray 26.7.28`，SHA256 `91291EB0…8C3F65` |

**平台偏差**：计划设想在 Linux 节点上执行，实际在本机 Windows 完成。核心是同一个固定版本，被测代码是平台无关的 Go，但**这不等于已在目标 Linux 节点验证**。节点复跑仍属未覆盖。

---

## 实验 1：数据库提交失败后增量是否丢失

**结论：丢失，且无任何错误信号。**

### 方法

探针 `testdata/s1-exp1-traffic-delta-loss/traffic_delta_loss_probe_test.go`，在 `internal/web/service` 包内运行：

1. 用脚本化的 fake Stats gRPC 服务驱动 `XrayAPI.GetTraffic()`
2. 轮 1 建立基线（up=1000 down=2000），轮 2 产生真实增量（up=1500 down=3000，即 +500/+1000）
3. 用 GORM `Raw().Before("gorm:raw")` 回调，在 `UPDATE client_traffics SET up …` 上注入失败
4. 调 `InboundService.AddTraffic(nil, clients)`
5. 轮 3 喂**完全相同**的累计值（期间无新流量），再次采集并提交
6. 断言账本最终应为 up=500 down=1000

### 实测输出

```
STEP 1  core metered a real delta, handed to the panel: up=500 down=1000
STEP 2  injected 1 client_traffics UPDATE failure(s); AddTraffic returned err=<nil>
STEP 2a SILENT: the write failed but AddTraffic reported success
STEP 3  ledger after the failed write: up=0 down=0
STEP 4  re-poll returned 1 entries (baseline already advanced past the lost delta)
STEP 5  final ledger: up=0 down=0
DELTA LOST: ledger holds up=0 down=0 ... want up=500 down=1000
```

完整输出见 `testdata/s1-exp1-traffic-delta-loss/probe-output.txt`。

### 两个独立缺陷

**缺陷 A — 写失败被静默吞掉。** `internal/web/service/inbound_traffic.go:179-187` 的每客户端 `tx.Exec(UPDATE client_traffics …)` 失败后只 `logger.Warning`，函数在 `:205` `return nil`。事务照常提交，`AddTraffic` 返回 nil，`internal/web/job/xray_traffic_job.go:82` 的调用方拿不到任何错误。同样模式在 `:196-202` 的 `expiry_time` 更新上重复一次。

**缺陷 B — 增量不可恢复。** `internal/xray/api.go:761` 在读取循环内无条件推进内存基线 `x.StatsLastValues[stat.Name] = stat.Value`，早于任何数据库提交；`:748` 用 `Reset_: false` 读取，核心侧计数器不被重置。下一轮同样累计值算出的 delta 为 0，字节永久消失。

**叠加后果**：一次瞬时数据库错误（锁竞争、磁盘满、Postgres 抖动）即可从共享月账本静默蒸发一段流量，面板层面无错误、无告警、无恢复机会。

### 探针复跑方法

把 `traffic_delta_loss_probe_test.go` 拷回 `internal/web/service/`，执行

```
go test -mod=readonly -count=1 -v ./internal/web/service -run '^TestProbeTrafficDeltaSurvivesFailedCommit$'
```

预期 FAIL（这是实验探针，不是已落地的回归测试；修复方案确定后再连同修复一起落库）。

---

## 实验 2a：RemoveUser 能否中断既有连接

**结论：不能。既有连接满速存活，完全不受影响。**

### 方法

自包含探针 `testdata/s1-exp2a-removeuser/s1probe.go.txt`（Go，仅标准库，零外部依赖）。单机内完成：

- 内建 HTTP 流量源（有声明长度的大响应）
- 服务端 Xray：一个 VLESS inbound（用户 A `alice@probe`、B `bob@probe`）+ dokodemo API inbound
- 客户端 Xray：两个 http inbound，分别路由到 A、B 的 VLESS 出站
- 两条限速持续下载，探针**自行统计收到的字节数**，与 Xray 自身计数器互为独立见证
- 稳定传输若干秒后调用 `xray api rmu`（即 3x-ui 发的 `AlterInbound` + `RemoveUserOperation`）
- 继续观察，最后再用被删用户发起一次**新**连接作对照

### 实测结果

移除生效确凿——`inbounduser` 移除前列出 alice 与 bob，移除后只剩 bob；`rmu` 输出 `Removed 1 user(s) in total.`

移除后 20 秒内：

| 用户 | 读取字节 | 速率 |
| --- | --- | --- |
| A（已被 RemoveUser） | 11,468,800 | 558.3 KiB/s |
| B（未动） | 11,468,800 | 558.3 KiB/s |

**完全相同。** 逐秒计数在移除那一刻（t+006）没有任何变化：

```
t+006  alice.do=+589824   probeA=+573440     ← 移除发生在这一秒
t+007  alice.do=+655360   probeA=+630784
t+008  alice.do=+524288   probeA=+573440
```

对照测试：被删用户 A 发起**新**连接被拒绝（EOF）。

完整证据：`testdata/s1-exp2a-removeuser/result.log.txt`（实验全程与判定）、`monitor.log.txt`（逐秒双见证计数）。两份日志因仓库 `.gitignore` 忽略 `*.log` 而以 `.txt` 后缀存放。

### 三条结论

1. **`RemoveUser` 只挡新握手，对已建立的连接零作用。** VLESS 在 `proxy/vless/encoding.go:94` 只在握手时认证一次；`RemoveUser`（`proxy/vless/inbound/inbound.go:245-248`）仅删两个 sync.Map 条目；`AlterInbound` 经 `app/proxyman/inbound/always.go:207-209` 只拿到裸 proxy，结构上够不到连接。
2. **被删用户的计数器继续增长。** 核心中无任何代码调用 `UnregisterCounter`，`*stats.Counter` 在 dispatch 时已焊入 link（`app/dispatcher/default.go:164-170`）。面板会继续给"已停用"用户记账并显示在线。
3. **面板侧无重启兜底。** `restartXrayOnClientDisable` 默认 `"true"`，但停用客户端走 `RestartXray(false)`，`internal/web/service/xray.go:1322-1324` 热更成功即 `return nil`，永不到达 `process.Stop()`。单面板部署下 `RemoveUser` 就是全部执行手段。（多节点 master 另有 `internal/web/job/node_traffic_sync_job.go:140` 的 `RestartXray(true)` 强制重启路径，尚未验证，且其代价是整机所有账号掉线。）

### 由此确认的一处既有缺陷

`internal/web/job/check_client_ip_job.go:666` 的 IP 超限功能写着：

```go
// Remove user to disconnect all connections
err = xrayAPI.RemoveUser(inbound.Tag, clientEmail)
time.Sleep(100 * time.Millisecond)
err = xrayAPI.AddUser(protocol, inbound.Tag, clientConfig)
```

按本实验结果，这段**一条连接都断不了**，只是把门关了 100 毫秒。该 IP 限制功能大概率失效。

---

## 附带发现（不在原计划范围内，但影响后续配置）

`proxy/freedom/freedom.go:154-169`：freedom 出站的默认最终规则**按入站协议决定**——

```go
case "vless", "vmess", "trojan", "hysteria", "wireguard":
    return defaultBlockPrivateRule
```

即 **VLESS 入站 + 默认 freedom 出站，无法访问内网/环回目标**，会被 blackhole 数十秒（证据见 `testdata/s1-exp2a-removeuser/freedom-block-private-evidence.txt`）。需要显式 `finalRules` 放行。本实验因此在服务端配置中加了 `{"action":"allow","ip":["127.0.0.1/32"]}`。

---

## 结论分类

### 一、源码已确认

- 内存基线推进早于数据库提交，提交失败路径只告警不回退。
- VLESS 单次握手认证，`RemoveUser` 仅改用户表，`AlterInbound` 够不到连接。
- 计数器从不注销；`RestartXray(false)` 在热更成功时提前返回。
- freedom 出站按入站协议套用默认私网拦截规则。

### 二、模拟依赖测试已运行

- 实验 1 全程使用 fake Stats gRPC 与临时 SQLite。缺陷 A、B 的复现建立在注入的写失败之上，**不是**观察到的真实数据库故障。

### 三、真实核心已运行

- 实验 2a 全程使用固定版本自编 `Xray 26.7.28` 真实进程，真实 VLESS 握手、真实 TCP 传输、真实 `rmu` 调用。移除生效与连接存活均为直接观测。

### 四、尚未覆盖

- **实验 3**：节点失联时调额/停用、恢复后收敛、旧指令迟到——需第二个节点，未执行。
- 目标 Linux 节点上的复跑（本次为 Windows）。
- VLESS + REALITY、XTLS Vision/flow、UDP、Mux 下的断流行为。Vision splice 另有两个已知复杂性：空闲计时器被推到 24 小时，且计数器只在连接结束时结算——届时计数器不能作为存活判据。

  **2026-09-16 补充的版本限定（重要）**：上述 Vision splice 行为是 `XTLS Vision: Defer Splice handoff until write completes`（PR #5737）引入的，该提交随 **v26.3.27** 发布。因此它适用于面板管理的 Xray **26.7.28**，而**不适用于机器 A 上当前仍在 443 服务真实用户的裸 Xray 26.2.6**。换言之：切换到面板 Xray 之后，流量计量的可观测特性会真的发生变化（下行计数器在 spliced 传输期间冻结、关闭时一次性结算），而现在还没有。此前未区分版本的表述范围过宽。另外 splice 仅在 Linux/Android 且内层为 TLS 1.3 时才触发，非该条件下退回 readV，计数照常连续。
- 多节点 master 的 `RestartXray(true)` 强制重启路径及其误伤范围。
- 真实数据库故障（非注入）下的行为。
- 20 账号 / 20 人并发容量。

---

## 对第一版设计的影响

三条已确认事实合起来构成一个对共享月额度不利的闭环：

> 额度耗尽 → 停用 → **连接不断** → 继续跑流量 → **继续记账** → 超用持续扩大，而面板显示一切正常。

因此「额度耗尽即断流」在现有 API 上**做不到**。可选方向（均未验证，需另行设计与实验）：

1. 接受一个可测量的超用窗口——只挡新连接，配合轮询与明示的延迟上界；
2. 在连接层扩展准入校验，使既有连接可被定向终止；
3. 整核心重启——**handoff 已明确禁止**，因其代价是同机所有账号掉线。

方向选定前不应开始 S3（共享额度）实现。

---

## 与计划的偏差

| 偏差 | 原因 | 影响 |
| --- | --- | --- |
| 实验在 Windows 而非 Linux 节点执行 | 节点尚未具备条件（系统 EOL、待重装） | 核心版本相同、被测为平台无关 Go 代码；但节点复跑仍属未覆盖 |
| 实验 2a 使用 http 入站作为客户端侧入口 | 便于用 Go 标准库 `http.Transport{Proxy:}` 驱动，无需额外依赖 | 被测对象是服务端 VLESS 入站与 `RemoveUser`，客户端侧入口协议不影响结论 |
| 服务端 freedom 出站额外加了 `finalRules` 放行环回 | 该版本默认对 VLESS 入站启用私网拦截 | 仅为让单机实验成立，不改变被测行为 |
| 实验 1 的失败是注入的 | 无法可靠制造真实数据库故障 | 证明的是「一旦写失败会怎样」，不是「写失败有多频繁」 |
