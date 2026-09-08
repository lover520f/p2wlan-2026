package api

import (
	"bytes"
	"encoding/json"
	"github.com/yhan-sun/p2wlan/server/auth"
	"github.com/yhan-sun/p2wlan/server/database"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestProfileUsernameAuthenticatedAndValidated(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "profile.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	service := auth.NewService("profile-test-secret", db)
	token, user, err := service.Register("one@example.test", "password123")
	if err != nil {
		t.Fatal(err)
	}
	_, other, err := service.Register("two@example.test", "password123")
	if err != nil {
		t.Fatal(err)
	}
	s := NewServer(service, nil, db)
	handler := service.RequireAuth(s.Profile)
	request := func(method, token string, body any) *httptest.ResponseRecorder {
		b, _ := json.Marshal(body)
		r := httptest.NewRequest(method, "/api/v1/profile", bytes.NewReader(b))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		handler(w, r)
		return w
	}
	if w := request("PATCH", "", map[string]any{"username": "小林"}); w.Code != 401 {
		t.Fatal(w.Code)
	}
	for _, name := range []string{"", "\n", strings.Repeat("名", 33), "名字\n欺骗", "名字\u202e"} {
		if w := request("PATCH", token, map[string]any{"username": name}); w.Code != 400 {
			t.Fatalf("invalid name accepted: %q %d", name, w.Code)
		}
	}
	if w := request("PATCH", token, map[string]any{"username": "小林", "id": other.ID}); w.Code != 400 {
		t.Fatal("unknown identity field accepted")
	}
	if w := request("PATCH", token, map[string]any{"username": " 小林 "}); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	got, _ := db.GetUserByID(user.ID)
	untouched, _ := db.GetUserByID(other.ID)
	if got.Username != "小林" || untouched.Username != "" {
		t.Fatal("wrong account updated")
	}
	w := request(http.MethodGet, token, nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "小林") || strings.Contains(w.Body.String(), "password_hash") {
		t.Fatal(w.Body.String())
	}
}
