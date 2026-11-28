// Written by AI on 2026.11.22 by model Gemini 4 Neon.
package receiver

import (
	_ "embed"
	"net/netip"
	"strings"
)

//go:embed public_suffix_rules.txt
var rawPublicSuffixRules string

var (
	pslExact map[string]struct{}
	pslWild  map[string]struct{}
	pslExc   map[string]struct{}
)

func init() {
	pslExact = make(map[string]struct{}, 11000)
	pslWild = make(map[string]struct{}, 400)
	pslExc = make(map[string]struct{}, 16)
	for _, line := range strings.Split(rawPublicSuffixRules, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		switch {
		case strings.HasPrefix(line, "!"):
			pslExc[line[1:]] = struct{}{}
		case strings.HasPrefix(line, "*."):
			pslWild[line[2:]] = struct{}{}
		default:
			pslExact[line] = struct{}{}
		}
	}
}

// publicSuffixLabels returns the number of rightmost labels forming the prevailing
// public suffix for labels (ICANN + Private rules, falling back to "*" -> 1 label).
func publicSuffixLabels(labels []string) int {
	n := len(labels)
	// Exception rules always take priority over exact and wildcard rules.
	for i := 0; i < n; i++ {
		sub := strings.Join(labels[i:], ".")
		if _, ok := pslExc[sub]; ok {
			return n - i - 1
		}
	}
	best := 1
	for i := 0; i < n; i++ {
		sub := strings.Join(labels[i:], ".")
		if _, ok := pslExact[sub]; ok {
			if l := n - i; l > best {
				best = l
			}
		}
		if _, ok := pslWild[sub]; ok {
			l := n - i
			if i > 0 {
				l = n - (i - 1)
			}
			if l > best {
				best = l
			}
		}
	}
	return best
}

// registrableDomain returns the eTLD+1 registrable domain for host under the full
// ICANN + Private Public Suffix List, or "" when host is a public suffix, IP, or invalid.
func registrableDomain(host string) string {
	clean := strings.TrimSuffix(strings.ToLower(host), ".")
	if clean == "" {
		return ""
	}
	if _, err := netip.ParseAddr(clean); err == nil {
		return ""
	}
	labels := strings.Split(clean, ".")
	if len(labels) < 2 {
		return ""
	}
	for _, label := range labels {
		if label == "" {
			return ""
		}
	}
	suffixLen := publicSuffixLabels(labels)
	if len(labels) <= suffixLen {
		return ""
	}
	return strings.Join(labels[len(labels)-suffixLen-1:], ".")
}

// matchesHost reports whether actualHost is savedHost or a same-tenant subdomain of savedHost.
func matchesHost(actualHost, savedHost string) bool {
	if actualHost == savedHost {
		return true
	}
	if !strings.HasSuffix(actualHost, "."+savedHost) {
		return false
	}
	savedReg := registrableDomain(savedHost)
	return savedReg != "" && savedReg == registrableDomain(actualHost)
}
