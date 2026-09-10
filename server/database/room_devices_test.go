package database

import (
	"errors"
	"testing"
)

func TestRoomDeviceControlsIsolateSameAccountDevices(t *testing.T) {
	db := roomTestDB(t)
	owner := roomTestUser(t, db, "owner-controls")
	user := roomTestUser(t, db, "member-controls")
	room := roomTestRoom(t, db, owner)
	if _, err := db.JoinRoom(user, room.Code, "safe-password", ""); err != nil {
		t.Fatal(err)
	}
	a := roomTestDevice(t, db, user, room.ID, "same-account-a")
	b := roomTestDevice(t, db, user, room.ID, "same-account-b")
	if a.ID == b.ID || a.VirtualIP == b.VirtualIP {
		t.Fatal("device identities or addresses collapsed")
	}
	_, ta, err := db.CreateDeviceCredential(a.ID, 3600)
	if err != nil {
		t.Fatal(err)
	}
	_, tb, err := db.CreateDeviceCredential(b.ID, 3600)
	if err != nil {
		t.Fatal(err)
	}
	access, err := db.RequestRoomDevice(user, room.ID, a.PublicKey, a.DeviceName, a.Platform, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.ChangeRoomDeviceAccess(user, room.ID, access.ID, "disconnect"); err != nil {
		t.Fatal(err)
	}
	if _, _, err = db.ValidateDeviceCredential(ta); err == nil {
		t.Fatal("disconnected credential remains valid")
	}
	if _, _, err = db.ValidateDeviceCredential(tb); err != nil {
		t.Fatalf("sibling interrupted: %v", err)
	}
	if ok, _ := db.UserHasNetworkAccess(user, room.ID); !ok {
		t.Fatal("disconnect removed membership")
	}
	if _, err = db.CreateDevice(user, room.ID, a.PublicKey, a.DeviceName, a.Platform, ""); !errors.Is(err, ErrRoomDevicePaused) {
		t.Fatalf("daemon reconnect was allowed: %v", err)
	}
	if _, err = db.RequestRoomDevice(user, room.ID, a.PublicKey, a.DeviceName, a.Platform, false); !errors.Is(err, ErrRoomDevicePaused) {
		t.Fatalf("auto resume was allowed: %v", err)
	}
	if ok, _ := db.DevicesMayCommunicate(a.ID, b.ID); ok {
		t.Fatal("paused device can communicate")
	}
	visible, err := db.ListVisibleDevices(user, room.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(visible) != 1 || visible[0].ID != b.ID {
		t.Fatalf("paused device remains in peer authorization: %+v", visible)
	}
	if _, err = db.RequestRoomDevice(user, room.ID, a.PublicKey, a.DeviceName, a.Platform, true); err != nil {
		t.Fatal(err)
	}
	restored, err := db.CreateDevice(user, room.ID, a.PublicKey, a.DeviceName, a.Platform, "")
	if err != nil {
		t.Fatal(err)
	}
	if restored.ID != a.ID || restored.VirtualIP != a.VirtualIP {
		t.Fatal("manual reconnect changed stable device identity/IP")
	}
	if _, _, err = db.ValidateDeviceCredential(ta); err == nil {
		t.Fatal("manual reconnect resurrected a revoked credential")
	}
	if _, err = db.ChangeRoomDeviceAccess(owner, room.ID, access.ID, "block"); err != nil {
		t.Fatal(err)
	}
	if _, err = db.RequestRoomDevice(user, room.ID, a.PublicKey, a.DeviceName, a.Platform, true); !errors.Is(err, ErrRoomDeviceBlocked) {
		t.Fatal(err)
	}
	if _, err = db.ChangeRoomDeviceAccess(user, room.ID, access.ID, "unblock"); !errors.Is(err, ErrRoomAccess) {
		t.Fatalf("member lifted owner restriction: %v", err)
	}
	if _, err = db.ChangeRoomDeviceAccess(owner, room.ID, access.ID, "unblock"); err != nil {
		t.Fatal(err)
	}
	if _, err = db.RequestRoomDevice(user, room.ID, a.PublicKey, a.DeviceName, a.Platform, false); !errors.Is(err, ErrRoomDevicePaused) {
		t.Fatal("unblock should require local connect", err)
	}
}

func TestRoomNewDeviceApprovalCannotBeBypassed(t *testing.T) {
	db := roomTestDB(t)
	owner := roomTestUser(t, db, "approval-owner")
	user := roomTestUser(t, db, "approval-member")
	other := roomTestUser(t, db, "approval-other")
	room := roomTestRoom(t, db, owner)
	for _, u := range []string{user, other} {
		if _, err := db.JoinRoom(u, room.Code, "safe-password", ""); err != nil {
			t.Fatal(err)
		}
	}
	old := roomTestDevice(t, db, user, room.ID, "already-approved")
	if err := db.SetRoomDeviceApproval(user, room.ID, true); !errors.Is(err, ErrRoomAccess) {
		t.Fatal("member changed policy", err)
	}
	if err := db.SetRoomDeviceApproval(owner, room.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := db.CreateDevice(user, room.ID, old.PublicKey, old.DeviceName, old.Platform, ""); err != nil {
		t.Fatal("policy disrupted existing device", err)
	}
	if _, err := db.CreateDevice(user, room.ID, "new-install", "new", "macos", ""); !errors.Is(err, ErrRoomDevicePending) {
		t.Fatal("registration bypassed approval", err)
	}
	details, err := db.GetRoom(owner, room.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !details.DeviceApprovalRequired {
		t.Fatal("policy not returned")
	}
	var request RoomDeviceAccess
	for _, a := range details.DeviceAccess {
		if a.PublicKey == "new-install" {
			request = a
		}
	}
	if request.State != "pending" || request.DeviceID != "" {
		t.Fatalf("request not retained without live device: %+v", request)
	}
	for _, action := range []string{"approve", "block"} {
		if _, err := db.ChangeRoomDeviceAccess(user, room.ID, request.ID, action); !errors.Is(err, ErrRoomAccess) {
			t.Fatalf("member bypass via %s: %v", action, err)
		}
	}
	if _, err := db.ChangeRoomDeviceAccess(other, room.ID, request.ID, "disconnect"); !errors.Is(err, ErrRoomAccess) {
		t.Fatal("other member controlled device", err)
	}
	if _, err := db.ChangeRoomDeviceAccess(owner, room.ID, request.ID, "approve"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RequestRoomDevice(user, room.ID, "new-install", "new", "macos", false); !errors.Is(err, ErrRoomDevicePaused) {
		t.Fatal("approval auto-connected device", err)
	}
	if _, err := db.RequestRoomDevice(user, room.ID, "new-install", "new", "macos", true); err != nil {
		t.Fatal(err)
	}
	roomTestDevice(t, db, user, room.ID, "new-install")
	if _, err := db.RequestRoomDevice(user, room.ID, "reinstalled-key", "new", "macos", true); !errors.Is(err, ErrRoomDevicePending) {
		t.Fatal("new key inherited approval", err)
	}
	if err := migrateRooms(db.DB); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RequestRoomDevice(user, room.ID, "reinstalled-key", "new", "macos", true); !errors.Is(err, ErrRoomDevicePending) {
		t.Fatal("migration reset access", err)
	}
}

func TestRoomOwnerAndExitAreAccountScoped(t *testing.T) {
	db := roomTestDB(t)
	owner := roomTestUser(t, db, "account-owner")
	member := roomTestUser(t, db, "account-member")
	room := roomTestRoom(t, db, owner)
	creator := roomTestDevice(t, db, owner, room.ID, "creator")
	otherOwner := roomTestDevice(t, db, owner, room.ID, "owner-second")
	if err := db.DeleteRoomDevice(owner, room.ID, creator.ID); err != nil {
		t.Fatal(err)
	}
	details, err := db.GetRoom(owner, room.ID)
	if err != nil || details.Room.Role != "owner" {
		t.Fatal("lost room ownership with creation device", err)
	}
	if _, err := db.JoinRoom(member, room.Code, "safe-password", ""); err != nil {
		t.Fatal(err)
	}
	a := roomTestDevice(t, db, member, room.ID, "exit-a")
	b := roomTestDevice(t, db, member, room.ID, "exit-b")
	ids, err := db.RemoveRoomMember(member, room.ID, member, false)
	if err != nil || len(ids) != 2 {
		t.Fatal("exit did not affect both devices", ids, err)
	}
	for _, id := range []string{a.ID, b.ID} {
		if _, err := db.GetDevice(id); err == nil {
			t.Fatal("exit kept device")
		}
	}
	if _, err := db.GetDevice(otherOwner.ID); err != nil {
		t.Fatal("exit removed another account device", err)
	}
}
