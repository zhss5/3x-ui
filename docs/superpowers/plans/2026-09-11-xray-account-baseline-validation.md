# Xray 账户管理 S0 基线验证 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 在当前任务内顺序执行，不另建用户任务或自动派生代理。

**Goal:** 交付可复现的固定基线构建、现有流量测试及真实核心 API 验证记录，为账户计量和定向断流实验确定起点。

**Architecture:** 本计划是已批准第一阶段设计的 S0 验证包，复用已有 Go 测试和临时数据库，不改变业务行为。先区分源码推断、模拟节点测试和真实核心结果，再把未覆盖的连接路径交给下一阶段实验；S0 通过不代表账户系统或双服务器验收完成。

**Tech Stack:** 当前仓库 Go 1.27、CGO SQLite、标准库 testing、go.mod 固定的 Xray-core、Windows PowerShell。

## Global Constraints

- 产品范围遵循 [已批准设计](../specs/2026-09-11-xray-account-phase1-design.md)，不再请求同一设计的批准。
- 在当前 3x-ui 单仓库扩展，复用 Go/Gin/GORM 后端及 React/Ant Design 界面。
- 第一版包含两台代理服务器，预计全系统 20 个账号、20 人同时使用；需要双节点流量汇总及共享额度的实际验收。人数是容量目标，不作为注册数、设备数或连接数上限。
- 第一版不实现设备限制，也不预建相关表和会话服务；不引入自研客户端、支付或开放注册。
- 采用管理员开户、UTC 自然月、整数 byte 存储及 GiB 展示；批量设置当期和后续周期共享额度，保留已用量和管理员停用状态。
- 所有后续代理变更经过 `runtime.Runtime`；本阶段只调用现有隔离测试，不接触生产配置。
- 工作目录为 `D:\workspaces\3x-ui`，分支为 `codex/xray-account`，源码基线为 `f727d04f6522bb94a8fb52e8352fdcafb51c11e1`。文档提交可以位于基线之后。
- 不执行安装脚本、部署、公开面板、推送或全核心重启来代替按账户停用。
- 使用临时数据库、测试凭据和 loopback 监听。缺少真实核心时记录未运行；`SKIP`、mock 调用成功和源码阅读均不能记为真实连接测试通过。

## 文件与交付边界

| 文件 | 用途 |
| --- | --- |
| `docs/superpowers/validation/2026-09-11-xray-account-baseline.md`（新建） | 环境、命令、退出码、测试名、结论和证据限制 |
| `tmp/account-validation/`（忽略目录） | 日志及本地编译产物；不得提交 |
| `internal/xray/api_traffic_test.go`（已有，只读） | 核心累计计数读取及内存差分测试 |
| `internal/web/service/node_client_traffic_sum_test.go`（已有，只读） | 两节点同一统计身份的汇总、重置和历史导入测试 |
| `internal/web/service/traffic_commit_test.go`（已有，只读） | 禁用辅助步骤失败与流量事务的关系 |
| `internal/web/service/traffic_runtime_apply_test.go`（已有，只读） | 数据提交后向模拟运行时分发停用 |
| `internal/xray/api_users_e2e_test.go`（已有，只读） | 指定真实核心的用户 API 和实际 HTTP 代理流量测试 |

本阶段不新增产品 API、数据表或前端页面。下列任务是基线验证，不是修复测试；发现失败先定位并记录，不修改断言把缺陷变成通过。后续修复另写失败回归测试和独立提交。

### Task 1: 固定环境并构建后端

**Files:** 读取 `go.mod`、`go.sum`、`Makefile`；仅在忽略目录创建构建产物及必要的 embed 占位文件。

**Interfaces:** 消费当前 Go 模块和基线；产出 Go/CGO/编译器版本、构建退出码及 `tmp/account-validation/x-ui.exe`。后续任务在同一个 PowerShell 会话沿用环境。

- [ ] **Step 1: 核实分支和基线祖先，记录环境。**

```powershell
Set-Location -LiteralPath 'D:\workspaces\3x-ui'
$ErrorActionPreference = 'Stop'
if ((git branch --show-current) -ne 'codex/xray-account') { throw 'Unexpected branch' }
git merge-base --is-ancestor f727d04f6522bb94a8fb52e8352fdcafb51c11e1 HEAD
if ($LASTEXITCODE -ne 0) { throw 'Baseline is not an ancestor' }
New-Item -ItemType Directory -Force -Path 'tmp/account-validation' | Out-Null
Start-Transcript -Path 'tmp/account-validation/run.log' -Append
git status --short --branch
git rev-parse HEAD
git remote -v
$env:CGO_ENABLED = '1'
$env:CC = 'D:\msys64\mingw64\bin\gcc.exe'
if (-not (Test-Path -LiteralPath $env:CC)) { throw 'Configured C compiler is absent' }
go version
if ($LASTEXITCODE -ne 0) { throw 'Go version check failed' }
go env GOVERSION GOOS GOARCH CGO_ENABLED CC GOTOOLCHAIN
if ($LASTEXITCODE -ne 0) { throw 'Go environment check failed' }
& $env:CC --version
if ($LASTEXITCODE -ne 0) { throw 'C compiler check failed' }
```

期望：基线是祖先，当前有效 Go 工具链满足 `go.mod` 的 1.27 要求，CGO 为 1。启动器路径中的版本号不能代替 `go version` 结果。环境不满足时先修复本地工具配置并记录，不改项目版本门槛。

- [ ] **Step 2: 按 Makefile 的 dist-stub 语义构建，仅生成后端产物。**

```powershell
New-Item -ItemType Directory -Force -Path 'internal/web/dist' | Out-Null
if (-not (Test-Path -LiteralPath 'internal/web/dist/.gitkeep')) {
    New-Item -ItemType File -Path 'internal/web/dist/.gitkeep' | Out-Null
}
go build -mod=readonly -o tmp/account-validation/x-ui.exe .
if ($LASTEXITCODE -ne 0) { throw 'Backend baseline build failed' }
```

期望：构建退出码 0。此产物使用 embed 占位，不是带完整界面的发布包，也不启动它。

### Task 2: 建立现有计量和节点分发证据

**Files:** 上表中现有计量和运行时测试；不修改实现或测试。

**Interfaces:** 消费 `XrayAPI.GetTraffic() ([]*Traffic, []*ClientTraffic, error)` 及现有测试夹具；产出每个命名测试的实际结果。模拟 Stats gRPC/节点与临时 SQLite 证据必须分别标注。

- [ ] **Step 1: 执行核心统计差分及 API 参数保护测试。**

```powershell
go test -mod=readonly -count=1 -v ./internal/xray -run '^(TestGetTraffic.*|TestRemoveUserGuardsNilHandlerClient)$'
if ($LASTEXITCODE -ne 0) { throw 'Core statistics baseline failed' }
```

期望：命中的测试逐个 PASS。首个非空采集建立基线；后出现的计数器按零起点计算；计数器回落有现有处理。这些不证明数据库提交失败后的增量能恢复。

- [ ] **Step 2: 执行双节点同身份汇总、历史导入、重置和运行时分发测试。**

```powershell
go test -mod=readonly -count=1 -v ./internal/web/service -run '^(TestTwoNodesShareEmail_SumsCorrectly|TestSingleNode_MirrorsCorrectly|TestNodeAdd_ImportsClientHistoryWithNewInbound|TestUpgrade_PreExistingRow_NoDoubleCount|TestNodeCounterReset_NoReAdd|TestCentralReset_NoReAdd|TestCentralResetClearsNodeBaseline_NoLeak|TestAddTrafficCommitsDespiteDisableHelperError|TestTrafficDisableImmediatelyUpdatesNodeRuntime)$'
if ($LASTEXITCODE -ne 0) { throw 'Node traffic baseline failed' }
```

期望：上述 9 个测试逐个 PASS。核对现有断言：两节点首次建立基线后的增量合计为上传/下载各 110；新入站导入可以带历史流量；远端累计值回落时现有逻辑重新设基线，而本地核心统计回落测试会计入回落后的值。不得把两种数据源的累计值直接当成同一种账户月计量。

`TestAddTrafficCommitsDespiteDisableHelperError` 验证辅助禁用错误不回滚正常流量，不是数据库写入失败重试测试。`TestTrafficDisableImmediatelyUpdatesNodeRuntime` 验证 mock 调用次数，不是已有连接终止测试。

- [ ] **Step 3: 记录写入顺序和账户模块不能直接依赖的边界。**

```powershell
rg -n 'QueryStats|Reset_: false|StatsLastValues' internal/xray/api.go
rg -n 'GetXrayTraffic|AddTraffic|RestartXray' internal/web/job/xray_traffic_job.go
rg -n 'setRemoteTrafficLocked|NodeClientTraffic|Transaction' internal/web/service/inbound_node.go
```

记录 `GetTraffic` 在数据库提交前推进内存基线的源码事实；把“提交失败后可能丢失增量”列为需要故障实验确认的风险，不写成已运行的复现。既有代理统计清零和新节点历史导入也不能作为清空月账本或向新账户追记历史用量的依据。

### Task 3: 用固定版本真实核心运行已有 API 与流量测试

**Files:** 读取 `go.mod`、`internal/xray/api_users_e2e_test.go`；生成 `tmp/account-validation/xray.exe`。

**Interfaces:** 消费现有 `startE2ECore(t *testing.T, inbounds []any) *e2eCore` 及 `XRAY_E2E_BINARY`；产出核心版本/哈希、真实进程测试结果。测试自行创建临时配置并清理它启动的进程。

- [ ] **Step 1: 编译模块固定的核心，记录来源和二进制哈希。**

```powershell
go list -mod=readonly -m -json github.com/xtls/xray-core
if ($LASTEXITCODE -ne 0) { throw 'Xray module resolution failed' }
go build -mod=readonly -o tmp/account-validation/xray.exe github.com/xtls/xray-core/main
if ($LASTEXITCODE -ne 0) { throw 'Pinned Xray build failed' }
go version -m tmp/account-validation/xray.exe
if ($LASTEXITCODE -ne 0) { throw 'Xray build metadata check failed' }
Get-FileHash -LiteralPath 'tmp/account-validation/xray.exe' -Algorithm SHA256
$env:XRAY_E2E_BINARY = (Resolve-Path -LiteralPath 'tmp/account-validation/xray.exe').Path
```

期望：模块版本与 `go.mod` 固定值一致，构建无 `go.mod`/`go.sum` 漂移。不得改用 `latest` 二进制绕过失败。

- [ ] **Step 2: 执行 VLESS 用户 API 子测试和实际代理流量测试。**

```powershell
go test -mod=readonly -count=1 -v ./internal/xray -run '^TestXrayAPI_E2E_Users$/^vless$'
if ($LASTEXITCODE -ne 0) { throw 'VLESS user API test failed' }
go test -mod=readonly -count=1 -v ./internal/xray -run '^TestXrayAPI_E2E_NewClientTrafficIsCounted$'
if ($LASTEXITCODE -ne 0) { throw 'Real proxy traffic test failed' }
```

期望：输出明确运行 `Users/vless` 和 `NewClientTrafficIsCounted`，没有对应 SKIP；核心正常退出或由夹具清理。后一个测试通过本地 HTTP 代理产生 64 KiB 响应负载，是实际流量采集证据；不是 VLESS + REALITY、Vision、UDP 或 Mux 的端到端验收。

### Task 4: 交付基线记录并锁定下一步实验

**Files:** 新建 `docs/superpowers/validation/2026-09-11-xray-account-baseline.md`；更新本计划复选框。原安全报告保持原文。

**Interfaces:** 消费 Tasks 1–3 的实际输出；产出带结果和限制的记录。只记录已执行内容；运行失败保留错误和退出码，未执行写“未运行”及原因，不填写预测结果。

- [ ] **Step 1: 结束记录并核对修改范围。**

```powershell
Stop-Transcript
git diff --exit-code -- go.mod go.sum
if ($LASTEXITCODE -ne 0) { throw 'Dependency files changed' }
git status --short
```

- [ ] **Step 2: 用实际输出填写验证记录。**

记录必须包含：执行日期、完整 HEAD、源码基线、Go/CGO/编译器信息、核心模块版本和 SHA256、构建及各命令退出码、测试名和 PASS/FAIL/SKIP、相关日志摘录。将日志中的测试凭据明确标为测试数据；不提交实际账号、节点密钥或数据库。

结论按“源码已确认”“模拟依赖测试已运行”“真实核心已运行”“尚未覆盖”四类写明，禁止把后两类混在一起。S0 只验证既有基础，不声明计量无损、完整账户断流或 20 人容量达标。

- [ ] **Step 3: 按以下条件确定 S1 实验内容，再展开功能实施计划。**

| 顺序 | S1 必须新增的行为验证 | 决定什么 |
| --- | --- | --- |
| 1 | 读取统计后注入数据库提交失败，再次采集；节点重复/迟到快照；核心/节点重启与归属变更 | 持久化计量起点、去重键、计数器世代和异常可见性 |
| 2 | 账户 A/B 先建立持续 TCP 流；停用 A 后新连接被拒、旧流停止，B 不受影响；再测 UDP、Mux、VLESS + REALITY/实际 flow | 现有运行时能否执行目标，是否需要 Xray 连接层扩展 |
| 3 | 一节点失联时调额/停用，恢复后接收最新状态；重复执行及旧指令迟到 | 节点失败策略、重试和版本控制；没有证据不能显示已生效 |

S1 的详细测试代码和连接控制方案根据 S0 结果另成计划；本计划不预设现有 API 会断开已有连接。若需要新增核心能力，先形成具体接口和行为方案，不以全核心重启或只隐藏订阅替代。

- [ ] **Step 4: 检查并仅提交计划执行记录。**

```powershell
git add -- docs/superpowers/validation/2026-09-11-xray-account-baseline.md docs/superpowers/plans/2026-09-11-xray-account-baseline-validation.md
git diff --cached --check
if ($LASTEXITCODE -ne 0) { throw 'Staged whitespace check failed' }
git diff --cached --stat
```

人工核对仅包含本任务记录，再本地提交 `docs(xray-account): record baseline validation`，提交说明写明证据范围。不推送，不暂存忽略目录。

## 双节点与定向断流验证方法（讨论补充）

2026-09-11 用户询问如何验证双节点计量和账户定向断流。本节保存讨论中的测试方法与通过标准，补充 S1 和最终验收的输入，不是运行记录，不改变 S0 的交付边界。

### 环境与分层

- 一个管理端、两个独立代理节点、测试账户 A/B，节点使用独立配置和数据库，固定 Xray 版本。
- 本机隔离实例用于前期逻辑和连接行为验证；最终在两台 Linux 测试服务器上按实际部署拓扑验收。本机结果不替代双服务器和 20 人容量证据。
- 账户模块尚未实现时，先用固定的“账户 → 凭据 → 节点”测试映射验证底层能力。完成账户模块后，必须再从真实账户接口触发同样的场景。
- 使用自动化脚本产生可控制的上传、下载及持续连接，不操作现有生产账户或生产代理。

### 计量断言

先向计量模块输入已知增量，逐项比较整数 byte：

| 场景 | 预期行为 |
| --- | --- |
| A 在节点一上传 20 MiB、下载 100 MiB，节点二上传 10 MiB、下载 80 MiB，测试倍率为 1 | A 上传增加 30 MiB、下载增加 180 MiB、合计增加 210 MiB；B 不变 |
| 同一节点重复上报同一份数据 | 不重复累计 |
| 同一 UUID 在两个节点均产生真实流量 | 两个来源分别计入，不能仅按 UUID 把另一节点的流量去重 |
| 读取统计后注入数据库提交失败，再次采集或重试 | 对可恢复的数据不丢失、不重复；无法恢复的缺口明确记录 |
| 节点重启、统计清零、迟到上报 | 不产生负数、不重复导入历史；按来源和计数器世代处理 |
| 修改月额度或重置代理凭据 | 当月已用量及历史账本保持；额度修改只改变额度和派生状态 |

MiB 只用于测试样例，1 MiB = 1,048,576 byte，不改变产品 GiB 展示规则。随后通过真实节点产生上传和下载，停止发流并等待采集完成，将账户账本增量与两个节点同一计量口径的统计增量之和对账。文件大小、网卡流量和 Xray 统计的计量位置不同，不把三者直接设为相等断言；记录各自口径及采集区间。

### 账户定向断流断言

1. 让 A、B 在两个节点均建立持续传输的长连接。为 A 覆盖多个关联凭据；记录连接标识，避免客户端自动重连掩盖原连接被中断。
2. 仅停用 A，检查两个节点上的 A 新连接都不能继续代理传输，已有连接停止传输，所有关联凭据受相同账户规则约束。
3. 检查 B 原有长连接持续传输且没有重建，核心未因该操作整体重启。只检查 B 能重新连接不足以证明未受影响。
4. 先用手动停用验证执行能力，再将触发条件替换为共享额度耗尽和管理员降低额度，覆盖两个节点上的执行状态和实际连接结果。
5. 在 TCP 之后覆盖 UDP、实际支持的复用方式，以及 VLESS + REALITY/所选 flow 的配置。记录 v2rayN、v2rayNG、Shadowrocket、支持该组合的 Clash/Mihomo 的实际版本和结果；不能以未支持的组合推断整个客户端可用或不可用。

接口成功、`Enable=false`、运行时收到调用均不能单独作为断流通过。若新连接被拒而旧连接仍能持续下载，记录现有 API 的能力缺口，并形成连接层扩展方案；不以重启整个核心或撤下订阅作为按账户断流的替代。

### 恢复、故障与测量

- 提高额度后，有剩余额度且仅因额度耗尽停用的 A 可以重新建立代理连接；不要求已终止的 TCP 连接原地恢复。管理员手动停用的账户保持停用。新月按相同状态优先级验证。
- 模拟一个节点失联，再调整额度或停用账户，检查失联/执行失败可见；节点恢复后按最新目标状态执行，旧请求和重试不能覆盖较新的设置。
- 失联期间继续服务还是限制服务及容忍时长仍由连接控制设计明确；本节不把任何一种策略当成已验证或已获单独确认。
- 记录额度耗尽被发现、停用指令发出、节点响应和目标连接最后成功传输的时间；测量检测/执行延迟、最终超用字节以及 B 的连接连续性。时间比较需统一时钟或记录时钟偏差，区分“实际达到阈值”与“采集首次观察到达到阈值”。
- 根据实测结果确定验收时延与可接受超用范围，不承诺同步零延迟或字节级硬上限。

### 当前证据边界

仓库已有 `TestTwoNodesShareEmail_SumsCorrectly` 汇总测试和 `TestTrafficDisableImmediatelyUpdatesNodeRuntime` 分发测试；后者只检查模拟运行时调用。现有真实核心用户 API 测试也不等于持续连接终止测试。截至本节写入，账户项目的上述测试尚未运行，定向断流实验尚未补充；原安全审查中的隔离探针是另一类历史证据。

## 第一版后续交付映射

下表保留完整设计的覆盖关系；属于后续实现包，不能因为本 S0 计划执行完就勾选已完成。

| 实现包 | 交付范围 | 前置条件 |
| --- | --- | --- |
| S1 技术实验 | 故障记账、按账户定向断流、断联节点策略和时延测量 | S0 给出实际证据 |
| S2 安全与账户 | 相关安全补丁、普通用户认证、服务端归属隔离、账户/凭据关系、迁移、管理员开户 | 固定基线；逐问题回归；明确关联计量起点 |
| S3 共享额度 | 月账本、上下行合计、两节点共享额度、月切换、单个及批量修改、自动恢复、保留手动停用、审计/重试 | S1 确定记账及连接控制接口，S2 账户归属可用 |
| S4 界面与配置 | 管理员多选和逐节点进度、用户登录/用量/配置/改密、凭据独立重置、API/WS 隔离及多语言合同 | S2/S3 接口与重置操作边界确定 |
| S5 整体验收 | 两台代理、20 账号/20 人真实并发、四类客户端实际版本、超用与延迟、失败恢复、相关检查及 make verify | S2–S4 完成；真实节点及客户端测试条件齐备 |

## 计划审阅记录

- [x] 路径、现有测试名及核心测试环境变量已从当前源码核对。
- [x] 区分已有测试、需要新增的实验和完整第一版验收，不把 S0 等同于实现完成。
- [x] 已确认的开户、月周期、单位和批量额度规则直接沿用；保留设计中尚需实验的执行边界。
- [x] 本计划没有执行结果；以上任务仍全部未运行。
