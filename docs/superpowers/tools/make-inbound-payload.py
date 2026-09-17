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
import subprocess
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
ap.add_argument("--pbk", default="",
                help="REALITY publicKey for the panel-only realitySettings.settings sidecar. "
                     "Copy it from a working client config; without it the panel renders "
                     "links with no pbk/fp and they cannot connect. Derived from privateKey "
                     "via --xray-bin when omitted.")
ap.add_argument("--xray-bin", default="/usr/local/x-ui/bin/xray-linux-amd64",
                help="used only to derive --pbk when it is not supplied")
ap.add_argument("--fingerprint", default="chrome", help="client TLS fingerprint for the sidecar")
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

stream = json.loads(json.dumps(ib.get("streamSettings", {})))   # deep copy
sniff = ib.get("sniffing", {"enabled": False})


def derive_pbk(private_key, xray_bin):
    """Ask the pinned xray binary for the public key matching private_key.

    Its output is three labelled lines; this version spells the one we want
    "Password (PublicKey):". Returns "" when the binary is absent or fails.
    """
    try:
        out = subprocess.run([xray_bin, "x25519", "-i", private_key],
                             capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in (out.stdout or "").splitlines():
        label, sep, value = line.partition(":")
        if not sep:
            continue
        label = label.strip().lower()
        if "private" in label:
            continue
        if "public" in label or "password" in label:
            return value.strip()
    return ""


# A bare Xray server config carries no public key -- the server never needs it.
# Without this panel-only sidecar every generated link/subscription omits pbk
# and fp, so no client can handshake (machine A shipped broken this way).
sidecar_note = "already present, left alone"
if (stream.get("security") or "") == "reality":
    reality = stream.setdefault("realitySettings", {})
    if not reality.get("settings"):
        pbk = args.pbk.strip() or derive_pbk(reality.get("privateKey", ""), args.xray_bin)
        if not pbk:
            sys.exit("could not determine the REALITY publicKey: pass --pbk (copy it from a "
                     "working client config) or point --xray-bin at the xray binary")
        reality["settings"] = {
            "publicKey": pbk,
            "fingerprint": args.fingerprint,
            "serverName": "",
            "spiderX": "/",
            "mldsa65Verify": "",
        }
        sidecar_note = "added (%s)" % ("from --pbk" if args.pbk.strip() else "derived from privateKey")
else:
    sidecar_note = "n/a (security is not reality)"

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
print("  reality.settings     %s" % sidecar_note)
_sc = r.get("settings") or {}
if _sc:
    print("     publicKey   <%d chars, sha256[:16]=%s>"
          % (len(_sc.get("publicKey", "")), h16(_sc.get("publicKey", ""))))
    print("     fingerprint %s" % _sc.get("fingerprint"))
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
