#!/bin/bash
# killprobe.sh -- 在机器 A 上隔离验证：RemoveUser + SOCK_DESTROY 能否切断处于 Vision splice 状态的连接。
#
# 设计要点：
#  - 只用 127.0.0.1 的 44310-44313 端口和一次性生成的 REALITY 密钥；不碰 443、不碰面板、不碰生产密钥。
#  - 数据源自带（本地强制 TLS 1.3 的无限流 HTTPS），不依赖外部测速站点：外部站点会限流，
#    而且可能协商成 TLS 1.2，那样 Vision 不会进入 splice，整个实验会静默地测错东西。
#  - dest 候选逐个试握手：REALITY 要求 dest 的 TLS 1.3 握手可被劫持；不满足时会在认证成功后
#    仍报 "handshake did not complete successfully"（reality tls.go 的失败链最后一档）。
#    第一个候选是机器 A 生产 443 已验证可用的。
#  - 销毁前先用完全相同的过滤条件列出目标并硬校验，再停下来等人确认。
#
# 以 root 运行（ss -K 需要 CAP_NET_ADMIN）。约 2 分钟。
# DRYRUN=1：跳过 root 检查、自动确认，用于在不支持 SOCK_DESTROY 的环境里只跑通流程。
set -u

XRAY=${XRAY:-/usr/local/x-ui/bin/xray-linux-amd64}
D=${D:-/root/killprobe}
DRYRUN=${DRYRUN:-0}
SP=44310        # 测试服务端 VLESS+REALITY+Vision
AP=44311        # 测试服务端 API
CP=44312        # 测试客户端 socks
LP=44313        # 本地 TLS 1.3 无限流数据源
TAG=probe-in
EMAIL=probe-user
RATE=1M
# dest 候选："主机:端口|serverName|客户端指纹"
DESTS=(
  "www.apple.com:443|www.apple.com|chrome"
  "www.apple.com:443|www.apple.com|firefox"
  "www.cloudflare.com:443|www.cloudflare.com|chrome"
  "www.bing.com:443|www.bing.com|chrome"
)
SMALL_URL="https://www.cloudflare.com/cdn-cgi/trace"
BIG_URL="https://127.0.0.1:$LP/stream"

PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  sleep 1
  for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
}
trap cleanup EXIT
trap 'echo; echo "中断，正在清理"; exit 130' INT TERM

say() { printf '\n=== %s ===\n' "$*"; }
size() { stat -c %s "$D/dl.bin" 2>/dev/null || echo 0; }
# 每秒采样一次下载文件大小并打印增量；窗口内总增量存入 GROWTH
sample() {
  local n=$1 label=$2 prev cur i total=0
  prev=$(size)
  for i in $(seq 1 "$n"); do
    sleep 1; cur=$(size)
    printf '  %s t+%02ds  +%10d 字节\n' "$label" "$i" $((cur - prev))
    total=$((total + cur - prev)); prev=$cur
  done
  GROWTH=$total
}
listening() { ss -Hltn "( sport = :$1 )" | grep -q .; }

if [ "$DRYRUN" != 1 ] && [ "$(id -u)" != 0 ]; then echo "需要以 root 运行"; exit 1; fi
[ -x "$XRAY" ] || { echo "找不到 $XRAY"; exit 1; }
command -v python3 >/dev/null || { echo "需要 python3"; exit 1; }
command -v openssl >/dev/null || { echo "需要 openssl"; exit 1; }

say "0. 安全前置检查"
for p in $SP $AP $CP $LP; do listening "$p" && { echo "端口 $p 已被占用，退出"; exit 1; }; done
PROD_PID0=$(ss -Hltnp '( sport = :443 )' | grep -oP 'pid=\K[0-9]+' | head -1)
PROD_N0=$(ss -Htn state established '( sport = :443 )' | wc -l)
echo "  生产 443：pid=${PROD_PID0:-无}  已建立连接=$PROD_N0"
echo "  核心：$($XRAY version | head -1)"
rm -rf "$D" && mkdir -m 700 "$D" && cd "$D" || exit 1

say "1. 起一个本地 TLS 1.3 无限流数据源（自带，不依赖外部站点）"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout key.pem -out cert.pem \
  -days 1 -nodes -subj "/CN=probe.local" >/dev/null 2>&1 || { echo "生成自签证书失败"; exit 1; }
# 注意：以下 Python 刻意不含任何反斜杠转义，避免经多层引用后被提前解释。
cat > src.py <<'PY'
import ssl, socket, threading, sys
CRLF = bytes([13, 10])
HDR = (b"HTTP/1.1 200 OK" + CRLF
       + b"Content-Type: application/octet-stream" + CRLF
       + b"Connection: close" + CRLF + CRLF)
BLK = bytes(65536)          # 65536 个零字节
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3   # 强制 1.3：splice 的前提条件
ctx.load_cert_chain("cert.pem", "key.pem")
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sys.argv[1])))
srv.listen(8)
def handle(c):
    try:
        c.recv(65536)
        c.sendall(HDR)
        while True:
            c.sendall(BLK)
    except Exception:
        pass
    finally:
        try:
            c.close()
        except Exception:
            pass
while True:
    raw, _ = srv.accept()
    try:
        c = ctx.wrap_socket(raw, server_side=True)
    except Exception:
        raw.close()
        continue
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY
python3 src.py $LP > src.out 2>&1 & SRCPID=$!; PIDS+=("$SRCPID")
for i in $(seq 1 20); do listening $LP && break; sleep 0.5; done
listening $LP || { echo "本地数据源启动失败："; cat src.out; exit 1; }
# 服务端已设 minimum_version=TLSv1_3，客户端再用 --tlsv1.3 强制一次：
# 握手成功即双向证明走的是 TLS 1.3，无需依赖 curl 的 %{tls_version}（老版本没有该变量）。
V=$(curl -sk --tlsv1.3 --max-time 8 -o /dev/null -w '%{http_code}' "$BIG_URL")
echo "  本地源直连（强制 TLS 1.3）返回：$V"
[ "$V" = 200 ] || { echo "本地源的 TLS 1.3 连接不通，splice 前提不成立，退出。src.out："; cat src.out; exit 1; }

say "2. 生成一次性密钥"
KEYS=$($XRAY x25519)
PRIV=$(printf '%s\n' "$KEYS" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')
PUB=$(printf '%s\n' "$KEYS" | awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}')
UUID=$($XRAY uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
SID=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
if [ -z "$PRIV" ] || [ -z "$PUB" ] || [ -z "$UUID" ] || [ -z "$SID" ]; then echo "密钥生成失败："; echo "$KEYS"; exit 1; fi
echo "  一次性密钥已生成（与生产密钥无关）"

# 用指定的 dest/serverName/fingerprint 生成三份配置
write_configs() {
  local dest=$1 sni=$2 fp=$3
  INBOUND='{"tag":"'$TAG'","listen":"127.0.0.1","port":'$SP',"protocol":"vless","settings":{"clients":[{"id":"'$UUID'","email":"'$EMAIL'","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":true,"dest":"'$dest'","serverNames":["'$sni'"],"privateKey":"'$PRIV'","shortIds":["'$SID'"]}}}'
  cat > server.json <<J
{"log":{"loglevel":"debug","error":"$D/server.log","access":"$D/access.log"},
 "api":{"tag":"api","services":["HandlerService","StatsService"]},
 "stats":{},
 "policy":{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true,"statsUserOnline":true}}},
 "inbounds":[{"tag":"api","listen":"127.0.0.1","port":$AP,"protocol":"tunnel","settings":{"address":"127.0.0.1"}},
  $INBOUND],
 "outbounds":[{"protocol":"freedom","tag":"direct","settings":{"finalRules":[{"action":"allow"}]}}],
 "routing":{"rules":[{"inboundTag":["api"],"outboundTag":"api"}]}}
J
  cat > client.json <<J
{"log":{"loglevel":"debug","error":"$D/client.log"},
 "inbounds":[{"tag":"socks-in","listen":"127.0.0.1","port":$CP,"protocol":"socks","settings":{"udp":false}}],
 "outbounds":[{"protocol":"vless","tag":"proxy",
  "settings":{"vnext":[{"address":"127.0.0.1","port":$SP,"users":[{"id":"$UUID","encryption":"none","flow":"xtls-rprx-vision"}]}]},
  "streamSettings":{"network":"tcp","security":"reality",
   "realitySettings":{"serverName":"$sni","fingerprint":"$fp","publicKey":"$PUB","shortId":"$SID"}}}]}
J
  printf '{"inbounds":[%s]}\n' "$INBOUND" > adduser.json
  chmod 600 ./*.json
}

say "3. 逐个试 dest 候选，直到 REALITY 握手真正打通"
GOOD=""
for spec in "${DESTS[@]}"; do
  IFS='|' read -r dest sni fp <<< "$spec"
  printf '  试 dest=%s fp=%s ... ' "$dest" "$fp"
  write_configs "$dest" "$sni" "$fp"
  if ! $XRAY run -test -c server.json >/dev/null 2>&1; then echo "配置校验失败"; continue; fi
  : > server.log; : > client.log
  $XRAY run -c server.json > server.out 2>&1 & SPID=$!
  $XRAY run -c client.json > client.out 2>&1 & CPID=$!
  ok=0
  for i in $(seq 1 20); do listening $SP && listening $AP && listening $CP && { ok=1; break; }; sleep 0.5; done
  if [ "$ok" = 1 ]; then
    R=$(curl -s -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:$CP --max-time 20 "$SMALL_URL")
  else
    R="启动失败"
  fi
  if [ "$R" = 200 ]; then
    echo "通（HTTP 200）"; GOOD="$spec"; PIDS+=("$SPID" "$CPID"); break
  fi
  echo "不通（$R）"
  grep -m2 -oE 'handshake did not complete[^"]*|server name mismatch[^"]*|unsupported TLS version[^"]*|authentication failed[^"]*|target sent incorrect[^"]*|failed to read client hello[^"]*' server.log 2>/dev/null | sed 's/^/      服务端：/'
  kill "$SPID" "$CPID" 2>/dev/null; sleep 1; kill -9 "$SPID" "$CPID" 2>/dev/null
done
if [ -z "$GOOD" ]; then
  echo "  所有 dest 候选都没打通，无法继续。诊断信息："
  echo "  --- server.log 尾部 ---"; tail -n 20 server.log
  echo "  --- client.log 尾部 ---"; tail -n 20 client.log
  exit 1
fi
echo "  采用：$GOOD   服务端 pid=$SPID  客户端 pid=$CPID"

say "4. 经代理限速下载本地 TLS 1.3 流（${RATE}/s），确认流量在走且 splice 生效"
SPLICE_B=$(grep -c 'CopyRawConn splice' server.log 2>/dev/null); SPLICE_B=${SPLICE_B:-0}
curl -sk --tlsv1.3 --socks5-hostname 127.0.0.1:$CP --limit-rate $RATE --max-time 600 -o "$D/dl.bin" "$BIG_URL" &
DLPID=$!; PIDS+=("$DLPID")
sample 8 "下载中"; FLOW0=$GROWTH
SPLICE_A=$(grep -c 'CopyRawConn splice' server.log 2>/dev/null); SPLICE_A=${SPLICE_A:-0}
SPLICE_N=$((SPLICE_A - SPLICE_B))
INNER=$(grep -oE 'XtlsFilterTls found tls 1\.[0-9]' client.log 2>/dev/null | tail -n 1)
echo "  8 秒增长 $FLOW0 字节；本次下载新增 splice $SPLICE_N 次；客户端判定内层：${INNER:-未见}"
[ "$FLOW0" -gt 0 ] || { echo "下载没有跑起来，退出。日志尾部："; tail -n 15 server.log client.log; exit 1; }

say "5. RemoveUser（预期：已有连接不受影响）"
$XRAY api rmu --server=127.0.0.1:$AP -tag=$TAG $EMAIL
sample 8 "移除后"; FLOW_RMU=$GROWTH

say "6. 将要销毁的连接（过滤条件：本地端口 $SP、状态 established）"
ss -Htnp state established "( sport = :$SP )" | tee targets.txt
N=$(wc -l < targets.txt)
BAD=$(awk '{print $3}' targets.txt | grep -vc ":$SP\$")
echo "  共 $N 条；本地端口不是 $SP 的 $BAD 条"
if [ "$N" -lt 1 ] || [ "$N" -gt 5 ] || [ "$BAD" -ne 0 ]; then echo "目标集合异常，放弃销毁并退出"; exit 1; fi
if [ "$DRYRUN" = 1 ]; then ANS=yes; else
  read -r -t 120 -p "  以上只有测试连接吗？输入 yes 执行销毁（120 秒不答视为放弃）：" ANS
fi
[ "${ANS:-}" = yes ] || { echo "未确认，放弃"; exit 1; }

say "7. 销毁 socket（ss -K，过滤条件与上一步完全相同）"
L0=$(wc -l < server.log)
ss -K -Htn state established "( sport = :$SP )"
echo "  宽限 1 秒后连续观察 5 秒："
sleep 1; sample 5 "销毁后"; FLOW_KILL=$GROWTH
if kill -0 "$DLPID" 2>/dev/null; then DL_STATE="curl 仍在运行"; else wait "$DLPID" 2>/dev/null; DL_STATE="curl 已退出（退出码 $?）"; fi
echo "  $DL_STATE"
LEFT=$(ss -Htn state established "( sport = :$SP )" | wc -l)
echo "  端口 $SP 上剩余 established 连接：$LEFT"
echo "  服务端日志中销毁后的相关行："
tail -n +$((L0 + 1)) server.log | grep -iE 'error|close|reset|abort|broken|splice|fail' | head -n 12 | sed 's/^/    /'

say "8. 被销毁连接的出站侧是否残留"
sleep 2
ss -Htnp state established | grep "pid=$SPID," | awk '$4 !~ /^127\.0\.0\.1:44313$/ && $3 !~ /:44310$/' | sed 's/^/    /' > linger.txt
if [ -s linger.txt ]; then cat linger.txt; LINGER=$(wc -l < linger.txt); else echo "  无（到本地数据源的出站连接单列在下一行）"; LINGER=0; fi
LP_LEFT=$(ss -Htn state established "( dport = :$LP )" | wc -l)
echo "  测试服务端到本地数据源（$LP）仍保持的连接：$LP_LEFT 条"

say "9. 被移除的用户发起新连接（预期：被拒）"
R1=$(curl -s -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:$CP --max-time 15 "$SMALL_URL"); echo "  HTTP=$R1"

say "10. AddUser（模拟新周期；预期：不重启核心即可重新连接）"
$XRAY api adu --server=127.0.0.1:$AP adduser.json
R2=$(curl -s -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:$CP --max-time 15 "$SMALL_URL"); echo "  HTTP=$R2"
kill -0 "$SPID" 2>/dev/null && SAME="是（pid $SPID 自始至终未变）" || SAME="否"

say "11. 生产 443 是否受影响"
PROD_PID1=$(ss -Hltnp '( sport = :443 )' | grep -oP 'pid=\K[0-9]+' | head -1)
PROD_N1=$(ss -Htn state established '( sport = :443 )' | wc -l)
echo "  pid：${PROD_PID0:-无} -> ${PROD_PID1:-无}   已建立连接：$PROD_N0 -> $PROD_N1（自然波动属正常）"

say "结论"
v() { printf '  %-40s %s\n' "$1" "$2"; }
v "采用的 dest / 指纹" "$GOOD"
v "内层 TLS（splice 前提）" "${INNER:-未见}"
[ "$SPLICE_N" -gt 0 ] && v "本次下载确实进入 splice" "是（新增 $SPLICE_N 次）" || v "本次下载确实进入 splice" "否 —— 结果不能代表 splice 场景"
[ "$FLOW_RMU" -gt 0 ] && v "RemoveUser 后已有连接继续传输" "是（8 秒 +$FLOW_RMU 字节，复现 S1）" || v "RemoveUser 后已有连接继续传输" "否（8 秒增长 $FLOW_RMU）"
[ "$FLOW_KILL" -eq 0 ] && v "销毁 socket 后传输停止" "是 ★核心结论" || v "销毁 socket 后传输停止" "否（5 秒仍增长 $FLOW_KILL 字节）★核心结论"
v "出站侧到数据源的残留连接" "$LP_LEFT 条"
[ "$R1" = 000 ] && v "移除后新连接被拒" "是" || v "移除后新连接被拒" "否（HTTP $R1）"
[ "$R2" = 200 ] && v "AddUser 后重连成功" "是" || v "AddUser 后重连成功" "否（HTTP $R2）"
v "测试服务端全程未重启" "$SAME"
[ "${PROD_PID0:-x}" = "${PROD_PID1:-x}" ] && v "生产 443 核心未受影响" "是（pid ${PROD_PID1:-无}）" || v "生产 443 核心未受影响" "否！pid ${PROD_PID0:-无} -> ${PROD_PID1:-无}"
[ "$DRYRUN" = 1 ] && echo "  （DRYRUN：当前环境不支持 SOCK_DESTROY，核心结论一项预期为否）"
echo
echo "测试进程已随脚本退出清理。一次性密钥与日志保留在 $D 供排查，看完可执行：rm -rf $D"
