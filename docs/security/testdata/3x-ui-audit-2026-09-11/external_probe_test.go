package probe

import (
 "context"
 "errors"
 "fmt"
 "net/http"
 "net/http/httptest"
 "net/url"
 "sync/atomic"
 "testing"
)

// These tests characterize unsafe behavior; PASS means the reachability gap
// was reproduced, not that the application passed a security regression test.
func TestExternalSubscriptionReachesLoopback(t *testing.T) {
 var hits atomic.Int32
 local := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
  hits.Add(1)
  fmt.Fprintln(w, "vless://audit-placeholder@example.invalid:443")
 }))
 defer local.Close()
 if !isHTTPURL(local.URL) { t.Fatal("actual URL validator rejected test URL") }
 links, err := doFetchSubscriptionLinks(local.URL)
 if err != nil || hits.Load() != 1 || len(links) != 1 {
  t.Fatalf("fetch result: hits=%d links=%d err=%v", hits.Load(), len(links), err)
 }
 t.Log("actual external-subscription functions accepted and fetched a loopback URL")
}

func TestExternalSubscriptionFollowsRedirectToLoopback(t *testing.T) {
 var hits atomic.Int32
 local := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
  hits.Add(1)
  fmt.Fprintln(w, "vless://audit-placeholder@example.invalid:443")
 }))
 defer local.Close()
 redirector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
  http.Redirect(w, r, local.URL, http.StatusFound)
 }))
 defer redirector.Close()
 _, err := doFetchSubscriptionLinks(redirector.URL)
 if err != nil || hits.Load() != 1 { t.Fatalf("hits=%d err=%v", hits.Load(), err) }
 t.Log("redirect followed to second loopback server; both servers stayed local")
}

func TestExistingGuardRejectsSameLoopbackTarget(t *testing.T) {
 local := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
  t.Error("guarded dialer must not connect")
 }))
 defer local.Close()
 parsed, err := url.Parse(local.URL)
 if err != nil { t.Fatal(err) }
 conn, err := SSRFGuardedDialContext(context.Background(), "tcp", parsed.Host)
 if conn != nil { conn.Close(); t.Fatal("unexpected connection") }
 if !errors.Is(err, ErrPrivateAddressBlocked) { t.Fatalf("guard result: %v", err) }
 t.Log("existing netsafe guard rejects identical target; external fetch does not use it")
}
