# S3 定向断连实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 客户端流量耗尽时，挡住它的新握手并定向销毁它已有的连接，全程不重启 Xray 核心、不影响其他客户端；新周期恢复时同样不重启即可重新连入。

**Architecture:** 新增 `internal/xray/sockdrop` 包，通过内核 `SOCK_DESTROY`（netlink `NETLINK_INET_DIAG`）按「本地端口 + 对端 IP」销毁 TCP 连接；在 `runtime.Runtime` 上新增 `DropUser` = `RemoveUser`（挡新握手）+ 查在线 IP + 销毁 socket。把 6 个 `rt.RemoveUser` 调用点中**语义为「离开且不会被加回」的 5 个**改调 `DropUser`，唯独「修改客户端」那个保持 `RemoveUser`。同时关闭上游 v3.8.5 的整核心重启开关。

**Tech Stack:** Go 1.27 / `github.com/vishvananda/netlink` v1.3.1（已在 go.mod，间接依赖）/ `golang.org/x/sys/unix` / Xray gRPC StatsService。

---

## 为什么这样做（必读，否则会做错）

三条是这个方案存在的前提，均已实测，不要重新发明：

1. **Xray 核心没有关闭单个会话的 API。** 26.7.28 与 26.9.8 都没有。`RemoveUser` 只挡新握手，**已有连接继续满速传输**——机器 A 实测在 REALITY + Vision + splice 下 8 秒传了 10 MB。
2. **上游 v3.8.5 的做法（整核心重启）本项目不采用。** 它断掉机器上所有人；而且它的守卫只在「被移除客户端仍在运行进程的配置快照里」时触发，经运行时 API 热加回的客户端不在快照里，所以月初重置后下一次耗尽根本不会触发重启。
3. **`SOCK_DESTROY` 能干净地断开。** 销毁后 splice 的 `ReadFrom` 立刻报 `software caused connection abort`，两端一起拆除，**出站侧残留连接 0 条**，不存在 fd 泄漏。

完整证据与反例见 [handoff 的「S3 连接控制方向已确定（2026-09-18）」](../../xray-account-handoff.md)。

## 边界：这个计划做什么、不做什么

**做：** 本地运行时（`runtime.Local`）上的定向断连机制，以及把它接到已有的「额度耗尽」等路径上。

**不做（各有明确理由，不是遗漏）：**

- **共享月额度的账户层**（跨两台机器汇总、周期重置、批量调额）——那是 S3 本体，另有计划。本计划只提供它要用的断连能力。
- **流量账本丢增量的缺陷修复（L1/L2）**——独立缺陷，独立修。**但它是 S3 本体的前置**：账本不准则「是否超额」的判定依据就不准。本计划的机制不依赖它。
- **节点侧（Remote）断连。** 用户已明确「162 的节点暂时不管」，且面板当前只在本机。注意一个容易踩的坑：**`Remote.RemoveUser` 并不移除单个用户**，它是 `return r.UpdateInbound(ctx, ib, ib)`，即整个入站重推，语义与 `Local` 完全不同。节点侧要单独设计，不能假设照搬。本计划在 Task 6 里让 `Remote.DropUser` 保持现有行为并**显式告警**，使这个缺口在日志里可见，而不是静默。
- **`check_client_ip_job.go:678` 等 3 处绕过 runtime 直接调 `xrayAPI.RemoveUser` 的分层违规。** 其中 IP 超限功能的注释写着「Remove user to disconnect all connections」，按本计划的结论它一条连接都断不了，该功能大概率早已失效。修它是独立工作，不要混进来。

## 文件结构

| 文件 | 职责 |
| --- | --- |
| `internal/xray/sockdrop/sockdrop.go`（新建） | 跨平台类型定义（`Target` / `Result`）与文档。无平台相关 import。 |
| `internal/xray/sockdrop/sockdrop_linux.go`（新建） | Linux 实现：枚举两个地址族的 TCP socket，按 (本地端口, 对端 IP) 匹配并销毁。 |
| `internal/xray/sockdrop/sockdrop_other.go`（新建） | 非 Linux 桩：返回 `ErrUnsupported`。**必须有**，否则 Windows 开发机上 `go build ./...` 直接失败。 |
| `internal/xray/sockdrop/sockdrop_linux_test.go`（新建） | 真 socket 测试：v4 / 双栈+v4 / 双栈+v6 三种形态。 |
| `internal/web/runtime/runtime.go:17` 附近（修改） | 接口新增 `DropUser`。 |
| `internal/web/runtime/local.go:267` 之后（修改） | `Local.DropUser` 实现。 |
| `internal/web/runtime/remote.go:567` 之后（修改） | `Remote.DropUser`（v1 告警桩）。 |
| `internal/web/runtime/local_dropuser_test.go`（新建） | `DropUser` 在协议豁免、API 不可用等情形下的行为。 |
| `internal/web/service/inbound_traffic_apply.go:111`（修改） | 额度耗尽路径改调 `DropUser`。 |
| `internal/web/service/client_bulk.go:1214,1812`（修改） | 批量删除、批量停用改调 `DropUser`。 |
| `internal/web/service/client_inbound_apply.go:234,1217`（修改） | 解绑、单个删除改调 `DropUser`。**`:1022` 不改。** |
| `internal/web/service/setting.go:172`（修改） | `restartXrayOnClientDisable` 默认值改 `"false"`。 |

---

### Task 1: `sockdrop` 包的类型与非 Linux 桩

**Files:**
- Create: `internal/xray/sockdrop/sockdrop.go`
- Create: `internal/xray/sockdrop/sockdrop_other.go`

先建跨平台骨架。**顺序很重要**：先有桩再写 Linux 实现，否则中途任何一次 Windows 上的 `go build ./...` 都会红。

- [ ] **Step 1: 写类型定义**

创建 `internal/xray/sockdrop/sockdrop.go`：

```go
// Package sockdrop destroys live TCP connections by kernel socket destruction
// (SOCK_DESTROY over NETLINK_INET_DIAG). Xray has no API to close a single
// session, so removing a user only blocks new handshakes; this closes the old
// ones. Linux only — needs CONFIG_INET_DIAG_DESTROY and CAP_NET_ADMIN.
package sockdrop

import (
	"errors"
	"net/netip"
)

// ErrUnsupported is returned on platforms without kernel socket destruction.
var ErrUnsupported = errors.New("sockdrop: socket destruction is only available on linux")

// Target selects connections accepted on LocalPort whose peer address is in
// Peers. Xray's online map records peer IPs but not ports, so a peer IP shared
// by several users drops their connections too; they keep their access and
// their clients reconnect.
type Target struct {
	LocalPort int
	Peers     []netip.Addr
}

// Result reports what a Drop did. Destroyed < Matched means some sockets
// survived; Errs holds one error per failed socket.
type Result struct {
	Matched   int
	Destroyed int
	Errs      []error
}
```

- [ ] **Step 2: 写非 Linux 桩**

创建 `internal/xray/sockdrop/sockdrop_other.go`：

```go
//go:build !linux

package sockdrop

// Drop is unavailable off Linux; callers log the error and carry on, since the
// user is already blocked from new handshakes by then.
func Drop(Target) (Result, error) { return Result{}, ErrUnsupported }
```

- [ ] **Step 3: 确认在当前平台能编译**

Run: `make dist-stub && go build ./internal/xray/sockdrop/`
Expected: 无输出，exit 0。

- [ ] **Step 4: 提交**

```bash
git add internal/xray/sockdrop/
git commit -m "feat(sockdrop): add the cross-platform scaffolding for socket destruction"
```

---

### Task 2: Linux 实现——枚举与匹配

**Files:**
- Create: `internal/xray/sockdrop/sockdrop_linux.go`
- Create: `internal/xray/sockdrop/sockdrop_linux_test.go`

**关键事实（已实测，不要凭直觉改）：** 生产的 443 是双栈监听器，**IPv4 客户端的连接只出现在 `AF_INET6` 表里**（IPv4-mapped），在 `AF_INET` 表里查不到。所以必须两个族都枚举。

- [ ] **Step 1: 先写失败的测试**

创建 `internal/xray/sockdrop/sockdrop_linux_test.go`：

```go
//go:build linux

package sockdrop

import (
	"net"
	"net/netip"
	"testing"
)

// dialPair opens a listener of the given network and returns the accepted
// server side plus its local/remote addresses.
func dialPair(t *testing.T, listenNet, listenAddr, dialNet, dialHost string) (net.Conn, net.Conn, *net.TCPAddr, *net.TCPAddr) {
	t.Helper()
	ln, err := net.Listen(listenNet, listenAddr)
	if err != nil {
		t.Skipf("listen %s %s: %v", listenNet, listenAddr, err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port

	type acc struct {
		c net.Conn
		e error
	}
	ch := make(chan acc, 1)
	go func() { c, e := ln.Accept(); ch <- acc{c, e} }()

	cli, err := net.Dial(dialNet, net.JoinHostPort(dialHost, strconv.Itoa(port)))
	if err != nil {
		t.Skipf("dial %s %s: %v", dialNet, dialHost, err)
	}
	a := <-ch
	if a.e != nil {
		cli.Close()
		t.Fatalf("accept: %v", a.e)
	}
	t.Cleanup(func() { a.c.Close(); cli.Close() })
	return a.c, cli, a.c.LocalAddr().(*net.TCPAddr), a.c.RemoteAddr().(*net.TCPAddr)
}

func TestMatchFindsConnectionOnBothFamilies(t *testing.T) {
	tests := []struct {
		name                         string
		listenNet, listenAddr        string
		dialNet, dialHost, peerToUse string
	}{
		{"ipv4 listener", "tcp4", "127.0.0.1:0", "tcp4", "127.0.0.1", "127.0.0.1"},
		{"dual-stack listener, ipv4 client", "tcp", ":0", "tcp4", "127.0.0.1", "127.0.0.1"},
		{"dual-stack listener, ipv6 client", "tcp", ":0", "tcp6", "::1", "::1"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, _, local, _ := dialPair(t, tc.listenNet, tc.listenAddr, tc.dialNet, tc.dialHost)
			peer := netip.MustParseAddr(tc.peerToUse)
			got, err := match(Target{LocalPort: local.Port, Peers: []netip.Addr{peer}})
			if err != nil {
				t.Fatalf("match: %v", err)
			}
			if len(got) != 1 {
				t.Fatalf("matched sockets = %d, want exactly 1 (family split: an IPv4 client on a dual-stack listener lives in the AF_INET6 table)", len(got))
			}
		})
	}
}
```

顶部 import 补 `"strconv"`。

- [ ] **Step 2: 跑测试确认它失败**

Run: `go test ./internal/xray/sockdrop/ -run TestMatchFindsConnection -v`
Expected: 编译失败，`undefined: match`。

- [ ] **Step 3: 实现枚举与匹配**

创建 `internal/xray/sockdrop/sockdrop_linux.go`：

```go
//go:build linux

package sockdrop

import (
	"fmt"
	"net"
	"net/netip"

	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

type socketPair struct {
	local, remote *net.TCPAddr
}

// match lists live sockets on t.LocalPort whose peer is one of t.Peers. Both
// families are enumerated: an IPv4 client on a dual-stack listener appears only
// in the AF_INET6 table, as IPv4-mapped.
func match(t Target) ([]socketPair, error) {
	if t.LocalPort <= 0 || len(t.Peers) == 0 {
		return nil, nil
	}
	want := make(map[netip.Addr]struct{}, len(t.Peers))
	for _, p := range t.Peers {
		want[p.Unmap()] = struct{}{}
	}

	var (
		out      []socketPair
		lastErr  error
		anyFamOK bool
	)
	for _, fam := range []uint8{unix.AF_INET, unix.AF_INET6} {
		socks, err := netlink.SocketDiagTCP(fam)
		if err != nil {
			lastErr = fmt.Errorf("enumerate family %d: %w", fam, err)
			continue
		}
		anyFamOK = true
		for _, s := range socks {
			if int(s.ID.SourcePort) != t.LocalPort {
				continue
			}
			peer, ok := netip.AddrFromSlice(s.ID.Destination)
			if !ok {
				continue
			}
			if _, hit := want[peer.Unmap()]; !hit {
				continue
			}
			out = append(out, socketPair{
				local:  &net.TCPAddr{IP: s.ID.Source, Port: int(s.ID.SourcePort)},
				remote: &net.TCPAddr{IP: s.ID.Destination, Port: int(s.ID.DestinationPort)},
			})
		}
	}
	if !anyFamOK {
		return nil, lastErr
	}
	return out, nil
}
```

注意 `peer.Unmap()`：`AF_INET6` 表里 IPv4 连接的对端是 `::ffff:a.b.c.d`，而在线表给的是 `a.b.c.d`，不归一化就永远匹配不上。

- [ ] **Step 4: 跑测试确认通过**

Run: `go test ./internal/xray/sockdrop/ -run TestMatchFindsConnection -v`
Expected: 三个子测试全 PASS。

- [ ] **Step 5: 提交**

```bash
git add internal/xray/sockdrop/
git commit -m "feat(sockdrop): enumerate matching sockets across both address families"
```

---

### Task 3: Linux 实现——两个地址族的销毁

**Files:**
- Modify: `internal/xray/sockdrop/sockdrop_linux.go`
- Modify: `internal/xray/sockdrop/sockdrop_linux_test.go`

**关键事实（已实测）：** `netlink.SocketDestroy` 对 IPv4-mapped 的双栈连接**可用**（内核 TCP hashinfo 共用，v4 查找能命中 AF_INET6 表里的条目）；但对**真 IPv6 对端**它用 `To4() == nil` 拒绝并返回 `not implemented`，连接不断。库内部的 `socketRequest.Serialize()` 本就正确处理 AF_INET6，被挡住的只是那道闸，所以自己按同一 56 字节线格式拼请求即可，**无需改库、无需外调 `ss`**。

- [ ] **Step 1: 先写失败的测试**

在 `sockdrop_linux_test.go` 追加。判据用「重新枚举四元组是否还在」，**不要用「还能不能读到数据」**——服务端持续写入时客户端接收缓冲区有积压，socket 已销毁仍能读出积压数据，会误判（这个坑本项目踩过）。

```go
// Socket destruction needs CAP_NET_ADMIN and a kernel built with
// CONFIG_INET_DIAG_DESTROY (WSL2's default kernel lacks it). Skip on the
// permission check; a kernel without support surfaces as a Drop error, which
// this test reports rather than hides — Task 8 runs it where support exists.
func requireNetAdmin(t *testing.T) {
	t.Helper()
	if os.Geteuid() != 0 {
		t.Skip("socket destruction needs CAP_NET_ADMIN; run this as root (Task 8 does)")
	}
}

func TestDropClosesConnectionOnBothFamilies(t *testing.T) {
	requireNetAdmin(t)
	tests := []struct {
		name                  string
		listenNet, listenAddr string
		dialNet, dialHost     string
	}{
		{"ipv4 listener", "tcp4", "127.0.0.1:0", "tcp4", "127.0.0.1"},
		{"dual-stack listener, ipv4 client", "tcp", ":0", "tcp4", "127.0.0.1"},
		{"dual-stack listener, ipv6 client", "tcp", ":0", "tcp6", "::1"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv, _, local, remote := dialPair(t, tc.listenNet, tc.listenAddr, tc.dialNet, tc.dialHost)
			peer, _ := netip.AddrFromSlice(remote.IP)

			res, err := Drop(Target{LocalPort: local.Port, Peers: []netip.Addr{peer.Unmap()}})
			if err != nil {
				t.Fatalf("Drop: %v", err)
			}
			if res.Destroyed != 1 {
				t.Fatalf("destroyed = %d (matched %d, errs %v), want 1", res.Destroyed, res.Matched, res.Errs)
			}

			left, err := match(Target{LocalPort: local.Port, Peers: []netip.Addr{peer.Unmap()}})
			if err != nil {
				t.Fatalf("re-enumerate: %v", err)
			}
			if len(left) != 0 {
				t.Fatalf("sockets still in the table after Drop = %d, want 0", len(left))
			}
			if _, werr := srv.Write(make([]byte, 4096)); werr == nil {
				t.Fatal("server write succeeded after Drop, want a connection-abort error")
			}
		})
	}
}
```

顶部 import 补 `"os"`。

- [ ] **Step 2: 跑测试确认它失败**

Run: `sudo -E go test ./internal/xray/sockdrop/ -run TestDropCloses -v`
Expected: 编译失败，`undefined: Drop`。

- [ ] **Step 3: 实现销毁**

在 `sockdrop_linux.go` 追加。import 补 `"encoding/binary"` 和 `"github.com/vishvananda/netlink/nl"`：

```go
// netlink's socketRequest is unexported, so this mirrors its wire format. Its
// own Serialize already lays out AF_INET6 correctly; only SocketDestroy's
// To4() guard rejects IPv6, which is what this works around.
const sizeofSocketRequest = 56

type socketRequest6 struct {
	sourcePort, destinationPort uint16
	source, destination         net.IP
}

func (r *socketRequest6) Len() int { return sizeofSocketRequest }

func (r *socketRequest6) Serialize() []byte {
	native := nl.NativeEndian()
	b := make([]byte, sizeofSocketRequest)
	b[0] = unix.AF_INET6
	b[1] = unix.IPPROTO_TCP
	native.PutUint32(b[4:8], 0) // States: a destroy matches the 4-tuple exactly
	binary.BigEndian.PutUint16(b[8:10], r.sourcePort)
	binary.BigEndian.PutUint16(b[10:12], r.destinationPort)
	copy(b[12:28], r.source.To16())
	copy(b[28:44], r.destination.To16())
	native.PutUint32(b[44:48], 0) // Interface
	native.PutUint32(b[48:52], nl.TCPDIAG_NOCOOKIE)
	native.PutUint32(b[52:56], nl.TCPDIAG_NOCOOKIE)
	return b
}

// destroyV6 is SocketDestroy for genuine IPv6 peers, which the library refuses.
func destroyV6(local, remote *net.TCPAddr) error {
	req := nl.NewNetlinkRequest(nl.SOCK_DESTROY, unix.NLM_F_ACK)
	req.AddData(&socketRequest6{
		sourcePort:      uint16(local.Port),
		destinationPort: uint16(remote.Port),
		source:          local.IP.To16(),
		destination:     remote.IP.To16(),
	})
	_, err := req.Execute(unix.NETLINK_INET_DIAG, 0)
	return err
}

// Drop destroys every live connection matching t. A failure on one socket does
// not stop the others: the user is already blocked from new handshakes, so a
// partial drop is better than none.
func Drop(t Target) (Result, error) {
	pairs, err := match(t)
	if err != nil {
		return Result{}, err
	}
	res := Result{Matched: len(pairs)}
	for _, p := range pairs {
		var derr error
		if p.remote.IP.To4() != nil {
			derr = netlink.SocketDestroy(p.local, p.remote)
		} else {
			derr = destroyV6(p.local, p.remote)
		}
		if derr != nil {
			res.Errs = append(res.Errs, fmt.Errorf("destroy %s->%s: %w", p.local, p.remote, derr))
			continue
		}
		res.Destroyed++
	}
	return res, nil
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `sudo -E go test ./internal/xray/sockdrop/ -run TestDropCloses -v`
Expected: 三个子测试全 PASS。

若第三个子测试失败而前两个通过，说明 AF_INET6 请求拼装有误——对照 `docs/superpowers/validation/testdata/s3-sockdestroy/sockprobe.go.txt` 里已验证的版本逐字段比对，不要改判据。

若全部 skip，说明不是 root 或内核无 `CONFIG_INET_DIAG_DESTROY`（**WSL2 默认内核就没有**）。此时必须在机器 A 上验证，见 Task 8。

- [ ] **Step 5: 提交**

```bash
git add internal/xray/sockdrop/
git commit -m "feat(sockdrop): destroy sockets for both IPv4 and IPv6 peers"
```

---

### Task 4: `Local.DropUser`

**Files:**
- Modify: `internal/web/runtime/runtime.go`（接口，约 :17）
- Modify: `internal/web/runtime/local.go`（约 :267 之后）
- Create: `internal/web/runtime/local_dropuser_test.go`

- [ ] **Step 1: 先写失败的测试**

创建 `internal/web/runtime/local_dropuser_test.go`：

```go
package runtime

import (
	"context"
	"testing"

	"github.com/mhsanaei/3x-ui/v3/internal/database/model"
)

func TestDropUserSkipsProtocolsWithoutXraySockets(t *testing.T) {
	called := false
	l := NewLocal(LocalDeps{
		APIPort:        func() int { called = true; return 0 },
		SetNeedRestart: func() {},
	})
	for _, p := range []model.Protocol{model.MTProto, model.AmneziaWG, model.TUIC} {
		t.Run(string(p), func(t *testing.T) {
			called = false
			ib := &model.Inbound{Protocol: p, Tag: "in-test", Port: 443}
			if err := l.DropUser(context.Background(), ib, "someone@example.com"); err != nil {
				t.Fatalf("DropUser on %s = %v, want nil (these run outside Xray)", p, err)
			}
			if called {
				t.Fatalf("DropUser on %s reached the Xray API, want it skipped", p)
			}
		})
	}
}

func TestDropUserReportsRemoveUserFailure(t *testing.T) {
	l := NewLocal(LocalDeps{APIPort: func() int { return 0 }, SetNeedRestart: func() {}})
	ib := &model.Inbound{Protocol: model.VLESS, Tag: "in-443-tcp", Port: 443}
	err := l.DropUser(context.Background(), ib, "someone@example.com")
	if err == nil {
		t.Fatal("DropUser with no running core = nil, want the RemoveUser error surfaced")
	}
}
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `make dist-stub && go test ./internal/web/runtime/ -run TestDropUser -v`
Expected: 编译失败，`l.DropUser undefined`。

- [ ] **Step 3: 接口加方法**

在 `internal/web/runtime/runtime.go` 的 `RemoveUser` 那行下面加：

```go
	// DropUser removes the user AND destroys their live connections. RemoveUser
	// only blocks new handshakes — Xray has no API to close a session, so an
	// existing connection keeps running at full speed. Use this wherever the
	// user leaves and is not added back; an edit that re-adds must not use it.
	DropUser(ctx context.Context, ib *model.Inbound, email string) error
```

- [ ] **Step 4: 实现 `Local.DropUser`**

在 `internal/web/runtime/local.go` 的 `RemoveUser` 之后加。import 补 `"net/netip"`、`"github.com/mhsanaei/3x-ui/v3/internal/logger"`、`"github.com/mhsanaei/3x-ui/v3/internal/xray/sockdrop"`：

```go
func (l *Local) DropUser(ctx context.Context, ib *model.Inbound, email string) error {
	if err := l.RemoveUser(ctx, ib, email); err != nil {
		return err
	}
	if ib.Protocol == model.MTProto || ib.Protocol == model.AmneziaWG || ib.Protocol == model.TUIC {
		return nil
	}

	var peers []netip.Addr
	err := l.withAPI(func(api *xray.XrayAPI) error {
		users, err := api.GetOnlineUsers()
		if err != nil {
			return err
		}
		for _, u := range users {
			if u.Email != email {
				continue
			}
			for _, ip := range u.IPs {
				if addr, perr := netip.ParseAddr(ip.IP); perr == nil {
					peers = append(peers, addr.Unmap())
				}
			}
		}
		return nil
	})
	// 断连失败不回滚：用户已被挡住新握手，少断一条连接好过把移除也撤销。
	if err != nil {
		logger.Warning("DropUser: look up online IPs for", email, "failed:", err)
		return nil
	}
	if len(peers) == 0 {
		return nil
	}
	res, err := sockdrop.Drop(sockdrop.Target{LocalPort: ib.Port, Peers: peers})
	if err != nil {
		logger.Warning("DropUser: destroy sockets for", email, "failed:", err)
		return nil
	}
	logger.Info("DropUser:", email, "matched", res.Matched, "destroyed", res.Destroyed)
	for _, e := range res.Errs {
		logger.Warning("DropUser:", email, e)
	}
	return nil
}
```

`RemoveUser` 的错误要返回：核心不可用时调用方需要知道，这与断连失败不同。

- [ ] **Step 5: 跑测试确认通过**

Run: `go test ./internal/web/runtime/ -run TestDropUser -v`
Expected: 两个测试 PASS。

- [ ] **Step 6: 提交**

```bash
git add internal/web/runtime/
git commit -m "feat(runtime): add DropUser, which removes a user and closes their connections"
```

---

### Task 5: `Remote.DropUser`（v1 告警桩）

**Files:**
- Modify: `internal/web/runtime/remote.go`（约 :567 之后）

节点侧不在 v1 范围内（用户已定「162 的节点暂时不管」）。但**必须让缺口在日志里可见**——静默地不断连正是本项目反复抓到的那类问题。

- [ ] **Step 1: 实现桩**

在 `Remote.RemoveUser` 之后加：

```go
// DropUser on a node currently only blocks new handshakes. Local's socket
// destruction has to run where the connection lands, and the node has no
// endpoint for it yet; note also that Remote.RemoveUser re-pushes the whole
// inbound rather than removing one user.
func (r *Remote) DropUser(ctx context.Context, ib *model.Inbound, email string) error {
	logger.Warning("remote DropUser:", email, "on node", ib.Tag,
		"— existing connections survive until the node-side drop endpoint ships")
	return r.RemoveUser(ctx, ib, email)
}
```

- [ ] **Step 2: 确认接口已被满足**

Run: `go build ./internal/web/...`
Expected: exit 0。任何实现了 `Runtime` 的测试替身也要补这个方法——若报错，按编译器指出的文件逐个补上同样的桩。

- [ ] **Step 3: 提交**

```bash
git add internal/web/runtime/remote.go
git commit -m "feat(runtime): add Remote.DropUser, logging the node-side gap instead of hiding it"
```

---

### Task 6: 接上「离开且不回来」的 5 个调用点

**Files:**
- Modify: `internal/web/service/inbound_traffic_apply.go:111`
- Modify: `internal/web/service/client_bulk.go:1214`、`:1812`
- Modify: `internal/web/service/client_inbound_apply.go:234`、`:1217`
- **不改：** `internal/web/service/client_inbound_apply.go:1022`

这是整个计划最容易做错的一步。`UpdateUser` 修改客户端时是「先 `RemoveUser` 再 `AddUser`」（`local.go:305-315`），**挂错地方会让批量调整额度把这批人全部断线**——而批量调额正是第一版目标第 4 条。

| 位置 | 语义 | 改不改 |
| --- | --- | --- |
| `inbound_traffic_apply.go:111` | 额度耗尽 / 到期 | **改**（S3 要的就是这条） |
| `client_bulk.go:1214` | 批量删除 | 改 |
| `client_bulk.go:1812` | 批量停用 | 改 |
| `client_inbound_apply.go:234` | 解绑 | 改 |
| `client_inbound_apply.go:1217` | 单个删除 | 改 |
| `client_inbound_apply.go:1022` | **修改客户端**，之后可能在 `:1042` 加回 | **不改** |

- [ ] **Step 1: 先写失败的测试**

在 `internal/web/service/` 下新建 `client_drop_wiring_test.go`。它用源码自身作为断言对象——这是唯一能防住「将来有人顺手把 :1022 也改了」的方式：

```go
package service

import (
	"os"
	"strings"
	"testing"
)

// The edit path is RemoveUser+AddUser; turning it into DropUser would cut off
// every client touched by a bulk quota change. Pin it here because nothing else
// catches that regression.
func TestEditPathStillUsesRemoveUserNotDropUser(t *testing.T) {
	b, err := os.ReadFile("client_inbound_apply.go")
	if err != nil {
		t.Fatalf("read source: %v", err)
	}
	lines := strings.Split(string(b), "\n")

	var editLine string
	for i, ln := range lines {
		if strings.Contains(ln, "rt.RemoveUser(context.Background(), oldInbound, oldEmail)") {
			editLine = ln
			t.Logf("edit path at client_inbound_apply.go:%d", i+1)
		}
	}
	if editLine == "" {
		t.Fatal("the edit path's rt.RemoveUser call is gone; if it moved, update this test — do not delete it")
	}
	if strings.Contains(editLine, "DropUser") {
		t.Fatal("the edit path uses DropUser: a bulk quota change would disconnect every client it touches")
	}
}

func TestDepletionPathUsesDropUser(t *testing.T) {
	b, err := os.ReadFile("inbound_traffic_apply.go")
	if err != nil {
		t.Fatalf("read source: %v", err)
	}
	if !strings.Contains(string(b), "rt.DropUser(context.Background(), &plan.inbound, plan.email)") {
		t.Fatal("the quota-depletion path does not call DropUser, so an over-quota client keeps its live connections")
	}
}
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `go test ./internal/web/service/ -run "TestEditPathStill|TestDepletionPath" -v`
Expected: `TestDepletionPathUsesDropUser` FAIL（"does not call DropUser"）；`TestEditPathStill...` PASS（此时尚未改动，本就该绿——它防的是未来的回归）。

- [ ] **Step 3: 改额度耗尽路径**

`internal/web/service/inbound_traffic_apply.go:111`，把

```go
				err = rt.RemoveUser(context.Background(), &plan.inbound, plan.email)
```

改为

```go
				err = rt.DropUser(context.Background(), &plan.inbound, plan.email)
```

`not found` 的吞错逻辑保持原样。

- [ ] **Step 4: 改其余 4 处**

逐个把 `rt.RemoveUser(` 改成 `rt.DropUser(`，参数不变：

- `client_bulk.go:1214`
- `client_bulk.go:1812`
- `client_inbound_apply.go:234`
- `client_inbound_apply.go:1217`

**再次确认 `client_inbound_apply.go:1022` 保持 `rt.RemoveUser`。**

- [ ] **Step 5: 跑测试确认通过**

Run: `go test ./internal/web/service/ -run "TestEditPathStill|TestDepletionPath" -v`
Expected: 两个都 PASS。

- [ ] **Step 6: 跑全量 Go 测试**

Run: `make test-go`
Expected: 全绿。

- [ ] **Step 7: 提交**

```bash
git add internal/web/service/
git commit -m "feat(service): drop connections on the paths where a client leaves for good"
```

---

### Task 7: 关掉整核心重启开关

**Files:**
- Modify: `internal/web/service/setting.go:172`

有了定向断连，上游的整核心重启只剩下代价没有收益。

- [ ] **Step 1: 先写失败的测试**

在 `internal/web/service/` 下新建 `setting_restart_default_test.go`：

```go
package service

import (
	"path/filepath"
	"testing"

	"github.com/mhsanaei/3x-ui/v3/internal/database"
)

// This fork disconnects over-quota clients by destroying their sockets, so the
// upstream default of restarting the whole core — which cuts off everyone on
// the machine — must stay off.
func TestRestartXrayOnClientDisableDefaultsOff(t *testing.T) {
	if err := database.InitDB(filepath.Join(t.TempDir(), "x-ui.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { _ = database.CloseDB() })

	got, err := (&SettingService{}).GetRestartXrayOnClientDisable()
	if err != nil {
		t.Fatalf("GetRestartXrayOnClientDisable: %v", err)
	}
	if got {
		t.Fatal("restartXrayOnClientDisable defaults to true: one client's quota running out would restart the core and cut off everyone")
	}
}
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `go test ./internal/web/service/ -run TestRestartXrayOnClientDisableDefaults -v`
Expected: FAIL，"defaults to true"。

- [ ] **Step 3: 改默认值**

`internal/web/service/setting.go:172`：

```go
	"restartXrayOnClientDisable":  "false",
```

- [ ] **Step 4: 跑测试确认通过**

Run: `go test ./internal/web/service/ -run TestRestartXrayOnClientDisableDefaults -v`
Expected: PASS。

注意这只改**新库的默认值**；机器 A 现有数据库里已存的值要单独用 `x-ui setting` 改，见 Task 8。

- [ ] **Step 5: 提交**

```bash
git add internal/web/service/
git commit -m "fix(setting): stop restarting the whole core when one client is disabled"
```

---

### Task 8: 机器 A 端到端验收

**Files:** 无代码改动（Step 7 除外）。

前面所有测试都在回环上跑，而 `OnlineMap.AddIP` **刻意跳过 `127.0.0.1` / `[::1]`**（`online_map.go:36`），所以 `email → 客户端 IP` 这条查询路径在单元测试里根本没被走到。它必须用真实远端客户端验一次，否则整个机制可能在生产上查不到 IP、一条都断不掉。

> **这一步会动生产，先读完再动手。** 机器 A 当前跑的是**上游 v3.7.0 发行二进制**，本计划的改动在本仓库里，要生效就必须把自建面板放上去——这等于让机器 A 从此跑自建构建，是第一次把「v3.8.5 面板 + 钉住 26.7.28 核心」这条路推上生产。另外：机器 A 上还有一个独立的老版 xray 跑在 443 服务老版 v2rayN 用户，**任何步骤都不得触碰它**。执行前先跟用户确认这次部署，不要自行决定。

- [ ] **Step 1: 本地全量验证**

Run: `make verify`
Expected: 全绿。

- [ ] **Step 2: 在机器 A 上跑 Linux 侧单元测试**

**这一步不需要部署面板**，只把测试二进制送上去，风险最低，先做：

```bash
GOOS=linux GOARCH=amd64 go test -c -o /tmp/sockdrop.test ./internal/xray/sockdrop/
scp /tmp/sockdrop.test root@38.59.228.104:/tmp/
ssh root@38.59.228.104 '/tmp/sockdrop.test -test.v; echo exit=$?; rm -f /tmp/sockdrop.test'
```

Expected: 六个子测试全 PASS，**没有 skip**。有 skip 说明权限或内核不满足，必须先解决再往下走。

- [ ] **Step 3: 备份现有面板，留好回退路**

在部署前先把可回退的东西固定下来：

```bash
ssh root@38.59.228.104 'systemctl stop x-ui && \
  cp /usr/local/x-ui/x-ui /root/x-ui.v3.7.0.bak && \
  cp /etc/x-ui/x-ui.db /root/x-ui.db.bak-$(date +%F) && \
  ls -la /root/x-ui.v3.7.0.bak /root/x-ui.db.bak-*'
```

Expected: 两个备份文件都在。**回退方法**：`systemctl stop x-ui && cp /root/x-ui.v3.7.0.bak /usr/local/x-ui/x-ui && cp /root/x-ui.db.bak-<日期> /etc/x-ui/x-ui.db && systemctl start x-ui`。

- [ ] **Step 4: 部署自建面板并确认核心版本没被换掉**

```bash
GOOS=linux GOARCH=amd64 go build -o /tmp/x-ui-fork .
scp /tmp/x-ui-fork root@38.59.228.104:/usr/local/x-ui/x-ui
ssh root@38.59.228.104 'systemctl start x-ui && sleep 5 && \
  systemctl is-active x-ui && /usr/local/x-ui/bin/xray-linux-amd64 version | head -n 1'
```

Expected: `active`，且核心版本仍是 **26.7.28**（不是 26.9.x——26.9.9 会切断 Shadowrocket，占在用客户端的一半）。版本不对立刻按 Step 3 回退。

- [ ] **Step 5: 把已存的重启开关也关掉**

Task 7 只改了新库默认值，机器 A 库里已有旧值：

```bash
ssh root@38.59.228.104 '/usr/local/x-ui/x-ui setting -show true | grep -i restartXrayOnClientDisable'
```

若显示 `true`，用面板设置页改为关闭后重新确认。Expected: 最终为 `false`。

- [ ] **Step 6: 用真实客户端验证在线 IP 查询**

用 v2rayN 或 Shadowrocket 以 `zlz2026` 连上 443 并保持流量，然后在机器 A 上查在线表。面板端口先取出来再用：

```bash
ssh root@38.59.228.104 '/usr/local/x-ui/x-ui setting -show true | grep -iE "^port|webBasePath"'
```

用面板界面的「在线用户」列查看即可（走 API 需要会话 Cookie，界面更省事）。

Expected: `zlz2026` 出现在在线列表里且带**非回环**的公网 IP。查不到则 `DropUser` 无从下手——先查 `statsUserOnline` 策略是否开启，不要继续往下。

- [ ] **Step 6.5: 记录基线**

```bash
ssh root@38.59.228.104 'pgrep -a xray | head -n 3; \
  ss -tn state established "( sport = :443 )" | wc -l'
```

记下 pid 与连接数，Step 8 要对照。

- [ ] **Step 7: 触发一次真实耗尽**

把 `zlz2026` 的额度调到低于已用量，等定时任务跑完（或手动触发），观察面板日志里出现 `DropUser: zlz2026 matched N destroyed N`：

```bash
ssh root@38.59.228.104 'journalctl -u x-ui -n 50 --no-pager | grep -i dropuser'
```

Expected: 客户端立刻断流；`matched` 与 `destroyed` 相等且大于 0。

- [ ] **Step 8: 确认没有连带损伤**

```bash
ssh root@38.59.228.104 'pgrep -a xray | head -n 3; \
  ss -tn state established "( sport = :443 )" | wc -l'
```

Expected: **pid 与 Step 6.5 完全一致**（核心没重启）；连接数只减少了 `zlz2026` 那部分，`user1` 不受影响且仍能正常用——用 `user1` 的客户端实际发一次请求确认，不要只看连接数。

- [ ] **Step 9: 确认恢复**

把额度调回，确认 `zlz2026` 能重新连上，且 pid 仍未变。

Expected: 连接成功，核心全程零重启。

- [ ] **Step 10: 把结果写进 handoff**

在 `docs/xray-account-handoff.md` 的「S3 连接控制方向已确定（2026-09-18）」下追加一节实测记录，含 pid、连接数前后对比、`matched/destroyed` 数字。**如实记录**：任何一步没做或没通过，就写没通过。

```bash
git add docs/xray-account-handoff.md
git commit -m "docs(xray-account): record the end-to-end targeted-disconnect acceptance on machine A"
```

---

## 完成标准

1. `make verify` 通过。
2. `sudo -E go test ./internal/xray/sockdrop/` 在机器 A 上六个子测试全 PASS 且无 skip。
3. 机器 A 上真实客户端耗尽后断流，**Xray pid 未变**，其他用户不受影响，额度恢复后能重连。
4. `client_inbound_apply.go:1022` 仍是 `rt.RemoveUser`，且 `TestEditPathStillUsesRemoveUserNotDropUser` 为绿。
5. 机器 A 上留有可回退的 v3.7.0 二进制与数据库备份，且核心仍是 26.7.28。
6. handoff 中已追加如实的实测记录。

## 已知遗留（不在本计划内，不要顺手做）

- 节点侧（`Remote`）断连——只有告警，没有实际断开。
- `check_client_ip_job.go:678` 等 3 处绕过 runtime 的调用，其中 IP 超限功能大概率早已失效。
- 流量账本丢增量（L1/L2）——S3 本体的前置。
- 「停用原因」字段与新周期自动恢复——属于共享额度账户层。
- `AddUser` 失败时置 `needRestart` 走 30 秒重启，是整个周期里唯一还会重启的地方，应改为重试。
