package database

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// ---- User operations ----

// User represents a registered user.
type User struct {
	Username     string `json:"username"`
	ID           string `json:"id"`
	Email        string `json:"email"`
	PasswordHash string `json:"-"`
	CreatedAt    int64  `json:"created_at"`
}

// Network represents a virtual network.
type Network struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	CIDR      string `json:"cidr"`
	OwnerID   string `json:"owner_id"`
	CreatedAt int64  `json:"created_at"`
}

// CreateUser inserts a new user.
func (db *DB) CreateUser(email, passwordHash string) (*User, error) {
	id := fmt.Sprintf("user-%d", time.Now().UnixNano())
	now := time.Now().Unix()

	_, err := db.Exec(`INSERT INTO users (id, email, password_hash, created_at) VALUES (?, ?, ?, ?)`,
		id, email, passwordHash, now)
	if err != nil {
		return nil, err
	}

	// Keep the legacy default-network membership so existing clients can
	// register without a migration. Membership grants network registration
	// access; it does not grant visibility or management rights over another
	// account's devices.
	db.CreateNetworkMembership(id, "default", "member")
	return &User{ID: id, Email: email, PasswordHash: passwordHash, CreatedAt: now}, nil
}

// GetUserByEmail looks up a user by email.
func (db *DB) GetUserByEmail(email string) (*User, error) {
	var u User
	err := db.QueryRow(`SELECT id, email, password_hash, created_at, username FROM users WHERE email = ?`, email).
		Scan(&u.ID, &u.Email, &u.PasswordHash, &u.CreatedAt, &u.Username)
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// GetUserByLoginIdentifier resolves either the account email or its optional
// display username. Usernames are not unique in legacy databases, so an
// ambiguous username is rejected rather than selecting an arbitrary account.
func (db *DB) GetUserByLoginIdentifier(identifier string) (*User, error) {
	identifier = strings.TrimSpace(identifier)
	if identifier == "" {
		return nil, sql.ErrNoRows
	}
	if user, err := db.GetUserByEmail(strings.ToLower(identifier)); err == nil {
		return user, nil
	}

	rows, err := db.Query(`
		SELECT id, email, password_hash, created_at, username
		FROM users
		WHERE username = ?
		LIMIT 2`, identifier)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var match *User
	count := 0
	for rows.Next() {
		var user User
		if err := rows.Scan(
			&user.ID,
			&user.Email,
			&user.PasswordHash,
			&user.CreatedAt,
			&user.Username,
		); err != nil {
			return nil, err
		}
		count++
		if count == 1 {
			match = &user
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if count != 1 {
		return nil, sql.ErrNoRows
	}
	return match, nil
}

var ErrInvalidUsername = errors.New("username must contain 1–32 characters without control characters")

func ValidUsername(name string) bool {
	if !utf8.ValidString(name) || utf8.RuneCountInString(name) < 1 || utf8.RuneCountInString(name) > 32 {
		return false
	}
	for _, c := range name {
		if unicode.IsControl(c) || unicode.In(c, unicode.Cf) {
			return false
		}
	}
	return strings.TrimSpace(name) == name
}

func (db *DB) GetUserByID(id string) (*User, error) {
	var u User
	err := db.QueryRow(`SELECT id, email, username, created_at FROM users WHERE id = ?`, id).Scan(&u.ID, &u.Email, &u.Username, &u.CreatedAt)
	return &u, err
}

func (db *DB) UpdateUsername(id, name string) (*User, error) {
	name = strings.TrimSpace(name)
	if !ValidUsername(name) {
		return nil, ErrInvalidUsername
	}
	if _, err := db.Exec(`UPDATE users SET username = ? WHERE id = ?`, name, id); err != nil {
		return nil, err
	}
	return db.GetUserByID(id)
}
