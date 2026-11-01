// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package receiver

import (
	"context"
	"encoding/hex"
	"errors"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func AllowedOrigin(origin string, sites []string) bool {
	actual, err := url.Parse(origin)
	if err != nil || actual.Hostname() == "" || actual.User != nil {
		return false
	}
	loopback := actual.Hostname() == "127.0.0.1" || actual.Hostname() == "::1" || actual.Hostname() == "localhost"
	if actual.Scheme != "https" && !(actual.Scheme == "http" && loopback) {
		return false
	}
	for _, site := range sites {
		if !strings.Contains(site, "://") {
			site = "https://" + site
		}
		saved, err := url.Parse(site)
		if err != nil || saved.Hostname() == "" || saved.User != nil {
			continue
		}
		host := strings.ToLower(actual.Hostname())
		savedHost := strings.ToLower(saved.Hostname())
		if loopback {
			if saved.Scheme == actual.Scheme && saved.Host == actual.Host {
				return true
			}
			continue
		}
		if saved.Scheme == "https" && (host == savedHost || strings.HasSuffix(host, "."+savedHost)) && actual.Port() == saved.Port() {
			return true
		}
	}
	return false
}
func LockOperation(ctx context.Context, scope, target string) (func(), error) {
	store, err := clientstate.Default()
	if err != nil {
		return nil, err
	}
	directory := filepath.Join(store.Directory, "operation-locks")
	if err = os.MkdirAll(directory, 0700); err != nil {
		return nil, errors.New("Cannot create the local operation lock directory.")
	}
	path := filepath.Join(directory, hex.EncodeToString(Digest(scope, target))+".lock")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, errors.New("Cannot lock this operation.")
	}
	fd := int(file.Fd())
	for {
		err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return func() { syscall.Flock(fd, syscall.LOCK_UN); file.Close() }, nil
		}
		if err == syscall.EINTR {
			continue
		}
		if err != syscall.EWOULDBLOCK {
			file.Close()
			return nil, errors.New("Cannot lock this operation.")
		}
		select {
		case <-ctx.Done():
			file.Close()
			return nil, ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}
