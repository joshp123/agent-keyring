//go:build !darwin && !linux

// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package receiver

import "errors"

func browserIdentity(port string) (string, error) {
	return "", errors.New("Browser endpoint ownership is supported on macOS and Linux. This receiver is unavailable on this platform.")
}
