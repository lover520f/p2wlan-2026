package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/yhan-sun/p2wlan/server/auth"
	"github.com/yhan-sun/p2wlan/server/database"
)

func TestRoomDeviceControlsHTTP(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	service := auth.NewService("room-device-controls-test-secret", db)
	owner, _, err := service.Register("owner@device.test", "account-password")
	if err != nil {
		t.Fatal(err)
	}
	member, _, err := service.Register("member@device.test", "account-password")
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(service, nil, db)
	mux := http.NewServeMux()
	server.RegisterRoomRoutes(mux)
	mux.HandleFunc("POST /api/v1/devices", auth.RequireAnyAuth(service, db)(server.RegisterDevice))
	mux.HandleFunc("GET /api/v1/nodes", auth.RequireAnyAuth(service, db)(server.ListNodes))
	request := func(method, path, token string, body any, want int) map[string]any {
		t.Helper()
		payload, _ := json.Marshal(body)
		req := httptest.NewRequest(method, path, bytes.NewReader(payload))
		req.Header.Set("Authorization", "Bearer "+token)
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, req)
		if recorder.Code != want {
			t.Fatalf("%s %s got %d want %d: %s", method, path, recorder.Code, want, recorder.Body.String())
		}
		var result map[string]any
		if err := json.Unmarshal(recorder.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	room := request("POST", "/api/v1/rooms", owner, map[string]any{"name": "room", "password": "safe-password"}, 201)["room"].(map[string]any)
	base := "/api/v1/rooms/" + room["id"].(string)
	request("POST", "/api/v1/rooms/join", member, map[string]any{"room_code": room["room_code"], "password": "safe-password"}, 200)
	request("PUT", base+"/device-policy", member, map[string]any{"require_approval": true}, 403)
	request("PUT", base+"/device-policy", owner, map[string]any{}, 400)
	request("PUT", base+"/device-policy", owner, map[string]any{"require_approval": true}, 200)
	payload := map[string]any{"public_key": "my-device-key", "device_name": "laptop", "platform": "linux", "resume": true}
	denied := request("POST", base+"/device-access", member, payload, 403)
	if denied["error_code"] != "room_device_pending" {
		t.Fatal(denied)
	}
	roster := request("GET", base, owner, nil, 200)
	access := roster["device_access"].([]any)[0].(map[string]any)["id"].(string)
	action := base + "/device-access/" + access
	request("POST", action+"/approve", member, nil, 403)
	request("POST", action+"/approve", owner, nil, 200)
	request("POST", base+"/device-access", member, payload, 200)
	registration := map[string]any{"network_id": room["id"], "public_key": "my-device-key", "device_name": "laptop", "platform": "linux", "room_protocol_version": 1}
	device := request("POST", "/api/v1/devices", member, registration, 200)
	_, credential, err := db.CreateDeviceCredential(device["node_id"].(string), 3600)
	if err != nil {
		t.Fatal(err)
	}
	request("POST", action+"/disconnect", credential, nil, 401)
	request("POST", action+"/disconnect", member, nil, 200)
	request("GET", "/api/v1/nodes?network_id="+room["id"].(string), credential, nil, 401)
	if request("POST", "/api/v1/devices", member, registration, 403)["error_code"] != "room_device_paused" {
		t.Fatal("registration did not enforce remote pause")
	}
	request("POST", action+"/block", owner, nil, 200)
	request("POST", action+"/unblock", member, nil, 403)
	if request("POST", base+"/device-access", member, payload, 403)["error_code"] != "room_device_blocked" {
		t.Fatal("account JWT bypassed device block")
	}
}
