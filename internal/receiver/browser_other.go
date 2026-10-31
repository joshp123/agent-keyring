//go:build !darwin

// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package receiver

import "errors"

func browserIdentity(port string) (string, error) {
	return "", errors.New("Browser endpoint ownership is currently supported on macOS only. This receiver is unavailable on this platform.")
}
