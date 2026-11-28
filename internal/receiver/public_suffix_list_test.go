// Written by AI on 2026.11.22 by model Gemini 4 Neon.
package receiver

import "testing"

func TestAllowedOriginPublicSuffixList(t *testing.T) {
	cases := []struct {
		name  string
		url   string
		sites []string
		want  bool
	}{
		{"exact match", "https://example.com/login", []string{"example.com"}, true},
		{"valid subdomain", "https://accounts.example.com/login", []string{"example.com"}, true},
		{"valid multi-label subdomain", "https://login.bbc.co.uk/", []string{"bbc.co.uk"}, true},
		{"block ICANN public suffix wildcard", "https://evil.co.uk/login", []string{"co.uk"}, false},
		{"block private multi-tenant github.io", "https://evil.github.io/login", []string{"github.io"}, false},
		{"allow exact private tenant", "https://myorg.github.io/login", []string{"myorg.github.io"}, true},
		{"allow subdomain of private tenant", "https://app.myorg.github.io/login", []string{"myorg.github.io"}, true},
		{"block sibling private tenant", "https://other.github.io/login", []string{"myorg.github.io"}, false},
		{"block private suffix amazonaws wildcard", "https://evil.s3.amazonaws.com/", []string{"s3.amazonaws.com"}, false},
		{"block nested delegated tenant under amazonaws.com", "https://evil.s3.amazonaws.com/", []string{"amazonaws.com"}, false},
		{"block nested delegated suffix itself under amazonaws.com", "https://s3.amazonaws.com/", []string{"amazonaws.com"}, false},
		{"allow same-tenant subdomain under amazonaws.com", "https://console.amazonaws.com/", []string{"amazonaws.com"}, true},
		{"block nested delegated execute-api tenant under amazonaws.com", "https://evil.execute-api.us-east-1.amazonaws.com/", []string{"amazonaws.com"}, false},
		{"block nested delegated wildcard tenant under amazonaws.com", "https://evil.compute.amazonaws.com/", []string{"amazonaws.com"}, false},
		{"block nested delegated tenant under windows.net", "https://evil.blob.core.windows.net/", []string{"windows.net"}, false},
		{"block wildcard rule parent", "https://evil.compute.amazonaws.com/", []string{"compute.amazonaws.com"}, false},
		{"block wildcard rule child as suffix", "https://a.b.ck/", []string{"b.ck"}, false},
		{"allow subdomain of wildcard tenant", "https://sub.a.b.ck/", []string{"a.b.ck"}, true},
		{"allow PSL exception www.ck", "https://sub.www.ck/", []string{"www.ck"}, true},
		{"block bare TLD", "https://example.com/", []string{"com"}, false},
		{"block IP wildcard", "https://sub.192.0.2.1/", []string{"192.0.2.1"}, false},
		{"allow loopback exact origin", "http://127.0.0.1:8080/login", []string{"http://127.0.0.1:8080"}, true},
		{"block loopback different port", "http://127.0.0.1:9090/login", []string{"http://127.0.0.1:8080"}, false},
		{"allow loopback uppercase host", "http://LOCALHOST:8080/login", []string{"http://localhost:8080"}, true},
		{"allow loopback saved uppercase host", "http://localhost:8080/login", []string{"http://Localhost:8080"}, true},
		{"allow loopback explicit http default port 80", "http://localhost:80/login", []string{"http://localhost"}, true},
		{"allow loopback saved explicit http default port 80", "http://127.0.0.1/login", []string{"http://127.0.0.1:80"}, true},
		{"allow loopback ipv6 explicit http default port 80", "http://[::1]:80/login", []string{"http://[::1]"}, true},
		{"allow loopback explicit https default port 443", "https://localhost:443/login", []string{"localhost"}, true},
		{"block loopback mismatched default port 443 on http", "http://localhost:443/login", []string{"http://localhost"}, false},
		{"allow https explicit default port 443", "https://example.com:443/login", []string{"example.com"}, true},
		{"allow https saved explicit default port 443", "https://example.com/login", []string{"https://example.com:443"}, true},
		{"block https mismatched port 80", "https://example.com:80/login", []string{"example.com"}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := CheckAllowedOrigin(tc.url, tc.sites); got != tc.want {
				t.Fatalf("AllowedOrigin(%q, %v) = %v, want %v", tc.url, tc.sites, got, tc.want)
			}
		})
	}
}
