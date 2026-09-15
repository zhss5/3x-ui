#!/usr/bin/env python3
"""Turn a bare Xray inbound from config.json into a 3x-ui /panel/api/inbounds/add payload.

Runs entirely on the node. Secrets (REALITY privateKey, client UUIDs) go straight
from the local config into the local payload file and are never printed.

  python3 make-inbound-payload.py --port 44300 --email user1@vm44212

Then review payload.json (the preview below is redacted; the file is not) and POST it.
"""
import argparse
import hashlib
import json
import os
import socket
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--config", default="/usr/local/etc/xray/config.json")
ap.add_argument("--out", default="payload.json")
ap.add_argument("--port", type=int, required=True,
                help="staging port for the panel inbound; must NOT be the live port")
ap.add_argument("--email", default="",
                help="email to assign to clients that have none (server-side stats label; "
                     "invisible to clients, so adding it changes nothing for existing users)")
ap.add_argument("--tag", default="", help="inbound tag; must be unique across every node")
ap.add_argument("--remark", default="", help="panel display name")
args = ap.parse_args()

cfg = json.load(open(args.config))
inbounds = [i for i in cfg.get("inbounds", []) if i.get("protocol") == "vless"]
if not inbounds:
    sys.exit("no vless inbound found in %s" % args.config)
if len(inbounds) > 1:
    sys.exit("found %d vless inbounds; this script handles one. Split them by hand." % len(inbounds))
ib = inbounds[0]

live_port = ib.get("port")
if args.port == live_port:
    sys.exit("--port %d is the LIVE port. Stage on a different one, then swap after verifying."
             % live_port)

host = socket.gethostname().split(".")[0]
tag = args.tag or "in-%s-%d" % (host, live_port)
remark = args.remark or "migrated-%s" % host

settings = json.loads(json.dumps(ib.get("settings", {})))   # deep copy
clients = settings.get("clients", [])
if not clients:
    sys.exit("inbound has no clients")

patched_email, patched_enable = 0, 0
for idx, c in enumerate(clients):
    # Without enable=true the panel writes Enable=false into client_traffics and
    # config generation silently drops the client (a green panel with zero users).
    if "enable" not in c:
        c["enable"] = True
        patched_enable += 1
    if not c.get("email"):
        base = args.email or ("user@%s" % host)
        c["email"] = base if len(clients) == 1 else "%s-%d" % (base, idx + 1)
        patched_email += 1

stream = ib.get("streamSettings", {})
sniff = ib.get("sniffing", {"enabled": False})

payload = {
    "remark": remark,
    "enable": True,
    "listen": ib.get("listen", "") or "",
    "port": args.port,
    "protocol": "vless",
    "tag": tag,
    "settings": json.dumps(settings, separators=(",", ":")),
    "streamSettings": json.dumps(stream, separators=(",", ":")),
    "sniffing": json.dumps(sniff, separators=(",", ":")),
}

with open(args.out, "w") as f:
    json.dump(payload, f, indent=2)
os.chmod(args.out, 0o600)


def h16(s):
    return hashlib.sha256(s.encode()).hexdigest()[:16]


r = stream.get("realitySettings", {}) or {}
print("wrote %s (mode 600)\n" % args.out)
print("--- REDACTED PREVIEW - check every line ---")
print("  tag            %s" % tag)
print("  remark         %s" % remark)
print("  listen         %r" % payload["listen"])
print("  port           %d   (LIVE port is %d - swap after verifying)" % (args.port, live_port))
print("  protocol       vless")
print("  network        %s" % stream.get("network"))
print("  security       %s" % stream.get("security"))
print("  reality.dest         %s" % r.get("dest"))
print("  reality.serverNames  %s" % r.get("serverNames"))
print("  reality.shortIds     %s" % r.get("shortIds"))
print("  reality.privateKey   <%d chars, sha256[:16]=%s>"
      % (len(r.get("privateKey", "")), h16(r.get("privateKey", ""))))
print("  decryption     %s" % settings.get("decryption"))
print("  clients        %d" % len(clients))
for c in clients:
    print("     email=%-22s flow=%-18s id=<%d chars, sha256[:16]=%s> enable=%s"
          % (c.get("email"), c.get("flow", ""), len(c.get("id", "")), h16(c.get("id", "")), c.get("enable")))
print()
print("patched: %d client(s) given an email, %d given enable=true" % (patched_email, patched_enable))
print()
print("privateKey sha256[:16] = %s   <-- must still match AFTER the panel takes over"
      % h16(r.get("privateKey", "")))
