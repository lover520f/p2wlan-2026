package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yhan-sun/p2wlan/server/auth"
	"github.com/yhan-sun/p2wlan/server/database"
)

func TestRoomHTTPAuthenticationOwnershipAndDeviceProtocol(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "rooms.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	service := auth.NewService("test-secret-for-friend-rooms", db)
	a, au, err := service.Register("a@room-api.test", "account-password")
	if err != nil {
		t.Fatal(err)
	}
	b, bu, err := service.Register("b@room-api.test", "account-password")
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(service, nil, db)
	mux := http.NewServeMux()
	server.RegisterRoomRoutes(mux)
	mux.HandleFunc("POST /api/v1/devices", service.RequireAuth(server.RegisterDevice))
	mux.HandleFunc("PATCH /api/v1/devices/{id}", service.RequireAuth(server.UpdateDevice))
	mux.HandleFunc("GET /api/v1/nodes", auth.RequireAnyAuth(service, db)(server.ListNodes))
	request := func(method, path, token string, body any, want int) map[string]any {
		t.Helper()
		payload, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(method, path, bytes.NewReader(payload))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Fatalf("%s %s: got %d want %d: %s", method, path, rec.Code, want, rec.Body.String())
		}
		result := map[string]any{}
		if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(rec.Body.String(), "safe-room-password") || strings.Contains(rec.Body.String(), "password_hash") || strings.Contains(rec.Body.String(), "token_hash") {
			t.Fatal("room secret in response")
		}
		return result
	}
	request("GET", "/api/v1/rooms", "", nil, 401)
	request("POST", "/api/v1/rooms", a, map[string]any{"name": "room", "password": "safe-room-password", "owner_id": bu.ID}, 400)
	created := request("POST", "/api/v1/rooms", a, map[string]any{"name": "room", "password": "safe-room-password"}, 201)["room"].(map[string]any)
	roomID, code := created["id"].(string), created["room_code"].(string)
	if created["owner_id"] != au.ID {
		t.Fatal("owner not derived from authentication")
	}
	base := "/api/v1/rooms/" + roomID
	request("POST", "/api/v1/rooms", a, map[string]any{"name": "room2", "password": "safe-room-password"}, 409)
	request("GET", base, b, nil, 403)
	request("POST", "/api/v1/rooms/join", b, map[string]any{"room_code": code, "password": "wrong-password"}, 403)
	request("POST", "/api/v1/rooms/join", b, map[string]any{"room_code": code, "password": "safe-room-password"}, 200)
	request("GET", base, b, nil, 200)
	request("PATCH", base, b, map[string]any{"name": "hijacked"}, 403)
	request("POST", base+"/invites", b, map[string]any{}, 403)
	request("DELETE", base+"/members/"+au.ID, b, nil, 403)
	old := map[string]any{"network_id": roomID, "public_key": strings.Repeat("a", 64), "device_name": "member"}
	request("POST", "/api/v1/devices", b, old, 426)
	old["room_protocol_version"] = 1
	old["virtual_ip"] = "10.21.1.9"
	request("POST", "/api/v1/devices", b, old, 403)
	delete(old, "virtual_ip")
	device := request("POST", "/api/v1/devices", b, old, 200)
	deviceID, ok := device["node_id"].(string)
	if !ok {
		t.Fatalf("missing registration: %v", device)
	}
	request("PATCH", "/api/v1/devices/"+deviceID, b, map[string]any{"virtual_ip": "10.21.1.9"}, 403)
	_, credential, err := db.CreateDeviceCredential(deviceID, 3600)
	if err != nil {
		t.Fatal(err)
	}
	request("GET", "/api/v1/rooms", credential, nil, 401)
	roster := request("GET", "/api/v1/nodes?network_id="+roomID, credential, nil, 200)
	if roster["authorization_lease_seconds"] != float64(30) {
		t.Fatal("missing room authorization lease")
	}
	request("PATCH", base+"/devices/"+deviceID, a, map[string]any{"virtual_ip": "10.21.1.40"}, 200)
	request("GET", "/api/v1/nodes?network_id="+roomID, credential, nil, 401)
	request("PUT", base+"/bans/"+bu.ID, a, nil, 200)
	request("GET", base, b, nil, 403)
	request("POST", "/api/v1/rooms/join", b, map[string]any{"room_code": code, "password": "safe-room-password"}, 403)
	request("DELETE", base+"/bans/"+bu.ID, a, nil, 200)
	invite := request("POST", base+"/invites", a, map[string]any{"ttl_seconds": 600, "max_uses": 1}, 201)
	request("POST", "/api/v1/rooms/join", b, map[string]any{"room_code": code, "invite_token": invite["invite_token"]}, 200)
	request("POST", base+"/leave", b, nil, 200)
	request("DELETE", base, a, nil, 200)
	request("GET", base, a, nil, 403)
}

func TestRoomHTTPRejectsOversizedAndTrailingJSON(t *testing.T) {
	for _, body := range []string{`{"name":"ok"}{}`, fmt.Sprintf(`{"name":"%s"}`, strings.Repeat("x", 20<<10))} {
		req := httptest.NewRequest("POST", "/", strings.NewReader(body))
		rec := httptest.NewRecorder()
		var parsed struct {
			Name string `json:"name"`
		}
		if roomBody(rec, req, &parsed) || rec.Code != 400 {
			t.Fatalf("unsafe request accepted: %d", rec.Code)
		}
	}
}
