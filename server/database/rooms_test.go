package database

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"net/netip"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func roomTestDB(t *testing.T) *DB {
	t.Helper()
	db, err := New(filepath.Join(t.TempDir(), "rooms.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func roomTestUser(t *testing.T, db *DB, name string) string {
	t.Helper()
	u, err := db.CreateUser(name+"@rooms.test", "unused")
	if err != nil {
		t.Fatal(err)
	}
	return u.ID
}

func roomTestRoom(t *testing.T, db *DB, owner string) *Room {
	t.Helper()
	r, err := db.CreateRoom(owner, "朋友的房间", "safe-password")
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func roomTestDevice(t *testing.T, db *DB, user, network, key string) *Device {
	t.Helper()
	d, err := db.CreateDevice(user, network, key, key, "linux", "")
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func TestRoomsConcurrentAllocationAcrossConnections(t *testing.T) {
	path := filepath.Join(t.TempDir(), "shared.db")
	const n = 8
	dbs := make([]*DB, n)
	users := make([]string, n)
	for i := range dbs {
		var err error
		dbs[i], err = New(path)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { dbs[i].Close() })
		users[i] = roomTestUser(t, dbs[i], fmt.Sprint(i))
	}
	var wg sync.WaitGroup
	rooms := make(chan *Room, n)
	errs := make(chan error, n)
	for i := range dbs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			r, err := dbs[i].CreateRoom(users[i], "room", "safe-password")
			if err != nil {
				errs <- err
			} else {
				rooms <- r
			}
		}(i)
	}
	wg.Wait()
	close(rooms)
	close(errs)
	for err := range errs {
		t.Error(err)
	}
	prefixes := []netip.Prefix{}
	codes := map[string]bool{}
	for r := range rooms {
		p, err := netip.ParsePrefix(r.CIDR)
		if err != nil || p.Bits() != 24 || !p.Addr().IsPrivate() {
			t.Fatalf("invalid subnet: %+v", r)
		}
		for _, other := range prefixes {
			if p.Overlaps(other) {
				t.Fatal("overlapping room subnets")
			}
		}
		if codes[r.Code] || len(r.Code) != 8 {
			t.Fatal("invalid room number")
		}
		codes[r.Code] = true
		prefixes = append(prefixes, p)
	}
	if len(prefixes) != n {
		t.Fatalf("created %d/%d rooms", len(prefixes), n)
	}
}

func TestRoomsSameOwnerConcurrentCreate(t *testing.T) {
	db := roomTestDB(t)
	u := roomTestUser(t, db, "owner")
	results := make(chan error, 8)
	for i := 0; i < 8; i++ {
		go func() { _, err := db.CreateRoom(u, "room", "safe-password"); results <- err }()
	}
	created := 0
	for i := 0; i < 8; i++ {
		err := <-results
		if err == nil {
			created++
		} else if !errors.Is(err, ErrRoomExists) {
			t.Fatal(err)
		}
	}
	if created != 1 {
		t.Fatalf("created %d rooms for one account", created)
	}
}

func TestRoomsPoolOverlapExhaustionAndQuarantine(t *testing.T) {
	t.Run("overlap", func(t *testing.T) {
		db := roomTestDB(t)
		u := roomTestUser(t, db, "owner")
		if _, err := db.CreateNetwork(u, "existing", "10.21.0.0/23"); err != nil {
			t.Fatal(err)
		}
		r := roomTestRoom(t, db, u)
		if r.CIDR != "10.21.2.0/24" {
			t.Fatal(r.CIDR)
		}
		if _, err := db.CreateNetwork(u, "conflict", "10.0.0.0/8"); !errors.Is(err, ErrRoomConflict) {
			t.Fatalf("room overlap allowed: %v", err)
		}
	})
	t.Run("exhausted", func(t *testing.T) {
		db := roomTestDB(t)
		u := roomTestUser(t, db, "owner")
		if _, err := db.CreateNetwork(u, "existing", "10.21.0.0/16"); err != nil {
			t.Fatal(err)
		}
		if _, err := db.CreateRoom(u, "room", "safe-password"); !errors.Is(err, ErrRoomExhausted) {
			t.Fatalf("want exhausted, got %v", err)
		}
	})
	t.Run("quarantine", func(t *testing.T) {
		db := roomTestDB(t)
		u := roomTestUser(t, db, "owner")
		r := roomTestRoom(t, db, u)
		if _, err := db.DeleteRoom(u, r.ID); err != nil {
			t.Fatal(err)
		}
		r2 := roomTestRoom(t, db, u)
		if r2.ID == r.ID || r2.CIDR == r.CIDR {
			t.Fatal("old identity or subnet reused before revocation expiry")
		}
	})
}

func TestRoomsPasswordInviteAndOwnerBoundaries(t *testing.T) {
	db := roomTestDB(t)
	a, b, c := roomTestUser(t, db, "a"), roomTestUser(t, db, "b"), roomTestUser(t, db, "c")
	r := roomTestRoom(t, db, a)
	for _, code := range []string{r.Code, "00000000"} {
		if _, err := db.JoinRoom(b, code, "wrong-password", ""); !errors.Is(err, ErrRoomJoin) {
			t.Fatalf("join error leaks: %v", err)
		}
	}
	if _, err := db.GetRoom(b, r.ID); !errors.Is(err, ErrRoomAccess) {
		t.Fatal(err)
	}
	if _, err := db.JoinRoom(b, r.Code, "safe-password", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := db.CreateRoomInvite(b, r.ID, 300, 1); !errors.Is(err, ErrRoomAccess) {
		t.Fatal(err)
	}
	if _, err := db.RemoveRoomMember(b, r.ID, a, false); !errors.Is(err, ErrRoomAccess) {
		t.Fatal(err)
	}
	if _, err := db.DeleteRoom(b, r.ID); !errors.Is(err, ErrRoomAccess) {
		t.Fatal(err)
	}
	name := "stolen"
	if err := db.UpdateRoom(b, r.ID, &name, nil, nil); !errors.Is(err, ErrRoomAccess) {
		t.Fatal(err)
	}
	invite, token, err := db.CreateRoomInvite(a, r.ID, 300, 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.JoinRoom(c, r.Code, "", token); err != nil {
		t.Fatal(err)
	}
	if _, err := db.JoinRoom(c, r.Code, "", token); err != nil {
		t.Fatalf("idempotent join: %v", err)
	}
	var uses int
	var digest []byte
	if err := db.QueryRow(`SELECT uses, token_hash FROM room_invites WHERE id = ?`, invite.ID).Scan(&uses, &digest); err != nil {
		t.Fatal(err)
	}
	expected := sha256.Sum256([]byte(token))
	if uses != 1 || string(digest) != string(expected[:]) || string(digest) == token {
		t.Fatal("invite accounting/hash")
	}
	password := "replacement-password"
	if err := db.UpdateRoom(a, r.ID, nil, &password, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := db.JoinRoom(c, r.Code, "", token); !errors.Is(err, ErrRoomJoin) {
		t.Fatal("rotated invite still accepted")
	}
	if _, err := db.JoinRoom(b, r.Code, "safe-password", ""); !errors.Is(err, ErrRoomJoin) {
		t.Fatal("old password accepted")
	}
	if _, err := db.JoinRoom(b, r.Code, password, ""); err != nil {
		t.Fatal(err)
	}
}

func TestRoomsInviteConcurrentRedemptionAndExpiry(t *testing.T) {
	db := roomTestDB(t)
	owner := roomTestUser(t, db, "owner")
	r := roomTestRoom(t, db, owner)
	users := []string{}
	for i := 0; i < 6; i++ {
		users = append(users, roomTestUser(t, db, fmt.Sprint(i)))
	}
	invite, token, err := db.CreateRoomInvite(owner, r.ID, 300, 1)
	if err != nil {
		t.Fatal(err)
	}
	results := make(chan error, len(users))
	for _, u := range users {
		go func(u string) { _, err := db.JoinRoom(u, r.Code, "", token); results <- err }(u)
	}
	n := 0
	for range users {
		err := <-results
		if err == nil {
			n++
		} else if !errors.Is(err, ErrRoomJoin) {
			t.Fatal(err)
		}
	}
	if n != 1 {
		t.Fatalf("one-use invite redeemed %d times", n)
	}
	if _, err := db.Exec(`UPDATE room_invites SET expires_at = ? WHERE id = ?`, time.Now().Unix()-1, invite.ID); err != nil {
		t.Fatal(err)
	}
	for _, u := range users {
		if _, err := db.JoinRoom(u, r.Code, "", token); !errors.Is(err, ErrRoomJoin) {
			t.Fatal("expired invitation accepted")
		}
	}
}

func TestRoomsJoinRateLimitAndLock(t *testing.T) {
	db := roomTestDB(t)
	a, b := roomTestUser(t, db, "a"), roomTestUser(t, db, "b")
	r := roomTestRoom(t, db, a)
	locked := true
	if err := db.UpdateRoom(a, r.ID, nil, nil, &locked); err != nil {
		t.Fatal(err)
	}
	if _, err := db.JoinRoom(b, r.Code, "safe-password", ""); !errors.Is(err, ErrRoomJoin) {
		t.Fatal(err)
	}
	for i := 1; i < 10; i++ {
		db.JoinRoom(b, "", "", "")
	}
	if _, err := db.JoinRoom(b, r.Code, "safe-password", ""); !errors.Is(err, ErrRoomRateLimit) {
		t.Fatal(err)
	}
}

func TestRoomsMembershipDiscoveryIPAndRevocation(t *testing.T) {
	db := roomTestDB(t)
	a, b, c := roomTestUser(t, db, "a"), roomTestUser(t, db, "b"), roomTestUser(t, db, "c")
	r, other := roomTestRoom(t, db, a), roomTestRoom(t, db, c)
	if _, err := db.JoinRoom(b, r.Code, "safe-password", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := db.JoinRoom(b, other.Code, "safe-password", ""); err != nil {
		t.Fatal(err)
	}
	owned := roomTestRoom(t, db, b)
	list, err := db.ListRooms(b)
	if err != nil || len(list) != 3 || list[0].ID != owned.ID {
		t.Fatalf("multiroom: %+v %v", list, err)
	}
	personalA := roomTestDevice(t, db, a, "default", "pa")
	personalB := roomTestDevice(t, db, b, "default", "pb")
	da := roomTestDevice(t, db, a, r.ID, "ra")
	db1 := roomTestDevice(t, db, b, r.ID, "rb1")
	db2 := roomTestDevice(t, db, b, r.ID, "rb2")
	dOther := roomTestDevice(t, db, b, other.ID, "bo")
	if db1.VirtualIP == db2.VirtualIP {
		t.Fatal("multiple devices share one IP")
	}
	if _, err := db.CreateDevice(c, r.ID, "outsider", "bad", "linux", ""); !errors.Is(err, ErrRoomAccess) {
		t.Fatal(err)
	}
	if _, err := db.CreateDeviceWithOptions(b, r.ID, "rb3", "bad", "linux", "", "10.21.1.9", ""); !errors.Is(err, ErrRoomInvalid) {
		t.Fatal(err)
	}
	for _, check := range []struct {
		from, to string
		allowed  bool
	}{
		{da.ID, db1.ID, true}, {db1.ID, db2.ID, true}, {db1.ID, dOther.ID, false}, {personalA.ID, personalB.ID, false}, {db1.ID, personalB.ID, false},
	} {
		allowed, err := db.DevicesMayCommunicate(check.from, check.to)
		if err != nil || allowed != check.allowed {
			t.Fatalf("communication %s -> %s: %v %v", check.from, check.to, allowed, err)
		}
	}
	visible, err := db.ListVisibleDevices(b, r.ID)
	if err != nil || len(visible) != 3 {
		t.Fatalf("room visibility: %v %v", visible, err)
	}
	visible, err = db.ListVisibleDevices(b, "default")
	if err != nil || len(visible) != 1 || visible[0].ID != personalB.ID {
		t.Fatal("personal network leaked")
	}
	visible, err = db.ListVisibleDevices(c, r.ID)
	if err != nil || len(visible) != 0 {
		t.Fatal("outsider discovery allowed")
	}
	cred, token, err := db.CreateDeviceCredential(db1.ID, 3600)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AssignRoomDeviceIP(b, r.ID, db1.ID, "10.21.1.40"); !errors.Is(err, ErrRoomAccess) {
		t.Fatal(err)
	}
	for _, ip := range []string{da.VirtualIP, "10.21.1.0", "10.21.1.255", "10.20.0.9", "::1", "junk"} {
		if err := db.AssignRoomDeviceIP(a, r.ID, db1.ID, ip); err == nil {
			t.Fatalf("invalid IP accepted: %s", ip)
		}
	}
	if err := db.AssignRoomDeviceIP(a, r.ID, db1.ID, "10.21.1.40"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := db.ValidateDeviceCredential(token); err == nil {
		t.Fatal("IP change left old credential active")
	}
	var revoked bool
	if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM relay_revocations WHERE value = ?)`, cred.ID).Scan(&revoked); err != nil || !revoked {
		t.Fatal("relay credential not revoked")
	}
	_, token, err = db.CreateDeviceCredential(db1.ID, 3600)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := db.ValidateDeviceCredential(token); err != nil {
		t.Fatalf("new credential after IP change: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO signals (id, from_node_id, to_node_id, type, created_at) VALUES ('queued-room', ?, ?, 'offer', ?)`, da.ID, db1.ID, time.Now().Unix()); err != nil {
		t.Fatal(err)
	}
	ids, err := db.RemoveRoomMember(a, r.ID, b, true)
	if err != nil || len(ids) != 2 {
		t.Fatalf("remove: %v %v", ids, err)
	}
	if _, _, err := db.ValidateDeviceCredential(token); err == nil {
		t.Fatal("removed member credential still active")
	}
	if ok, err := db.DevicesMayCommunicate(da.ID, db1.ID); err != nil || ok {
		t.Fatal("removed member can signal")
	}
	var pending int
	if err := db.QueryRow(`SELECT COUNT(*) FROM signals WHERE id = 'queued-room'`).Scan(&pending); err != nil || pending != 0 {
		t.Fatal("queued signals not purged")
	}
	if _, err := db.GetDevice(personalB.ID); err != nil {
		t.Fatal("personal device deleted")
	}
	if _, err := db.GetDevice(dOther.ID); err != nil {
		t.Fatal("other room device deleted")
	}
	if _, err := db.JoinRoom(b, r.Code, "safe-password", ""); !errors.Is(err, ErrRoomJoin) {
		t.Fatal("ban bypassed")
	}
	if err := db.UnbanRoomMember(a, r.ID, b); err != nil {
		t.Fatal(err)
	}
	if _, err := db.JoinRoom(b, r.Code, "safe-password", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RemoveRoomMember(b, r.ID, b, false); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RemoveRoomMember(a, r.ID, a, false); !errors.Is(err, ErrRoomConflict) {
		t.Fatal("owner left own room")
	}
}

func TestRoomsRestartAndMigrationIdempotence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "restart.db")
	db, err := New(path)
	if err != nil {
		t.Fatal(err)
	}
	u := roomTestUser(t, db, "owner")
	r := roomTestRoom(t, db, u)
	if err := migrate(db.DB); err != nil {
		t.Fatal(err)
	}
	if err := migrateRooms(db.DB); err != nil {
		t.Fatal(err)
	}
	db.Close()
	db, err = New(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	details, err := db.GetRoom(u, r.ID)
	if err != nil || details.Room.Code != r.Code || details.Room.CIDR != r.CIDR {
		t.Fatalf("persistence: %v %v", details, err)
	}
	var stored string
	if err := db.QueryRow(`SELECT password_hash FROM rooms WHERE network_id = ?`, r.ID).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored == "safe-password" || !strings.HasPrefix(stored, "$2") {
		t.Fatal("password was not hashed")
	}
}
