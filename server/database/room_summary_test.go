package database

import (
	"testing"
	"time"
)

func TestRoomCardsCountAccountsAndExposeUsernames(t *testing.T) {
	db := roomTestDB(t)
	owner := roomTestUser(t, db, "owner-summary")
	member := roomTestUser(t, db, "member-summary")
	room := roomTestRoom(t, db, owner)
	if _, err := db.UpdateUsername(owner, "房主小林"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.CreateNetworkMembership(member, room.ID, "member"); err != nil {
		t.Fatal(err)
	}
	one := roomTestDevice(t, db, owner, room.ID, "summary-one")
	two := roomTestDevice(t, db, owner, room.ID, "summary-two")
	stale := roomTestDevice(t, db, member, room.ID, "summary-stale")
	now := time.Now().Unix()
	if _, err := db.Exec(`UPDATE devices SET online=1, last_seen=? WHERE id IN (?,?)`, now, one.ID, two.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE devices SET online=1, last_seen=? WHERE id=?`, now-DeviceOnlineTTL-1, stale.ID); err != nil {
		t.Fatal(err)
	}
	rooms, err := db.ListRooms(member)
	if err != nil {
		t.Fatal(err)
	}
	if len(rooms) != 1 || rooms[0].MemberCount != 2 || rooms[0].OnlineMemberCount != 1 || rooms[0].OwnerUsername != "房主小林" || len(rooms[0].OwnerDeviceIPs) != 2 {
		t.Fatalf("wrong summary: %+v", rooms)
	}
	details, err := db.GetRoom(member, room.ID)
	if err != nil {
		t.Fatal(err)
	}
	if details.Members[0].Username != "房主小林" {
		t.Fatal("username absent from roster")
	}
}
