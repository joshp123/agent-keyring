// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package receiver

import (
	"context"
	"encoding/hex"
	"errors"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func normalizedPort(u *url.URL) string {
	port := u.Port()
	if (u.Scheme == "https" && port == "443") || (u.Scheme == "http" && port == "80") {
		return ""
	}
	return port
}

func CheckAllowedOrigin(origin string, sites []string) bool {
	actual, err := url.Parse(origin)
	if err != nil || actual.Hostname() == "" || actual.User != nil {
		return false
	}
	host := strings.TrimSuffix(strings.ToLower(actual.Hostname()), ".")
	loopback := host == "127.0.0.1" || host == "::1" || host == "localhost"
	if actual.Scheme != "https" && !(actual.Scheme == "http" && loopback) {
		return false
	}
	for _, site := range sites {
		if matchesOrigin(site, actual, host, loopback) {
			return true
		}
	}
	return false
}

func matchesOrigin(site string, actual *url.URL, host string, loopback bool) bool {
	if !strings.Contains(site, "://") {
		site = "https://" + site
	}
	saved, err := url.Parse(site)
	if err != nil || saved.Hostname() == "" || saved.User != nil || normalizedPort(actual) != normalizedPort(saved) {
		return false
	}
	savedHost := strings.TrimSuffix(strings.ToLower(saved.Hostname()), ".")
	if loopback {
		return saved.Scheme == actual.Scheme && savedHost == host
	}
	return saved.Scheme == "https" && matchesHost(host, savedHost)
}

func AcquireOperationLock(ctx context.Context, scope, target string) (func(), error) {
	store, err := clientstate.DefaultClientStateStore()
	if err != nil {
		return nil, err
	}
	directory := filepath.Join(store.Directory, "operation-locks")
	if err = os.MkdirAll(directory, 0700); err != nil {
		return nil, errors.New("Cannot create the local operation lock directory.")
	}
	path := filepath.Join(directory, hex.EncodeToString(ComputeOperationDigest(scope, target))+".lock")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, errors.New("Cannot lock this operation.")
	}
	fd := int(file.Fd())
	for {
		err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			// Closing this descriptor releases the flock.
			return func() { _ = file.Close() }, nil
		}
		if errors.Is(err, syscall.EINTR) {
			continue
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			_ = file.Close()
			return nil, errors.New("Cannot lock this operation.")
		}
		select {
		case <-ctx.Done():
			_ = file.Close()
			return nil, ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}
