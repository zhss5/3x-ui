package service

// S1 experiment 1 probe (NOT a landed regression test): what happens to a
// traffic delta when the client_traffics UPDATE fails? Delete after recording.

import (
	"context"
	"errors"
	"net"
	"strings"
	"testing"

	statsService "github.com/xtls/xray-core/app/stats/command"
	"google.golang.org/grpc"
	"gorm.io/gorm"

	"github.com/mhsanaei/3x-ui/v3/internal/database/model"
	"github.com/mhsanaei/3x-ui/v3/internal/xray"
)

type probeStatsServer struct {
	statsService.UnimplementedStatsServiceServer
	rounds [][]*statsService.Stat
	calls  int
}

func (f *probeStatsServer) QueryStats(context.Context, *statsService.QueryStatsRequest) (*statsService.QueryStatsResponse, error) {
	round := f.calls
	f.calls++
	if round >= len(f.rounds) {
		round = len(f.rounds) - 1
	}
	return &statsService.QueryStatsResponse{Stat: f.rounds[round]}, nil
}

func probeStat(name string, value int64) *statsService.Stat {
	return &statsService.Stat{Name: name, Value: value}
}

func startProbeStats(t *testing.T, rounds [][]*statsService.Stat) *xray.XrayAPI {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := grpc.NewServer()
	statsService.RegisterStatsServiceServer(srv, &probeStatsServer{rounds: rounds})
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	api := &xray.XrayAPI{}
	if err := api.Init(lis.Addr().(*net.TCPAddr).Port); err != nil {
		t.Fatalf("api init: %v", err)
	}
	t.Cleanup(api.Close)
	return api
}

func TestProbeTrafficDeltaSurvivesFailedCommit(t *testing.T) {
	db := initTrafficTestDB(t)
	svc := &InboundService{}

	ib := &model.Inbound{
		UserId: 1, Tag: "in-local", Enable: true, Port: 44001,
		Protocol: model.VLESS,
		Settings: `{"clients":[{"email":"alice@x","enable":true}]}`,
	}
	if err := db.Create(ib).Error; err != nil {
		t.Fatalf("seed inbound: %v", err)
	}
	if err := db.Create(&xray.ClientTraffic{InboundId: ib.Id, Email: "alice@x", Enable: true}).Error; err != nil {
		t.Fatalf("seed client traffic row: %v", err)
	}

	const (
		up1, down1 = int64(1000), int64(2000)
		up2, down2 = int64(1500), int64(3000) // +500 / +1000 of real traffic
	)
	api := startProbeStats(t, [][]*statsService.Stat{
		{probeStat("user>>>alice@x>>>traffic>>>uplink", up1), probeStat("user>>>alice@x>>>traffic>>>downlink", down1)},
		{probeStat("user>>>alice@x>>>traffic>>>uplink", up2), probeStat("user>>>alice@x>>>traffic>>>downlink", down2)},
		// Counters stay put: the client sent nothing more after the failed write.
		{probeStat("user>>>alice@x>>>traffic>>>uplink", up2), probeStat("user>>>alice@x>>>traffic>>>downlink", down2)},
	})

	if _, _, err := api.GetTraffic(); err != nil {
		t.Fatalf("baseline GetTraffic: %v", err)
	}

	_, clients, err := api.GetTraffic()
	if err != nil {
		t.Fatalf("delta GetTraffic: %v", err)
	}
	if len(clients) != 1 || clients[0].Up != 500 || clients[0].Down != 1000 {
		t.Fatalf("round 2 reported %+v, want one client with up=500 down=1000", clients)
	}
	t.Logf("STEP 1  core metered a real delta, handed to the panel: up=%d down=%d", clients[0].Up, clients[0].Down)

	// addClientTraffic writes through tx.Exec, so the failure has to be injected
	// on the raw callback, not the update one.
	injected := 0
	const cbName = "s1-probe:fail-client-traffics-exec"
	if err := db.Callback().Raw().Before("gorm:raw").Register(cbName, func(tx *gorm.DB) {
		if tx.Statement == nil {
			return
		}
		sql := strings.ToLower(tx.Statement.SQL.String())
		if strings.HasPrefix(sql, "update client_traffics set up") {
			injected++
			tx.AddError(errors.New("injected client_traffics UPDATE failure"))
		}
	}); err != nil {
		t.Fatalf("register callback: %v", err)
	}

	_, _, addErr := svc.AddTraffic(nil, clients)
	if err := db.Callback().Raw().Remove(cbName); err != nil {
		t.Fatalf("remove callback: %v", err)
	}
	if injected == 0 {
		t.Fatalf("injection never fired — the probe did not reach the client_traffics UPDATE")
	}
	t.Logf("STEP 2  injected %d client_traffics UPDATE failure(s); AddTraffic returned err=%v", injected, addErr)
	if addErr == nil {
		t.Logf("STEP 2a SILENT: the write failed but AddTraffic reported success, so the caller has no error to act on")
	}

	var afterFailure xray.ClientTraffic
	if err := db.Where("email = ?", "alice@x").First(&afterFailure).Error; err != nil {
		t.Fatalf("reload after failure: %v", err)
	}
	t.Logf("STEP 3  ledger after the failed write: up=%d down=%d", afterFailure.Up, afterFailure.Down)

	// Next poll, core counters unchanged. A lossless design re-surfaces the
	// uncommitted delta here; this one moved its baseline past it in step 1.
	_, clients3, err := api.GetTraffic()
	if err != nil {
		t.Fatalf("re-poll GetTraffic: %v", err)
	}
	t.Logf("STEP 4  re-poll returned %d entries (baseline already advanced past the lost delta)", len(clients3))
	if _, _, err := svc.AddTraffic(nil, clients3); err != nil {
		t.Fatalf("re-poll AddTraffic: %v", err)
	}

	var final xray.ClientTraffic
	if err := db.Where("email = ?", "alice@x").First(&final).Error; err != nil {
		t.Fatalf("reload final: %v", err)
	}
	t.Logf("STEP 5  final ledger: up=%d down=%d", final.Up, final.Down)
	if final.Up != 500 || final.Down != 1000 {
		t.Fatalf("DELTA LOST: ledger holds up=%d down=%d after a failed write plus a healthy re-poll, want up=500 down=1000 (the core did meter 500/1000)", final.Up, final.Down)
	}
}
