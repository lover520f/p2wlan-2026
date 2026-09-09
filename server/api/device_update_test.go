package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/yhan-sun/p2wlan/server/auth"
	"github.com/yhan-sun/p2wlan/server/database"
)

func TestParseRelayServersReturnsEmptySliceWhenUnset(t *testing.T) {
	t.Setenv("RELAY_SERVERS", "")

	servers := parseRelayServers()
	if servers == nil {
		t.Fatal("expected an empty slice, got nil")
	}
	if len(servers) != 0 {
		t.Fatalf("expected no relay servers, got %v", servers)
	}

	encoded, err := json.Marshal(map[string][]string{"relay_servers": servers})
	if err != nil {
		t.Fatalf("marshal relay servers: %v", err)
	}
	if string(encoded) != `{"relay_servers":[]}` {
		t.Fatalf("expected empty JSON array, got %s", encoded)
	}
}

func TestParseRelayServersTrimsAndSkipsEmptyItems(t *testing.T) {
	t.Setenv("RELAY_SERVERS", " default@control.example.com:18081, ,backup@example.com:18081 ")

	servers := parseRelayServers()
	want := []string{"default@control.example.com:18081", "backup@example.com:18081"}
	if len(servers) != len(want) {
		t.Fatalf("expected %d relay servers, got %d: %v", len(want), len(servers), servers)
	}
	for i := range want {
		if servers[i] != want[i] {
			t.Fatalf("server %d: expected %q, got %q", i, want[i], servers[i])
		}
	}
}

func TestUpdateDeviceRenamesOwnedDevice(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("database.New: %v", err)
	}
	defer db.Close()
	user, err := db.CreateUser("owner@example.com", "hash")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	device, err := db.CreateDevice(user.ID, "default", "rename-key", "old-name", "macos", "")
	if err != nil {
		t.Fatalf("CreateDevice: %v", err)
	}

	server := NewServer(nil, nil, db)
	req := httptest.NewRequest(http.MethodPatch, "/api/v1/devices/"+device.ID, strings.NewReader(`{"device_name":"  Studio Mac  "}`))
	req.SetPathValue("id", device.ID)
	req = req.WithContext(context.WithValue(req.Context(), auth.UserClaimsKey, &auth.Claims{UserID: user.ID}))
	recorder := httptest.NewRecorder()

	server.UpdateDevice(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}
	updated, err := db.GetDevice(device.ID)
	if err != nil {
		t.Fatalf("GetDevice: %v", err)
	}
	if updated.DeviceName != "Studio Mac" {
		t.Fatalf("expected trimmed device name, got %q", updated.DeviceName)
	}
}

func TestRegisterDeviceStoresRequestedIPAndVersion(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("database.New: %v", err)
	}
	defer db.Close()
	user, err := db.CreateUser("register-version@example.com", "hash")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	server := NewServer(nil, nil, db)
	body := strings.NewReader(`{"public_key":"register-version-key","device_name":"Studio","platform":"macos","network_id":"default","virtual_ip":"10.20.0.44","app_version":"0.1.68"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/devices", body)
	req = req.WithContext(context.WithValue(req.Context(), auth.UserClaimsKey, &auth.Claims{UserID: user.ID}))
	recorder := httptest.NewRecorder()

	server.RegisterDevice(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		Success   bool   `json:"success"`
		NodeID    string `json:"node_id"`
		VirtualIP string `json:"virtual_ip"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !response.Success || response.VirtualIP != "10.20.0.44" || response.NodeID == "" {
		t.Fatalf("unexpected register response: %+v", response)
	}
	device, err := db.GetDeviceByPublicKey("default", "register-version-key")
	if err != nil {
		t.Fatalf("GetDeviceByPublicKey: %v", err)
	}
	if device.AppVersion != "0.1.68" {
		t.Fatalf("expected stored app version, got %q", device.AppVersion)
	}
}

func TestDeviceCredentialReregistrationKeepsDeviceOnlyAuthenticationAfterResponseLoss(t *testing.T) {
	t.Setenv("RELAY_CATALOG_JSON", `[{"region":"test","audience":"relay-test","endpoint":"tls://relay.example.com:18081"}]`)
	t.Setenv("RELAY_TICKET_SIGNER_JSON", `{"active":{"kid":"test-key","private_key":"0101010101010101010101010101010101010101010101010101010101010101"}}`)
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("database.New: %v", err)
	}
	defer db.Close()

	user, err := db.CreateUser("device-reregister@example.com", "hash")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	device, err := db.CreateDevice(user.ID, "default", "device-reregister-key", "before", "macos", "")
	if err != nil {
		t.Fatalf("CreateDevice: %v", err)
	}
	_, credential, err := db.CreateDeviceCredential(device.ID, 3600)
	if err != nil {
		t.Fatalf("CreateDeviceCredential: %v", err)
	}

	// The handlers are wrapped in the real credential middleware. The token is
	// deliberately not a user JWT, so any success below proves there was no
	// user-token fallback after the registration response was dropped.
	service := auth.NewService("credential-reregister-test", db)
	server := NewServer(service, nil, db)
	register := auth.RequireAnyAuth(service, db)(server.RegisterDevice)

	registrationReq := httptest.NewRequest(
		http.MethodPost,
		"/api/v1/devices",
		strings.NewReader(`{"public_key":"device-reregister-key","device_name":"after","platform":"macos","network_id":"default","registration_incarnation":100}`),
	)
	registrationReq.Header.Set("Authorization", "Bearer "+credential)
	registrationRecorder := httptest.NewRecorder()
	register(registrationRecorder, registrationReq)
	if registrationRecorder.Code != http.StatusOK {
		t.Fatalf("device-authenticated re-registration: HTTP %d %s", registrationRecorder.Code, registrationRecorder.Body.String())
	}

	var registrationResponse struct {
		Success                 bool   `json:"success"`
		RegistrationSeq         int64  `json:"registration_seq"`
		RegistrationIncarnation int64  `json:"registration_incarnation"`
		DeviceCredential        string `json:"device_credential"`
	}
	if err := json.Unmarshal(registrationRecorder.Body.Bytes(), &registrationResponse); err != nil {
		t.Fatalf("decode registration response: %v", err)
	}
	if !registrationResponse.Success || registrationResponse.RegistrationSeq != 2 || registrationResponse.RegistrationIncarnation != 100 {
		t.Fatalf("unexpected registration response: %+v", registrationResponse)
	}
	if registrationResponse.DeviceCredential != "" {
		t.Fatalf("credential-preserving re-registration must not unexpectedly rotate into the response: %+v", registrationResponse)
	}

	// The first response is intentionally ignored. A same-incarnation retry
	// must be idempotent: the server must not clear state or consume another
	// registration sequence while the daemon is recovering from a lost reply.
	replayReq := httptest.NewRequest(
		http.MethodPost,
		"/api/v1/devices",
		strings.NewReader(`{"public_key":"device-reregister-key","device_name":"after","platform":"macos","network_id":"default","registration_incarnation":100}`),
	)
	replayReq.Header.Set("Authorization", "Bearer "+credential)
	replayRecorder := httptest.NewRecorder()
	register(replayRecorder, replayReq)
	if replayRecorder.Code != http.StatusOK {
		t.Fatalf("same-incarnation registration replay: HTTP %d %s", replayRecorder.Code, replayRecorder.Body.String())
	}
	var replayResponse struct {
		RegistrationSeq int64 `json:"registration_seq"`
	}
	if err := json.Unmarshal(replayRecorder.Body.Bytes(), &replayResponse); err != nil {
		t.Fatalf("decode replay response: %v", err)
	}
	if replayResponse.RegistrationSeq != registrationResponse.RegistrationSeq {
		t.Fatalf("same-incarnation replay advanced registration sequence: got %d want %d", replayResponse.RegistrationSeq, registrationResponse.RegistrationSeq)
	}

	// Ignore the response after its server-side completion, as if it was lost.
	// The persisted credential must still authenticate the daemon's next
	// endpoint heartbeat without a user JWT.
	endpoint := auth.RequireDeviceAuth(db)(server.UpdateDeviceEndpoint)
	endpointReq := httptest.NewRequest(
		http.MethodPatch,
		"/api/v1/devices/"+device.ID+"/endpoint",
		strings.NewReader(`{"endpoint":"198.51.100.88:51820","nat_type":"p2v2:m=endpoint_independent;g=1;l=2"}`),
	)
	endpointReq.SetPathValue("id", device.ID)
	endpointReq.Header.Set("Authorization", "Bearer "+credential)
	endpointRecorder := httptest.NewRecorder()
	endpoint(endpointRecorder, endpointReq)
	if endpointRecorder.Code != http.StatusOK {
		t.Fatalf("device credential did not authenticate endpoint heartbeat after re-registration: HTTP %d %s", endpointRecorder.Code, endpointRecorder.Body.String())
	}

	updated, err := db.GetDevice(device.ID)
	if err != nil {
		t.Fatalf("GetDevice: %v", err)
	}
	if updated.Endpoint != "198.51.100.88:51820" || updated.NATType != "p2v2:m=endpoint_independent;g=1;l=2" || !updated.Online {
		t.Fatalf("device-only heartbeat did not publish the new incarnation: %+v", updated)
	}

	// A delayed duplicate may arrive after the daemon already published its
	// endpoint. It must retain those facts as well as the registration sequence.
	postHeartbeatReplayReq := httptest.NewRequest(
		http.MethodPost,
		"/api/v1/devices",
		strings.NewReader(`{"public_key":"device-reregister-key","device_name":"after","platform":"macos","network_id":"default","registration_incarnation":100}`),
	)
	postHeartbeatReplayReq.Header.Set("Authorization", "Bearer "+credential)
	postHeartbeatReplayRecorder := httptest.NewRecorder()
	register(postHeartbeatReplayRecorder, postHeartbeatReplayReq)
	if postHeartbeatReplayRecorder.Code != http.StatusOK {
		t.Fatalf("post-heartbeat same-incarnation replay: HTTP %d %s", postHeartbeatReplayRecorder.Code, postHeartbeatReplayRecorder.Body.String())
	}
	updated, err = db.GetDevice(device.ID)
	if err != nil {
		t.Fatalf("GetDevice after post-heartbeat replay: %v", err)
	}
	if updated.RegistrationSeq != 2 || updated.Endpoint != "198.51.100.88:51820" || updated.NATType != "p2v2:m=endpoint_independent;g=1;l=2" {
		t.Fatalf("same-incarnation replay cleared live endpoint facts: %+v", updated)
	}

	listNodes := auth.RequireAnyAuth(service, db)(server.ListNodes)
	listReq := httptest.NewRequest(http.MethodGet, "/api/v1/nodes", nil)
	listReq.Header.Set("Authorization", "Bearer "+credential)
	listRecorder := httptest.NewRecorder()
	listNodes(listRecorder, listReq)
	if listRecorder.Code != http.StatusOK {
		t.Fatalf("device credential did not authenticate roster fetch: HTTP %d %s", listRecorder.Code, listRecorder.Body.String())
	}

	relayTicket := auth.RequireDeviceAuth(db)(server.CreateRelayTicket)
	ticketReq := httptest.NewRequest(http.MethodPost, "/api/v1/relay/tickets", strings.NewReader(`{"audience":"relay-test"}`))
	ticketReq.Header.Set("Authorization", "Bearer "+credential)
	ticketRecorder := httptest.NewRecorder()
	relayTicket(ticketRecorder, ticketReq)
	if ticketRecorder.Code != http.StatusOK {
		t.Fatalf("device credential did not authenticate relay ticket fetch: HTTP %d %s", ticketRecorder.Code, ticketRecorder.Body.String())
	}

	newerReq := httptest.NewRequest(
		http.MethodPost,
		"/api/v1/devices",
		strings.NewReader(`{"public_key":"device-reregister-key","device_name":"newer","platform":"macos","network_id":"default","registration_incarnation":101}`),
	)
	newerReq.Header.Set("Authorization", "Bearer "+credential)
	newerRecorder := httptest.NewRecorder()
	register(newerRecorder, newerReq)
	if newerRecorder.Code != http.StatusOK {
		t.Fatalf("newer incarnation registration: HTTP %d %s", newerRecorder.Code, newerRecorder.Body.String())
	}

	staleReq := httptest.NewRequest(
		http.MethodPost,
		"/api/v1/devices",
		strings.NewReader(`{"public_key":"device-reregister-key","device_name":"late-old","platform":"macos","network_id":"default","registration_incarnation":100}`),
	)
	staleReq.Header.Set("Authorization", "Bearer "+credential)
	staleRecorder := httptest.NewRecorder()
	register(staleRecorder, staleReq)
	if staleRecorder.Code != http.StatusConflict {
		t.Fatalf("late older incarnation must be fenced: HTTP %d %s", staleRecorder.Code, staleRecorder.Body.String())
	}
	updated, err = db.GetDevice(device.ID)
	if err != nil {
		t.Fatalf("GetDevice after stale registration: %v", err)
	}
	if updated.DeviceName != "newer" || updated.RegistrationIncarnation != 101 || updated.RegistrationSeq != 3 {
		t.Fatalf("stale registration overwrote newer daemon state: %+v", updated)
	}
}

func TestRevokedDeviceCredentialCannotReregisterOrUpdateEndpoint(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("database.New: %v", err)
	}
	defer db.Close()

	user, err := db.CreateUser("revoked-reregister@example.com", "hash")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	device, err := db.CreateDevice(user.ID, "default", "revoked-reregister-key", "device", "macos", "")
	if err != nil {
		t.Fatalf("CreateDevice: %v", err)
	}
	cred, credential, err := db.CreateDeviceCredential(device.ID, 3600)
	if err != nil {
		t.Fatalf("CreateDeviceCredential: %v", err)
	}
	if err := db.RevokeDeviceCredential(cred.ID); err != nil {
		t.Fatalf("RevokeDeviceCredential: %v", err)
	}

	service := auth.NewService("revoked-reregister-test", db)
	server := NewServer(service, nil, db)
	register := auth.RequireAnyAuth(service, db)(server.RegisterDevice)
	registrationReq := httptest.NewRequest(
		http.MethodPost,
		"/api/v1/devices",
		strings.NewReader(`{"public_key":"revoked-reregister-key","device_name":"stale","platform":"macos","network_id":"default"}`),
	)
	registrationReq.Header.Set("Authorization", "Bearer "+credential)
	registrationRecorder := httptest.NewRecorder()
	register(registrationRecorder, registrationReq)
	if registrationRecorder.Code != http.StatusUnauthorized {
		t.Fatalf("revoked credential re-registration: HTTP %d %s", registrationRecorder.Code, registrationRecorder.Body.String())
	}

	endpoint := auth.RequireDeviceAuth(db)(server.UpdateDeviceEndpoint)
	endpointReq := httptest.NewRequest(
		http.MethodPatch,
		"/api/v1/devices/"+device.ID+"/endpoint",
		strings.NewReader(`{"endpoint":"198.51.100.89:51820","nat_type":"unknown"}`),
	)
	endpointReq.SetPathValue("id", device.ID)
	endpointReq.Header.Set("Authorization", "Bearer "+credential)
	endpointRecorder := httptest.NewRecorder()
	endpoint(endpointRecorder, endpointReq)
	if endpointRecorder.Code != http.StatusUnauthorized {
		t.Fatalf("revoked credential endpoint update: HTTP %d %s", endpointRecorder.Code, endpointRecorder.Body.String())
	}
}

func TestUpdateDeviceChangesVirtualIP(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("database.New: %v", err)
	}
	defer db.Close()
	user, err := db.CreateUser("update-ip@example.com", "hash")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	device, err := db.CreateDevice(user.ID, "default", "update-ip-key", "old-name", "macos", "")
	if err != nil {
		t.Fatalf("CreateDevice: %v", err)
	}

	server := NewServer(nil, nil, db)
	req := httptest.NewRequest(http.MethodPatch, "/api/v1/devices/"+device.ID, strings.NewReader(`{"device_name":"Studio Mac","virtual_ip":"10.20.0.66"}`))
	req.SetPathValue("id", device.ID)
	req = req.WithContext(context.WithValue(req.Context(), auth.UserClaimsKey, &auth.Claims{UserID: user.ID}))
	recorder := httptest.NewRecorder()

	server.UpdateDevice(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		DeviceName string `json:"device_name"`
		VirtualIP  string `json:"virtual_ip"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.DeviceName != "Studio Mac" || response.VirtualIP != "10.20.0.66" {
		t.Fatalf("unexpected update response: %+v", response)
	}
	updated, err := db.GetDevice(device.ID)
	if err != nil {
		t.Fatalf("GetDevice: %v", err)
	}
	if updated.DeviceName != "Studio Mac" || updated.VirtualIP != "10.20.0.66" {
		t.Fatalf("unexpected updated device: %+v", updated)
	}
}

func TestUpdateDeviceEndpointStoresRelayRTT(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("database.New: %v", err)
	}
	defer db.Close()
	user, err := db.CreateUser("relay-rtt@example.com", "hash")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	device, err := db.CreateDevice(user.ID, "default", "relay-rtt-key", "relay-device", "macos", "")
	if err != nil {
		t.Fatalf("CreateDevice: %v", err)
	}

	server := NewServer(nil, nil, db)
	req := httptest.NewRequest(
		http.MethodPatch,
		"/api/v1/devices/"+device.ID+"/endpoint",
		strings.NewReader(`{"endpoint":"198.51.100.10:52100","nat_type":"symmetric","relay_rtt_ms":42}`),
	)
	req.SetPathValue("id", device.ID)
	req = req.WithContext(context.WithValue(req.Context(), auth.UserClaimsKey, &auth.Claims{UserID: user.ID}))
	recorder := httptest.NewRecorder()

	server.UpdateDeviceEndpoint(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}
	updated, err := db.GetDevice(device.ID)
	if err != nil {
		t.Fatalf("GetDevice: %v", err)
	}
	if updated.RelayRTTMS == nil || *updated.RelayRTTMS != 42 {
		t.Fatalf("expected relay RTT 42, got %+v", updated.RelayRTTMS)
	}

	nodesReq := httptest.NewRequest(http.MethodGet, "/api/v1/nodes?network_id=default", nil)
	nodesReq = nodesReq.WithContext(context.WithValue(nodesReq.Context(), auth.UserClaimsKey, &auth.Claims{UserID: user.ID}))
	nodesRecorder := httptest.NewRecorder()
	server.ListNodes(nodesRecorder, nodesReq)
	if nodesRecorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", nodesRecorder.Code, nodesRecorder.Body.String())
	}
	var response struct {
		Nodes []database.Device `json:"nodes"`
	}
	if err := json.Unmarshal(nodesRecorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode nodes: %v", err)
	}
	if len(response.Nodes) != 1 || response.Nodes[0].RelayRTTMS == nil || *response.Nodes[0].RelayRTTMS != 42 {
		t.Fatalf("expected listed relay RTT 42, got %+v", response.Nodes)
	}
}

func TestListNodesIsolatedByAccountForUserAndDeviceAuth(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("database.New: %v", err)
	}
	defer db.Close()
	owner, _ := db.CreateUser("nodes-owner-isolation@example.com", "hash")
	other, _ := db.CreateUser("nodes-other-isolation@example.com", "hash")
	owned, _ := db.CreateDevice(owner.ID, "default", "nodes-owner-key", "owner-device", "macos", "")
	foreign, _ := db.CreateDevice(other.ID, "default", "nodes-other-key", "other-device", "linux", "")

	server := NewServer(nil, nil, db)
	userReq := httptest.NewRequest(http.MethodGet, "/api/v1/nodes?network_id=default", nil)
	userReq = userReq.WithContext(context.WithValue(userReq.Context(), auth.UserClaimsKey, &auth.Claims{UserID: owner.ID}))
	userRecorder := httptest.NewRecorder()
	server.ListNodes(userRecorder, userReq)
	if userRecorder.Code != http.StatusOK {
		t.Fatalf("user list expected 200, got %d: %s", userRecorder.Code, userRecorder.Body.String())
	}
	assertOnlyNode(t, userRecorder, owned.ID, foreign.ID)

	deviceReq := httptest.NewRequest(http.MethodGet, "/api/v1/nodes?network_id=default", nil)
	deviceReq = deviceReq.WithContext(context.WithValue(deviceReq.Context(), auth.DeviceClaimsKey, &auth.DeviceClaims{
		DeviceID: owned.ID, NetworkID: owned.NetworkID, UserID: owner.ID,
	}))
	deviceRecorder := httptest.NewRecorder()
	server.ListNodes(deviceRecorder, deviceReq)
	if deviceRecorder.Code != http.StatusOK {
		t.Fatalf("device list expected 200, got %d: %s", deviceRecorder.Code, deviceRecorder.Body.String())
	}
	assertOnlyNode(t, deviceRecorder, owned.ID, foreign.ID)
}

func assertOnlyNode(t *testing.T, recorder *httptest.ResponseRecorder, expectedID, forbiddenID string) {
	t.Helper()
	var response struct {
		Nodes []database.Device `json:"nodes"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode nodes: %v", err)
	}
	if len(response.Nodes) != 1 || response.Nodes[0].ID != expectedID {
		t.Fatalf("expected only %q, got %+v", expectedID, response.Nodes)
	}
	for _, node := range response.Nodes {
		if node.ID == forbiddenID {
			t.Fatalf("response leaked foreign device %q", forbiddenID)
		}
	}
}

func TestUserJWTEndpointUpdateCannotReviveCredentialedDevice(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("database.New: %v", err)
	}
	defer db.Close()
	user, err := db.CreateUser("endpoint-presence@example.com", "hash")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	device, err := db.CreateDevice(user.ID, "default", "endpoint-presence-key", "device", "macos", "")
	if err != nil {
		t.Fatalf("CreateDevice: %v", err)
	}
	if _, _, err := db.CreateDeviceCredential(device.ID, 3600); err != nil {
		t.Fatalf("CreateDeviceCredential: %v", err)
	}
	const staleLastSeen = int64(1234)
	if _, err := db.Exec(`UPDATE devices SET last_seen = ?, online = 0 WHERE id = ?`, staleLastSeen, device.ID); err != nil {
		t.Fatalf("mark offline: %v", err)
	}

	server := NewServer(nil, nil, db)
	req := httptest.NewRequest(http.MethodPatch, "/api/v1/devices/"+device.ID+"/endpoint",
		strings.NewReader(`{"endpoint":"198.51.100.20:52000","nat_type":"restricted"}`))
	req.SetPathValue("id", device.ID)
	req = req.WithContext(context.WithValue(req.Context(), auth.UserClaimsKey, &auth.Claims{UserID: user.ID}))
	recorder := httptest.NewRecorder()
	server.UpdateDeviceEndpoint(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}
	updated, err := db.GetDevice(device.ID)
	if err != nil {
		t.Fatalf("GetDevice: %v", err)
	}
	if updated.Online || updated.LastSeen != staleLastSeen {
		t.Fatalf("user JWT must not refresh device presence: %+v", updated)
	}
	if updated.Endpoint != "198.51.100.20:52000" {
		t.Fatalf("metadata update was lost: %+v", updated)
	}
}

func TestDeviceCredentialEndpointUpdateRefreshesPresence(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("database.New: %v", err)
	}
	defer db.Close()
	user, err := db.CreateUser("endpoint-heartbeat@example.com", "hash")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	device, err := db.CreateDevice(user.ID, "default", "endpoint-heartbeat-key", "device", "linux", "")
	if err != nil {
		t.Fatalf("CreateDevice: %v", err)
	}
	if _, err := db.Exec(`UPDATE devices SET last_seen = 0, online = 0 WHERE id = ?`, device.ID); err != nil {
		t.Fatalf("mark offline: %v", err)
	}

	server := NewServer(nil, nil, db)
	req := httptest.NewRequest(http.MethodPatch, "/api/v1/devices/"+device.ID+"/endpoint",
		strings.NewReader(`{"endpoint":"","nat_type":"unknown"}`))
	req.SetPathValue("id", device.ID)
	req = req.WithContext(context.WithValue(req.Context(), auth.DeviceClaimsKey, &auth.DeviceClaims{
		DeviceID:  device.ID,
		UserID:    user.ID,
		NetworkID: device.NetworkID,
		ExpiresAt: time.Now().Add(time.Hour).Unix(),
	}))
	recorder := httptest.NewRecorder()
	server.UpdateDeviceEndpoint(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}
	updated, err := db.GetDevice(device.ID)
	if err != nil {
		t.Fatalf("GetDevice: %v", err)
	}
	if !updated.Online || updated.LastSeen <= 0 {
		t.Fatalf("device credential heartbeat must refresh presence: %+v", updated)
	}
}

func TestReleaseDevicePresenceMarksOnlyMatchingDeviceOffline(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("database.New: %v", err)
	}
	defer db.Close()
	user, err := db.CreateUser("presence-release@example.com", "hash")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	device, err := db.CreateDevice(user.ID, "default", "presence-release-key", "device", "linux", "")
	if err != nil {
		t.Fatalf("CreateDevice: %v", err)
	}
	lastSeen := device.LastSeen

	server := NewServer(nil, nil, db)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/devices/"+device.ID+"/offline", nil)
	req.SetPathValue("id", device.ID)
	req = req.WithContext(context.WithValue(req.Context(), auth.DeviceClaimsKey, &auth.DeviceClaims{
		DeviceID:  device.ID,
		UserID:    user.ID,
		NetworkID: device.NetworkID,
		ExpiresAt: time.Now().Add(time.Hour).Unix(),
	}))
	recorder := httptest.NewRecorder()
	server.ReleaseDevicePresence(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}
	released, err := db.GetDevice(device.ID)
	if err != nil {
		t.Fatalf("GetDevice: %v", err)
	}
	if released.Online || released.LastSeen != lastSeen {
		t.Fatalf("release should only clear online: %+v", released)
	}

	wrongReq := httptest.NewRequest(http.MethodPost, "/api/v1/devices/other/offline", nil)
	wrongReq.SetPathValue("id", "other")
	wrongReq = wrongReq.WithContext(context.WithValue(wrongReq.Context(), auth.DeviceClaimsKey, &auth.DeviceClaims{
		DeviceID:  device.ID,
		UserID:    user.ID,
		NetworkID: device.NetworkID,
		ExpiresAt: time.Now().Add(time.Hour).Unix(),
	}))
	wrongRecorder := httptest.NewRecorder()
	server.ReleaseDevicePresence(wrongRecorder, wrongReq)
	if wrongRecorder.Code != http.StatusUnauthorized {
		t.Fatalf("mismatched device credential should be rejected, got %d", wrongRecorder.Code)
	}
}

// newEndpointUpdateTestServer sets up a server, user, and device owned by that
// user, ready to exercise UpdateDeviceEndpoint.
func newEndpointUpdateTestServer(t *testing.T) (*Server, string, string) {
	t.Helper()
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("database.New: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	user, err := db.CreateUser("endpoint-cap@example.com", "hash")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	device, err := db.CreateDevice(user.ID, "default", "endpoint-cap-key", "endpoint-cap-device", "macos", "")
	if err != nil {
		t.Fatalf("CreateDevice: %v", err)
	}
	return NewServer(nil, nil, db), device.ID, user.ID
}

// patchEndpoint sends an endpoint update with the given nat_type and returns
// the recorded response.
func patchEndpoint(t *testing.T, server *Server, deviceID string, userID string, natType string) *httptest.ResponseRecorder {
	t.Helper()
	body := fmt.Sprintf(`{"endpoint":"198.51.100.10:52100","nat_type":%q}`, natType)
	req := httptest.NewRequest(http.MethodPatch, "/api/v1/devices/"+deviceID+"/endpoint", strings.NewReader(body))
	req.SetPathValue("id", deviceID)
	req = req.WithContext(context.WithValue(req.Context(), auth.UserClaimsKey, &auth.Claims{UserID: userID}))
	recorder := httptest.NewRecorder()
	server.UpdateDeviceEndpoint(recorder, req)
	return recorder
}

// R1 widens the nat_type cap from 64 to 128: a full-width `p2v2:` fingerprint
// label (worst case ~97 bytes) must now be accepted.
func TestUpdateEndpointAcceptsNatTypeWithin128(t *testing.T) {
	server, deviceID, userID := newEndpointUpdateTestServer(t)
	// A label shaped like the R1 control label, padded to exactly 128 bytes.
	prefix := "p2v2:m=address_or_port_dependent;a=random;d=32;c=90;f=likely_endpoint_independent;h=not_applicable"
	natType := prefix + strings.Repeat("x", 128-len(prefix))
	if len(natType) != 128 {
		t.Fatalf("test bug: nat_type must be 128 bytes, got %d", len(natType))
	}
	recorder := patchEndpoint(t, server, deviceID, userID, natType)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200 for 128-byte nat_type, got %d: %s", recorder.Code, recorder.Body.String())
	}
}

// A nat_type over the new 128-byte cap must still be rejected with 400.
func TestUpdateEndpointRejectsNatTypeOver128(t *testing.T) {
	server, deviceID, userID := newEndpointUpdateTestServer(t)
	natType := strings.Repeat("y", 129)
	if len(natType) != 129 {
		t.Fatalf("test bug: nat_type must be 129 bytes, got %d", len(natType))
	}
	recorder := patchEndpoint(t, server, deviceID, userID, natType)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for 129-byte nat_type, got %d: %s", recorder.Code, recorder.Body.String())
	}
}
