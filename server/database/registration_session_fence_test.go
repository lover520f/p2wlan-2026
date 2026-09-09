package database

import (
	"errors"
	"path/filepath"
	"strconv"
	"testing"
)

func TestRegistrationSessionConditionalEndpointAndOfflineRejectStaleSequence(t *testing.T) {
	db, err := New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	user, err := db.CreateUser("registration-session-conditional@example.com", "hash")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	device, err := db.CreateDevice(user.ID, "default", "registration-session-conditional-key", "daemon", "macos", "")
	if err != nil {
		t.Fatalf("CreateDevice: %v", err)
	}

	firstIncarnation := int64(301)
	first, err := db.RegisterDeviceWithOptions(
		user.ID, device.NetworkID, device.PublicKey, "first", "macos", "", "", "",
		DeviceRegistrationAttempt{Incarnation: &firstIncarnation, EnforceIncarnation: true},
	)
	if err != nil {
		t.Fatalf("register first incarnation: %v", err)
	}
	secondIncarnation := int64(302)
	second, err := db.RegisterDeviceWithOptions(
		user.ID, device.NetworkID, device.PublicKey, "second", "macos", "", "", "",
		DeviceRegistrationAttempt{Incarnation: &secondIncarnation, EnforceIncarnation: true},
	)
	if err != nil {
		t.Fatalf("register second incarnation: %v", err)
	}
	if second.RegistrationSeq <= first.RegistrationSeq {
		t.Fatalf("registration sequence did not advance: first=%d second=%d", first.RegistrationSeq, second.RegistrationSeq)
	}

	currentRTT := int64(31)
	currentEndpoint := "198.51.100.31:51820"
	currentNAT := "p2v2:m=endpoint_independent;g=1;l=" + strconv.FormatInt(second.RegistrationSeq, 10)
	if err := db.UpdateDeviceEndpointForRegistrationSession(second.ID, second.RegistrationSeq, currentEndpoint, currentNAT, &currentRTT); err != nil {
		t.Fatalf("publish current endpoint: %v", err)
	}
	before, err := db.GetDevice(second.ID)
	if err != nil {
		t.Fatalf("GetDevice before stale actions: %v", err)
	}

	staleRTT := int64(99)
	err = db.UpdateDeviceEndpointForRegistrationSession(
		second.ID,
		first.RegistrationSeq,
		"198.51.100.99:51820",
		"p2v2:m=address_or_port_dependent;g=9;l="+strconv.FormatInt(first.RegistrationSeq, 10),
		&staleRTT,
	)
	assertRegistrationSessionConflict(t, err, second.RegistrationSeq)

	err = db.ReleaseDevicePresenceForRegistrationSession(second.ID, first.RegistrationSeq)
	assertRegistrationSessionConflict(t, err, second.RegistrationSeq)

	after, err := db.GetDevice(second.ID)
	if err != nil {
		t.Fatalf("GetDevice after stale actions: %v", err)
	}
	if after.Endpoint != before.Endpoint || after.NATType != before.NATType || after.LastSeen != before.LastSeen || after.Online != before.Online {
		t.Fatalf("stale session changed endpoint or lease: before=%+v after=%+v", before, after)
	}
	if after.RelayRTTMS == nil || before.RelayRTTMS == nil || *after.RelayRTTMS != *before.RelayRTTMS {
		t.Fatalf("stale session changed relay RTT: before=%+v after=%+v", before.RelayRTTMS, after.RelayRTTMS)
	}

	if err := db.ReleaseDevicePresenceForRegistrationSession(second.ID, second.RegistrationSeq); err != nil {
		t.Fatalf("current session release: %v", err)
	}
	current, err := db.GetDevice(second.ID)
	if err != nil {
		t.Fatalf("GetDevice after current release: %v", err)
	}
	if current.Online {
		t.Fatal("current session did not release presence")
	}
}

func assertRegistrationSessionConflict(t *testing.T, err error, wantSequence int64) {
	t.Helper()
	var conflict *RegistrationSessionConflictError
	if !errors.As(err, &conflict) {
		t.Fatalf("expected registration session conflict, got %v", err)
	}
	if conflict.CurrentSequence != wantSequence {
		t.Fatalf("conflict sequence = %d, want %d", conflict.CurrentSequence, wantSequence)
	}
}
