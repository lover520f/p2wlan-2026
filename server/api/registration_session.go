package api

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"sync"

	"github.com/yhan-sun/p2wlan/server/auth"
	"github.com/yhan-sun/p2wlan/server/database"
	"github.com/yhan-sun/p2wlan/server/signaling"
)

type registrationSessionContextKey struct{}

type registrationSessionLocker interface {
	Lock(deviceID string) func()
}

type deviceRegistrationSessionLocks struct {
	locks sync.Map // map[string]*sync.Mutex
}

func newRegistrationSessionLocks() *deviceRegistrationSessionLocks {
	return &deviceRegistrationSessionLocks{}
}

func (locks *deviceRegistrationSessionLocks) Lock(deviceID string) func() {
	value, _ := locks.locks.LoadOrStore(deviceID, &sync.Mutex{})
	lock := value.(*sync.Mutex)
	lock.Lock()
	return lock.Unlock
}

// RequireCurrentDeviceRegistrationSession validates the sequence proof and
// serializes the validated device-token REST action with device
// re-registration.  The mutex is deliberately per device: a long signal poll
// for one daemon must not delay an unrelated daemon's registration.
// Endpoint and presence writes additionally re-check the sequence in their
// database write transaction. The signaling hub and this lock are process
// local, so a future multi-process control-plane deployment must add shared
// session fencing and connection eviction before it is supported.
func (s *Server) RequireCurrentDeviceRegistrationSession(next http.HandlerFunc) http.HandlerFunc {
	return s.requireCurrentDeviceRegistrationSession(next)
}

func (s *Server) requireCurrentDeviceRegistrationSession(next http.HandlerFunc) http.HandlerFunc {
	validated := auth.RequireCurrentDeviceRegistrationSession(s.db)(func(w http.ResponseWriter, r *http.Request) {
		if _, err := auth.GetDeviceClaims(r.Context()); err == nil {
			if sequence, ok := registrationSequenceFromHeader(r); ok {
				r = r.WithContext(context.WithValue(r.Context(), registrationSessionContextKey{}, sequence))
			}
		}
		next(w, r)
	})

	return func(w http.ResponseWriter, r *http.Request) {
		claims, err := auth.GetDeviceClaims(r.Context())
		if err != nil {
			validated(w, r)
			return
		}
		unlock := s.lockDeviceRegistrationSession(claims.DeviceID)
		defer unlock()
		validated(w, r)
	}
}

// WebSocketRegistrationSessionGuard keeps a device's registration lock from
// the authoritative sequence re-check through signaling.Hub.register.  The
// signaling package releases it immediately after registration, before the
// socket begins its long-lived read/write pumps.
func (s *Server) WebSocketRegistrationSessionGuard() signaling.UpgradeGuard {
	return func(w http.ResponseWriter, r *http.Request) (func(), bool) {
		claims, err := auth.GetDeviceClaims(r.Context())
		if err != nil {
			http.Error(w, `{"error":"device authentication required"}`, http.StatusUnauthorized)
			return nil, false
		}
		unlock := s.lockDeviceRegistrationSession(claims.DeviceID)
		accepted := false
		auth.RequireCurrentDeviceRegistrationSession(s.db)(func(http.ResponseWriter, *http.Request) {
			accepted = true
		})(w, r)
		if !accepted {
			unlock()
			return nil, false
		}
		return unlock, true
	}
}

func (s *Server) lockDeviceRegistrationSession(deviceID string) func() {
	if deviceID == "" {
		return func() {}
	}
	return s.registrationSessionLocks.Lock(deviceID)
}

func registrationSequenceFromHeader(r *http.Request) (int64, bool) {
	values := r.Header.Values(auth.RegistrationSequenceHeader)
	if len(values) != 1 {
		return 0, false
	}
	sequence, err := strconv.ParseInt(values[0], 10, 64)
	if err != nil || sequence <= 0 {
		return 0, false
	}
	return sequence, true
}

func currentRequestRegistrationSequence(r *http.Request) (int64, bool) {
	sequence, ok := r.Context().Value(registrationSessionContextKey{}).(int64)
	return sequence, ok && sequence > 0
}

func writeRegistrationSessionConflict(w http.ResponseWriter, err error) bool {
	var conflict *database.RegistrationSessionConflictError
	if !errors.As(err, &conflict) {
		return false
	}
	writeJSON(w, http.StatusConflict, map[string]interface{}{
		"error":            "device registration session is no longer current",
		"error_code":       auth.RegistrationLifecycleConflictCode,
		"registration_seq": conflict.CurrentSequence,
	})
	return true
}
