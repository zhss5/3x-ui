"""Copy narrowly selected, unmodified source functions into a stdlib-only probe.

No application startup, external HTTP targets, or dependencies are needed.
The generated Go source is an extraction, not a full application test.
"""
from pathlib import Path
import re

ROOT = Path(r"C:\Users\zhang\AppData\Local\Temp\codex-3x-ui-audit-20260911")
OUT = Path(__file__).parent

def source(path):
    return (ROOT / path).read_text(encoding="utf-8")

def func(text, name):
    match = re.search(r"(?ms)^func " + re.escape(name) + r"\(.*?^}", text)
    if not match:
        raise RuntimeError(name)
    return match.group(0)

external = source("internal/sub/external_subscription.go")
selected = external[external.index("func doFetchSubscriptionLinks("):]
header = '''// Extracted from 3x-ui f727d04; network functions below are unchanged.
package probe
import (
 "context"
 "encoding/base64"
 "io"
 "net/http"
 "net/url"
 "strings"
 "time"
)
const subscriptionMaxBytes = 2 << 20
var subscriptionHTTPClient = &http.Client{Timeout: 6 * time.Second}
'''
text = header + selected + "\n" + func(source("internal/sub/external_config.go"), "padBase64Sub")
text += "\n" + func(source("internal/web/service/client_external_link.go"), "isHTTPURL") + "\n"
(OUT / "external_probe.go").write_text(text, encoding="utf-8")
netsafe = source("internal/util/netsafe/netsafe.go").replace("package netsafe", "package probe", 1)
(OUT / "netsafe_probe.go").write_text(netsafe, encoding="utf-8")
print("Extracted unchanged fetch/parse/URL-check functions and guarded dialer into", OUT)
