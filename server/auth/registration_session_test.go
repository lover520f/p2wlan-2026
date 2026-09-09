package auth

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/yhan-sun/p2wlan/server/database"
)

func TestCurrentDeviceRegistrationSessionRequiresExactSequenceOnlyAfterUpgrade(t *testing.T) {
	db, err := database.New(filepath.Join(t.TempDir(), "control.db"))
	if err != nil {
		t.Fatalf("database.New: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	user, err := db.CreateUser("registration-session@example.com", "hash")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	device, err := db.CreateDevice(user.ID, "default", "registration-session-key", "before", "macos", "")
	if err != nil {
		t.Fatalf("CreateDevice: %v", err)
	}
	_, credential, err := db.CreateDeviceCredential(device.ID, 3600)
	if err != nil {
		t.Fatalf("CreateDeviceCredential: %v", err)
	}

	incarnation := int64(7001)
	registered, err := db.RegisterDeviceWithOptions(
		user.ID, device.NetworkID, device.PublicKey, "after", "macos", "", "", "",
		database.DeviceRegistrationAttempt{Incarnation: &incarnation, EnforceIncarnation: true},
	)
	if err != nil {
		t.Fatalf("RegisterDeviceWithOptions: %v", err)
	}
	if registered.RegistrationIncarnation != incarnation || registered.RegistrationSeq <= device.RegistrationSeq {
		t.Fatalf("registration did not advance lifecycle: before=%+v after=%+v", device, registered)
	}

	called := 0
	handler := RequireDeviceAuth(db)(RequireCurrentDeviceRegistrationSession(db)(func(w http.ResponseWriter, _ *http.Request) {
		called++
		w.WriteHeader(http.StatusNoContent)
	}))

	request := func(headerValues ...string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/control", nil)
		req.Header.Set("Authorization", "Bearer "+credential)
		for _, value := range headerValues {
			req.Header.Add(RegistrationSequenceHeader, value)
		}
		recorder := httptest.NewRecorder()
		handler(recorder, req)
		return recorder
	}

	for name, values := range map[string][]string{
		"missing":         nil,
		"wrong":           {"1"},
		"whitespace":      {" " + fmtInt64ForSessionTest(registered.RegistrationSeq)},
		"noncanonical":    {"0" + fmtInt64ForSessionTest(registered.RegistrationSeq)},
		"duplicate":       {fmtInt64ForSessionTest(registered.RegistrationSeq), fmtInt64ForSessionTest(registered.RegistrationSeq)},
		"malformed":       {"two"},
		"zero":            {"0"},
		"negative":        {"-1"},
		"larger sequence": {fmtInt64ForSessionTest(registered.RegistrationSeq + 1)},
	} {
		t.Run(name, func(t *testing.T) {
			recorder := request(values...)
			if recorder.Code != http.StatusConflict {
				t.Fatalf("HTTP %d: %s", recorder.Code, recorder.Body.String())
			}
			if !strings.Contains(recorder.Body.String(), RegistrationLifecycleConflictCode) {
				t.Fatalf("missing lifecycle conflict code: %s", recorder.Body.String())
			}
		})
	}
	if called != 0 {
		t.Fatalf("stale registration session reached protected handler %d times", called)
	}

	valid := request(fmtInt64ForSessionTest(registered.RegistrationSeq))
	if valid.Code != http.StatusNoContent || called != 1 {
		t.Fatalf("current sequence was not accepted: HTTP %d called=%d body=%s", valid.Code, called, valid.Body.String())
	}

	// Device rows created before registration-incarnation support remain
	// header-free during the rolling upgrade.
	legacy, err := db.CreateDevice(user.ID, "default", "registration-session-legacy", "legacy", "linux", "")
	if err != nil {
		t.Fatalf("CreateDevice legacy: %v", err)
	}
	_, legacyCredential, err := db.CreateDeviceCredential(legacy.ID, 3600)
	if err != nil {
		t.Fatalf("CreateDeviceCredential legacy: %v", err)
	}
	legacyCalled := false
	legacyHandler := RequireDeviceAuth(db)(RequireCurrentDeviceRegistrationSession(db)(func(w http.ResponseWriter, _ *http.Request) {
		legacyCalled = true
		w.WriteHeader(http.StatusNoContent)
	}))
	legacyReq := httptest.NewRequest(http.MethodGet, "/control", nil)
	legacyReq.Header.Set("Authorization", "Bearer "+legacyCredential)
	legacyRecorder := httptest.NewRecorder()
	legacyHandler(legacyRecorder, legacyReq)
	if legacyRecorder.Code != http.StatusNoContent || !legacyCalled {
		t.Fatalf("legacy device should remain compatible: HTTP %d %s", legacyRecorder.Code, legacyRecorder.Body.String())
	}
}

func fmtInt64ForSessionTest(value int64) string {
	return strconv.FormatInt(value, 10)
}
