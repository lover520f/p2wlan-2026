package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"net"
	"testing"
	"time"
)

func auditConnect(t *testing.T, addr, id, ticket string) net.Conn {
	t.Helper()
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	c.SetDeadline(time.Now().Add(2 * time.Second))
	payload := append([]byte{byte(len(id))}, []byte(id)...)
	payload = append(payload, byte(len(ticket)>>8), byte(len(ticket)))
	payload = append(payload, []byte(ticket)...)
	if err := writeFull(c, makeFrame(msgAuthRegister, payload)); err != nil {
		t.Fatal(err)
	}
	typ, _ := readTestFrame(t, c)
	if typ != msgRegistered {
		t.Fatalf("registration failed: type=%d", typ)
	}
	return c
}

func TestAuditRevocationMustStopEstablishedForwarding(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	cfg := testConfig()
	cfg.Bind = "127.0.0.1:0"
	cfg.RequireAuthentication = true
	cfg.RelayAudience = "relay-test"
	cfg.RelayRegion = "test-region"
	cfg.TicketKeyringJSON = `{"audit":"` + hex.EncodeToString(pub) + `"}`
	s, addr, cleanup := startTestServerWithInstance(t, cfg)
	defer cleanup()
	ticketA := signRelayTicketForTest(t, priv, "audit", "jti-a", "node-a", "cred-a")
	ticketB := signRelayTicketForTest(t, priv, "audit", "jti-b", "node-b", "cred-b")
	a := auditConnect(t, addr, "node-a", ticketA)
	b := auditConnect(t, addr, "node-b", ticketB)
	if err := s.applyRevocationSnapshot(relayRevocationFeedSnapshot{Version: 1, RevokedCredentialIDs: []string{"cred-a"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.verifyTicket(ticketA); err == nil {
		t.Fatal("control check: new registration should be rejected")
	}
	payload := append([]byte{6}, []byte("node-b")...)
	payload = append(payload, []byte("after-revocation")...)
	if err := writeFull(a, makeFrame(msgForward, payload)); err != nil {
		return
	}
	typ, data, err := readFrame(b, cfg.MaxFramePayload)
	if err == nil && typ == msgReceived {
		t.Fatalf("revoked credential still forwards on its established connection: %q", data)
	}
}

func TestRevocationFencesConcurrentAuthenticatedRegistration(t *testing.T) {
	for _, kind := range []string{"device", "credential", "jti"} {
		t.Run(kind, func(t *testing.T) {
			for i := 0; i < 50; i++ {
				s := &RelayServer{hub: newHub()}
				local, remote := net.Pipe()
				claims := &relayTicketClaims{DeviceID: "device", CredentialID: "credential", NetworkID: "room", NodeID: "node"}
				claims.ID = "jti"
				p := &peer{conn: local}
				snapshot := relayRevocationFeedSnapshot{Version: 1}
				switch kind {
				case "device":
					snapshot.RevokedDeviceIDs = []string{"device"}
				case "credential":
					snapshot.RevokedCredentialIDs = []string{"credential"}
				case "jti":
					snapshot.RevokedJTIs = []string{"jti"}
				}
				done := make(chan bool, 1)
				go func() { done <- s.registerAuthenticated(p, claims) }()
				if err := s.applyRevocationSnapshot(snapshot); err != nil {
					t.Fatal(err)
				}
				<-done
				if s.hub.lookup("room", "node") != nil {
					t.Fatal("revoked registration survived publication race")
				}
				// Also covers signature verification before the snapshot, followed
				// by publication after the snapshot's active-connection scan.
				if s.registerAuthenticated(p, claims) {
					t.Fatal("late publication admitted revoked identity")
				}
				local.Close()
				remote.Close()
			}
		})
	}
}
