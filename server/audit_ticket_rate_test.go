package main

import (
	"fmt"
	"github.com/yhan-sun/p2wlan/server/api"
	"github.com/yhan-sun/p2wlan/server/auth"
	"github.com/yhan-sun/p2wlan/server/database"
	"github.com/yhan-sun/p2wlan/server/signaling"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestAuditIndependentDevicesBehindSameNATGetTickets(t *testing.T) {
	t.Setenv("RELAY_CATALOG_JSON", `[{"region":"test","audience":"relay-test","endpoint":"tls://relay.example.com:18081"}]`)
	t.Setenv("RELAY_TICKET_SIGNER_JSON", `{"active":{"kid":"test-key","private_key":"0101010101010101010101010101010101010101010101010101010101010101"}}`)
	t.Setenv("RELAY_TICKET_SIGNER_KEY_FILE", "")
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	user, err := db.CreateUser("audit@example.test", "unused")
	if err != nil {
		t.Fatal(err)
	}
	service := auth.NewService("audit-local-test", db)
	hub := signaling.NewHub()
	defer hub.Close()
	apiServer := api.NewServer(service, hub, db)
	mux := http.NewServeMux()
	registerDeviceControlRoutes(mux, service, db, apiServer, hub)
	for i := 0; i < 8; i++ {
		device, err := db.CreateDevice(user.ID, "default", fmt.Sprintf("audit-device-%d", i), "audit", "linux", "")
		if err != nil {
			t.Fatal(err)
		}
		_, token, err := db.CreateDeviceCredential(device.ID, 3600)
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest("POST", "/api/v1/relay/tickets", strings.NewReader(`{"audience":"relay-test","region":"test"}`))
		req.RemoteAddr = fmt.Sprintf("203.0.113.2:%d", 40000+i)
		req.Header.Set("Authorization", "Bearer "+token)
		out := httptest.NewRecorder()
		mux.ServeHTTP(out, req)
		t.Logf("independent device %d, first ticket request: HTTP %d", i+1, out.Code)
		if out.Code != http.StatusOK {
			t.Errorf("device %d is blocked by another device's requests: HTTP %d %s", i+1, out.Code, out.Body.String())
		}
	}
}
