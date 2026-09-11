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

func TestLoginAcceptsEmailAndAccountUsername(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "auth-handlers.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	service := auth.NewService("auth-handler-secret", db)
	_, user, err := service.Register("pyu@example.test", "password123")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.UpdateUsername(user.ID, "pyu"); err != nil {
		t.Fatal(err)
	}
	s := NewServer(service, nil, db)

	login := func(payload map[string]string) (int, map[string]any) {
		body, _ := json.Marshal(payload)
		r := httptest.NewRequest(http.MethodPost, "/api/v1/login", bytes.NewReader(body))
		w := httptest.NewRecorder()
		s.Login(w, r)
		var decoded map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &decoded)
		return w.Code, decoded
	}

	if code, body := login(map[string]string{"email": "pyu@example.test", "password": "password123"}); code != http.StatusOK || body["token"] == "" {
		t.Fatalf("email login failed: code=%d body=%v", code, body)
	}
	if code, body := login(map[string]string{"email": "pyu", "password": "password123"}); code != http.StatusOK || body["token"] == "" {
		t.Fatalf("username login failed: code=%d body=%v", code, body)
	}
	if code, body := login(map[string]string{"identifier": "pyu", "password": "password123"}); code != http.StatusOK || body["token"] == "" {
		t.Fatalf("identifier login failed: code=%d body=%v", code, body)
	}
}
