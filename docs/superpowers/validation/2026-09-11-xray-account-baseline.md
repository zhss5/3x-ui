# Xray 账户管理 S0 基线验证记录

本文件是 [S0 基线验证计划](../plans/2026-09-11-xray-account-baseline-validation.md) 的执行记录。
只记录已实际执行的内容。文件名沿用计划中固定的交付路径（计划日期 2026-09-11），实际执行日期见下表。

## 执行标识

| 项 | 值 |
| --- | --- |
| 执行日期 | 2026-09-14 |
| 工作目录 | `D:\workspaces\3x-ui` |
| 分支 | `codex/xray-account`（与 `origin/codex/xray-account` 同步） |
| 执行时 HEAD | `1b952e7679de96f7bfca634fd785838cfb4fe631` |
| 源码基线 | `f727d04f6522bb94a8fb52e8352fdcafb51c11e1`（v3.7.0），`git merge-base --is-ancestor` 退出码 0，确认为 HEAD 祖先 |
| origin | `git@github.com:zhss5/3x-ui.git` |
| upstream | `https://github.com/MHSanaei/3x-ui.git` |
| 执行前工作树 | 干净（`git status --porcelain` 为空） |
| 日志目录 | `tmp/account-validation/`（`.gitignore:14 tmp/` 覆盖，未提交） |

HEAD 位于基线之后的两个提交均为文档提交，符合计划「文档提交可以位于基线之后」的约定。

## 环境

| 项 | 值 | 来源 |
| --- | --- | --- |
| Go | `go1.27.0 windows/amd64` | `go version` |
| GOVERSION | `go1.27.0` | `go env` |
| GOOS / GOARCH | `windows` / `amd64` | `go env` |
| CGO_ENABLED | `1` | `go env` |
| CC | `D:\msys64\mingw64\bin\gcc.exe` | `go env` |
| GOTOOLCHAIN | `auto` | `go env` |
| C 编译器版本 | `gcc.exe (Rev2, Built by MSYS2 project) 16.1.0` | `& $env:CC --version` |

版本信息取自 `go version` / `go env` 的实际输出，不是启动器路径推断。

## 命令与退出码

| # | 任务 | 命令（要点） | 退出码 | 备注 |
| --- | --- | --- | --- | --- |
| 1 | T1S1 | `git merge-base --is-ancestor f727d04 HEAD` | 0 | 基线是祖先 |
| 2 | T1S1 | `go version` / `go env` / `gcc --version` | 0 | 见上表 |
| 3 | T1S2 | `go build -mod=readonly -o tmp/account-validation/x-ui.exe .` | 0 | 126.3 s，产物 128,598,677 字节 |
| 4 | T2S1 | `go test ./internal/xray -run '^(TestGetTraffic.*\|TestRemoveUserGuardsNilHandlerClient)$'` | 0 | 5 PASS |
| 5 | T2S2 | `go test ./internal/web/service -run '^(…9 个测试…)$'` | 0 | 9 PASS |
| 6 | T2S3 | 三处源码检索 | 0 | 用 `Select-String` 代替 `rg`，见「偏差」 |
| 7 | T3S1 | `go list -mod=readonly -m -json github.com/xtls/xray-core` | 0 | 版本与 go.mod 一致 |
| 8 | T3S1 | `go build -mod=readonly -o tmp/account-validation/xray.exe github.com/xtls/xray-core/main` | 0 | 7.3 s |
| 9 | T3S1 | `go version -m tmp/account-validation/xray.exe` | 0 | 41 个 dep |
| 10 | T3S2 | `go test ./internal/xray -run '^TestXrayAPI_E2E_Users$/^vless$'` | 0 | 1 PASS，无 SKIP |
| 11 | T3S2 | `go test ./internal/xray -run '^TestXrayAPI_E2E_NewClientTrafficIsCounted$'` | 0 | 1 PASS，无 SKIP |
| 12 | T4S1 | `git diff --exit-code -- go.mod go.sum` | 0 | 依赖文件未变 |
| 13 | T4S1 | `git status --short` | 0 | 输出为空 |

`internal/web/dist/` 按 `dist-stub` 语义新建并放置 `.gitkeep`，由 `.gitignore:21 dist/` 覆盖，不进入提交。构建产物未启动。

## 测试结果

### 模拟依赖：核心统计差分与 API 参数保护（`./internal/xray`，0.634 s）

| 测试 | 结果 |
| --- | --- |
| `TestRemoveUserGuardsNilHandlerClient` | PASS |
| `TestGetTrafficFirstPollIsBaselineOnly` | PASS |
| `TestGetTrafficCountsNewStatFromZero` | PASS |
| `TestGetTrafficCountsAfterCounterReset` | PASS |
| `TestGetTrafficSkipsAPIInboundAndPrunes` | PASS |

计划中的 `TestGetTraffic.*` 通配到上述 4 个测试，合计执行 5 个。

### 模拟依赖：双节点汇总与运行时分发（`./internal/web/service`，2.288 s）

| 测试 | 结果 |
| --- | --- |
| `TestTwoNodesShareEmail_SumsCorrectly` | PASS |
| `TestSingleNode_MirrorsCorrectly` | PASS |
| `TestNodeAdd_ImportsClientHistoryWithNewInbound` | PASS |
| `TestUpgrade_PreExistingRow_NoDoubleCount` | PASS |
| `TestNodeCounterReset_NoReAdd` | PASS |
| `TestCentralReset_NoReAdd` | PASS |
| `TestCentralResetClearsNodeBaseline_NoLeak` | PASS |
| `TestAddTrafficCommitsDespiteDisableHelperError` | PASS |
| `TestTrafficDisableImmediatelyUpdatesNodeRuntime` | PASS |

断言核对：`node_client_traffic_sum_test.go:107` 断言两节点建立基线后增量合计为上传/下载各 `110`，来源见同文件 `:338` 注释「node1 delta=50, node2 delta=60 → total=110」，与计划描述一致。

这两组使用模拟 Stats gRPC、模拟节点和临时 SQLite，**不是**真实核心结果。

### 真实核心：固定版本 Xray（`./internal/xray`）

`XRAY_E2E_BINARY=D:\workspaces\3x-ui\tmp\account-validation\xray.exe`

| 测试 | 结果 | 耗时 |
| --- | --- | --- |
| `TestXrayAPI_E2E_Users/vless` | PASS，无 SKIP | 0.832 s（包整体） |
| `TestXrayAPI_E2E_NewClientTrafficIsCounted` | PASS，无 SKIP | 1.356 s（包整体） |

两次运行均由测试夹具启动并清理真实核心进程，启动横幅一致：

```
Xray 26.7.28 (Xray, Penetrates Everything.) Custom (go1.27.0 windows/amd64)
2026/09/14 10:33:20.020797 [Warning] core: Xray 26.7.28 started
2026/09/14 10:33:20.162601 from 127.0.0.1:55838 accepted tcp:127.0.0.1:55836 [api -> api]
```

流量测试中出现实际被代理的请求，是本次唯一的真实取流证据：

```
2026/09/14 10:33:36.990264 from 127.0.0.1:58414 accepted http://127.0.0.1:58408/ [http-in >> direct]
--- PASS: TestXrayAPI_E2E_NewClientTrafficIsCounted (0.73s)
```

核心在启动时对 VMess / Trojan / Shadowsocks 输出了 deprecated 告警，属核心自身提示，测试仍通过。

## 核心二进制

| 项 | 值 |
| --- | --- |
| 模块 | `github.com/xtls/xray-core` |
| 版本 | `v1.260327.1-0.20260728075948-5ca6f4b7d4dc`（与 `go.mod` 固定值一致） |
| 模块校验和 | `h1:fkOkmgHWbF2Q8MdV9VxrsyxRz4OndcrUXUkh1ANBTg0=` |
| 运行时自报版本 | `Xray 26.7.28` |
| 构建 | `go1.27.0`，`CGO_ENABLED=1`，`GOOS=windows`，`GOARCH=amd64`，`-compiler=gc` |
| SHA256 | `91291EB076343201A7180ACDD25175C8217A36D4755AF5FC32642C150E8C3F65` |
| 大小 | 47,225,344 字节 |
| 依赖数 | 41 |

构建过程向模块缓存下载了 `github.com/ghodss/yaml` 与 `github.com/pelletier/go-toml`（xray-core `main` 包的传递依赖）。`git diff --exit-code -- go.mod go.sum` 退出码 0，本仓库依赖文件未发生漂移。未使用 `latest` 二进制。

## 源码事实（已确认，非运行结果）

按计划 Task 2 Step 3 记录写入顺序：

- `internal/xray/api.go:748` 以 `QueryStatsRequest{Reset_: false}` 读取核心统计，核心侧累计计数器不被面板重置，增量完全依赖面板内存态。
- `internal/xray/api.go:761` 在读取循环内无条件执行 `x.StatsLastValues[stat.Name] = stat.Value`，**内存基线在任何数据库提交之前就已推进**；`:757` 的 `baselinePass` 使首轮只建基线不计增量。
- `internal/xray/api.go:780-785` 当基线映射超过存活统计项 2 倍时重建，剪除已删除入站/客户端的残留基线。
- 数据库提交发生在下游 `internal/web/job/xray_traffic_job.go:82` 的 `inboundService.AddTraffic`；该处失败仅在 `:83-84` 记录 `logger.Warning` 后继续执行，增量不会被重新读取。
- `internal/web/service/inbound_node.go:415` `setRemoteTrafficLocked` 与 `:496-497` 的 `NodeClientTraffic` 基线行构成节点侧账本；`:819`、`:1065` 存在删除路径。

由此得到的风险条目：**统计读取推进内存基线在前、数据库提交在后且提交失败不回退，存在提交失败即丢失该轮增量的可能。** 这是源码推断，**尚未复现**，列为 S1 故障注入实验的首要验证项。

同时按计划记录边界：既有代理统计清零与新节点历史导入，均**不能**作为清空月账本或向新账户追记历史用量的依据。

## 结论分类

计划要求四类分开陈述，不得混写。

### 一、源码已确认

- 统计读取使用不重置的累计计数器，增量由面板内存基线计算。
- 内存基线推进早于数据库提交，且提交失败路径只告警不回退。
- 节点侧存在独立的 `NodeClientTraffic` 基线行与删除路径。

### 二、模拟依赖测试已运行

- 14 个既有测试全部 PASS（`./internal/xray` 5 个 + `./internal/web/service` 9 个）。
- 覆盖：首轮基线、计数器新增与回落、映射剪枝、双节点同身份汇总为 110、单节点镜像、新入站历史导入、升级不重复计数、节点/中心重置不重加与不泄漏、辅助禁用出错不回滚流量、提交后向模拟运行时分发停用。
- 这些结果建立在模拟 Stats gRPC、模拟节点和临时 SQLite 之上。其中 `TestAddTrafficCommitsDespiteDisableHelperError` **不是**数据库写入失败重试测试；`TestTrafficDisableImmediatelyUpdatesNodeRuntime` 只断言模拟运行时的调用次数，**不是**已有连接终止测试。

### 三、真实核心已运行

- 用 `go.mod` 固定版本自行编译的 `Xray 26.7.28` 实际启动，`TestXrayAPI_E2E_Users/vless` 与 `TestXrayAPI_E2E_NewClientTrafficIsCounted` 均 PASS 且无 SKIP。
- 后者经本地 HTTP 代理传输 `const payload = 64 * 1024`（65,536 字节）响应体，测试断言为「实际代理字节数等于 payload」且「核心统计的 downlink **不小于** payload」（`api_users_e2e_test.go:410-411`、`:428-429`）。因此本次证据支持「真实核心确实计入了被代理的流量」，**不支持**「计量与传输字节严格相等」。
- 测试使用的 UUID、邮箱、端口与临时配置均为夹具自动生成的测试数据，不含真实账号、节点密钥或数据库内容。

### 四、尚未覆盖

- VLESS + REALITY、Vision/flow、UDP、Mux 的端到端行为。
- 数据库提交失败后的增量恢复；节点重复上报与迟到快照；核心/节点重启与归属变更。
- 账户定向断流：停用某账户后新连接被拒、既有长连接停止传输、其他账户不受影响。以上均未实验，接口成功与 `Enable=false` 不能替代。
- 节点失联期间调额/停用的可见性、恢复后的最新状态收敛、重试与旧指令覆盖。
- 双节点真实部署、20 账号 / 20 人并发容量、四类客户端实际版本验收。
- Docker / Linux 权限验收、发行物供应链证明、全项目编译与完整测试套件（本次仅执行计划点名的测试）。

## 据本次结果确定的 S1 实验内容

按计划 Task 4 Step 3 的三行条件确定，顺序依 S0 实际发现调整优先级。详细测试代码与连接控制方案另成计划，本记录只锁定范围。

| 顺序 | S1 实验 | 本次 S0 给出的直接依据 | 要决定什么 |
| --- | --- | --- | --- |
| 1 | 读取统计后注入数据库提交失败再次采集；节点重复上报与迟到快照；核心/节点重启与归属变更 | `api.go:761` 内存基线先于 `xray_traffic_job.go:82` 的提交推进，且 `:83-84` 失败仅告警。既有 14 个测试**没有**覆盖这条路径 | 持久化计量起点、去重键、计数器世代、异常可见性 |
| 2 | 账户 A/B 各建持续 TCP 流；仅停用 A，验两节点上 A 新连接被拒、旧流停止、B 原连接不中断；再覆盖 UDP、Mux、VLESS + REALITY/实际 flow | 本次唯一的真实核心证据只到「用户 API 可增删」与「一次 64 KiB 取流被计入」，**没有**任何既有连接终止证据；`TestTrafficDisableImmediatelyUpdatesNodeRuntime` 只数 mock 调用 | 现有运行时能否执行定向断流，是否必须扩展 Xray 连接层 |
| 3 | 一节点失联时调额/停用，恢复后收敛到最新状态；重复执行与旧指令迟到 | 双节点汇总仅在模拟节点下验证；真实失联、部分执行失败均未触达 | 节点失败策略、重试与版本控制；无证据不得显示已生效 |

前置判断：实验 1 与实验 2 相互独立，可并行准备；实验 3 依赖实验 2 确定的执行接口。三项都完成并留下证据后，才进入 S2 安全与账户实现包。

## 与计划的偏差

| 偏差 | 原因 | 影响 |
| --- | --- | --- |
| `Start-Transcript` 未跨任务保持单一会话 | 执行 harness 每次调用为独立 PowerShell 进程，环境变量与转录不跨调用保留 | 改为每次调用以 `-Append` 续写同一 `tmp/account-validation/run.log`，并在每次调用重新设置 `CGO_ENABLED` / `CC` / `XRAY_E2E_BINARY`；命令与退出码判定不变 |
| Task 2 Step 3 用 `Select-String` 代替 `rg` | 当前环境 PATH 中无 `rg` | 检索文件与正则完全一致，仅工具不同 |
| `go version -m ... \| Select-Object -First 8` 曾返回退出码 255 | 管道提前关闭导致 native 命令 broken pipe | 已去掉截断重跑，退出码 0，记录以重跑结果为准 |
| 验证记录文件名沿用 `2026-09-11` | 计划的交付路径固定 | 实际执行日期 2026-09-14 已在「执行标识」中明确 |

## 证据边界

S0 只验证既有基础是否可复现地跑通，**不**声明计量无损、**不**声明账户级断流可用、**不**声明 20 人容量达标。第三类结论仅覆盖上述两个测试所触达的路径，其余协议、故障与多节点场景一律属于第四类。本次未执行安装脚本、未部署、未公开面板、未推送、未以整核心重启代替按账户停用。
