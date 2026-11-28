// Written by AI on 2026.11.26 by model gemini-4-neon.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var (
	dohURLs = []string{
		"https://1.1.1.1/dns-query",
		"https://1.0.0.1/dns-query",
		"https://8.8.8.8/dns-query",
		"https://8.8.4.4/dns-query",
		"https://9.9.9.9/dns-query",
		"https://149.112.112.112/dns-query",
	}
	dnsCounter atomic.Uint64

	linkRe  = regexp.MustCompile(`(?i)<link\b[^>]*rel=["']?[^"']*icon[^"']*["']?[^>]*>`)
	hrefRe  = regexp.MustCompile(`(?i)href=["']([^"']+)["']`)
	sizesRe = regexp.MustCompile(`(?i)sizes=["'](\d+)x(\d+)["']`)

	wafMarkers = [][]byte{
		[]byte("just a moment"),
		[]byte("cf-browser-verification"),
		[]byte("attention required! | cloudflare"),
		[]byte("_incapsula_resource"),
		[]byte("datadome"),
		[]byte("access denied"),
		[]byte("px-captcha"),
	}
)

const userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"

type iconCrawlJob struct {
	domain string
	origin string
	rank   int
}

type iconLinkCandidate struct {
	score int
	url   string
}

func isWAFStatus(code int) bool {
	switch code {
	case 403, 406, 429, 503, 520, 521, 522, 523, 524, 525, 526:
		return true
	}
	return false
}

func looksLikeWAFBody(b []byte) bool {
	low := bytes.ToLower(b[:min(len(b), 2048)])
	for _, m := range wafMarkers {
		if bytes.Contains(low, m) {
			return true
		}
	}
	return false
}

func looksLikeValidIcon(data []byte, contentType, rawURL string) (ok bool, isSVG bool) {
	if len(data) < 32 {
		return false, false
	}
	head := bytes.ToLower(bytes.TrimSpace(data[:min(256, len(data))]))
	ct := strings.ToLower(contentType)
	path, _, _ := strings.Cut(strings.ToLower(rawURL), "?")
	inline := bytes.Contains(head, []byte("<svg"))
	if inline || strings.Contains(ct, "svg") || strings.HasSuffix(path, ".svg") {
		svg := inline || bytes.Contains(bytes.ToLower(data[:min(1024, len(data))]), []byte("<svg"))
		return svg, svg
	}
	if bytes.HasPrefix(head, []byte("<!doctype")) || bytes.HasPrefix(head, []byte("<html")) || strings.Contains(ct, "text/html") {
		return false, false
	}
	// PNG, ICO, CUR, JPEG, GIF, BMP, or WebP.
	for _, magic := range []string{"\x89PNG", "\x00\x00\x01\x00", "\x00\x00\x02\x00", "\xff\xd8\xff", "GIF8", "BM"} {
		if bytes.HasPrefix(data, []byte(magic)) {
			return true, false
		}
	}
	return bytes.HasPrefix(data, []byte("RIFF")) && bytes.Equal(data[8:12], []byte("WEBP")), false
}

func rankLinkTag(tag, href string) int {
	tag, href = strings.ToLower(tag), strings.ToLower(href)
	score := 10
	if strings.Contains(tag, "apple-touch-icon") {
		score += 40
	}
	if m := sizesRe.FindStringSubmatch(tag); m != nil {
		sz, err := strconv.Atoi(m[1])
		switch {
		case err == nil && sz > 256:
			score += 25
		case err == nil && sz >= 48:
			score += 35
		case err == nil && sz >= 32:
			score += 20
		}
	}
	switch {
	case strings.Contains(href, ".svg") || strings.Contains(tag, "svg"):
		return score + 30
	case strings.Contains(href, ".png") || strings.Contains(href, ".webp"):
		return score + 15
	case strings.Contains(href, ".ico"):
		return score + 5
	}
	return score
}

func inlineSVG(href string) []byte {
	if !strings.HasPrefix(strings.ToLower(href), "data:image/svg+xml") {
		return nil
	}
	if _, encoded, ok := strings.Cut(href, ";base64,"); ok {
		if raw, err := base64.StdEncoding.DecodeString(encoded); err == nil {
			return raw
		}
	} else if _, encoded, ok := strings.Cut(href, ","); ok {
		if raw, err := url.PathUnescape(encoded); err == nil {
			return []byte(raw)
		}
	}
	return nil
}

func extractCandidates(html []byte, finalURL *url.URL) ([]byte, []string) {
	var candidates []iconLinkCandidate
	for _, match := range linkRe.FindAll(html, 16) {
		tag := string(match)
		hm := hrefRe.FindStringSubmatch(tag)
		if hm == nil {
			continue
		}
		href := strings.TrimSpace(hm[1])
		if svg := inlineSVG(href); len(svg) >= 32 {
			return svg, nil
		}
		if href == "" || strings.HasPrefix(strings.ToLower(href), "data:") {
			continue
		}
		if ref, err := url.Parse(href); err == nil {
			candidates = append(candidates, iconLinkCandidate{rankLinkTag(tag, href), finalURL.ResolveReference(ref).String()})
		}
	}
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	if len(candidates) == 0 {
		return nil, nil
	}
	first := candidates[0].url
	for _, c := range candidates[1:] {
		if c.url != first {
			return nil, []string{first, c.url}
		}
	}
	return nil, []string{first}
}

func fetchBytes(ctx context.Context, client *http.Client, rawURL string, maxBytes int64) (status int, ct string, finalURL *url.URL, body []byte, wafHdr bool, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return 0, "", nil, nil, false, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "text/html,application/xhtml+xml,image/webp,image/png,image/*;q=0.8,*/*;q=0.5")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	resp, err := client.Do(req)
	if err != nil {
		return 0, "", nil, nil, false, err
	}
	defer func() {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		_ = resp.Body.Close()
	}()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes))
	waf := strings.EqualFold(resp.Header.Get("cf-mitigated"), "challenge")
	return resp.StatusCode, resp.Header.Get("Content-Type"), resp.Request.URL, data, waf, err
}

func tryIconURL(ctx context.Context, client *http.Client, rawURL string) ([]byte, bool, bool) {
	status, ct, finalURL, data, waf, err := fetchBytes(ctx, client, rawURL, 300_000)
	if err == nil && status == http.StatusOK {
		if ok, svg := looksLikeValidIcon(data, ct, finalURL.String()); ok {
			return data, svg, false
		}
	}
	return nil, false, err == nil && (waf || isWAFStatus(status))
}

func crawlOne(client *http.Client, j iconCrawlJob, perDomainTimeout time.Duration) ([]byte, bool, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), perDomainTimeout)
	defer cancel()
	status, ct, finalURL, html, waf, err := fetchBytes(ctx, client, j.origin+"/", 65_536)
	if err != nil {
		alt := "https://www." + j.domain
		if strings.HasPrefix(j.origin, "https://www.") {
			alt = "https://" + j.domain
		}
		if alt != j.origin {
			status, ct, finalURL, html, waf, err = fetchBytes(ctx, client, alt+"/", 65_536)
		}
	}
	page := err == nil && status == http.StatusOK && strings.Contains(strings.ToLower(ct), "html")
	blocked := err == nil && (waf || isWAFStatus(status) || page && looksLikeWAFBody(html))
	if page && !blocked {
		return crawlPage(ctx, client, finalURL, html)
	}
	data, svg, fallbackWAF := tryIconURL(ctx, client, j.origin+"/favicon.ico")
	return data, svg, data == nil && (blocked || fallbackWAF)
}

func crawlPage(ctx context.Context, client *http.Client, page *url.URL, html []byte) ([]byte, bool, bool) {
	svg, urls := extractCandidates(html, page)
	if svg != nil {
		return svg, true, false
	}
	root := page.Scheme + "://" + page.Host
	urls = append(urls, root+"/favicon.ico", root+"/apple-touch-icon.png")
	var waf bool
	for _, u := range urls {
		data, svg, blocked := tryIconURL(ctx, client, u)
		if data != nil {
			return data, svg, false
		}
		waf = waf || blocked
	}
	return nil, false, waf
}

type dohResolver struct {
	client *http.Client
	mu     sync.RWMutex
	cache  map[string]string
}

func buildDNSQueryA(host string) []byte {
	query := []byte{0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0}
	for label := range strings.SplitSeq(strings.TrimSuffix(host, "."), ".") {
		if len(label) == 0 || len(label) > 63 {
			return nil
		}
		query = append(append(query, byte(len(label))), label...)
	}
	return append(query, 0, 0, 1, 0, 1)
}

// Skip a DNS name without dereferencing compression pointers.
func skipDNSName(packet []byte, offset int) int {
	for ; offset < len(packet); offset += 1 + int(packet[offset]) {
		switch {
		case packet[offset] == 0:
			return offset + 1
		case packet[offset]&0xc0 == 0xc0:
			return offset + 2
		}
	}
	return offset
}

func parseDNSA(resp []byte) string {
	if len(resp) < 12 {
		return ""
	}
	answers := binary.BigEndian.Uint16(resp[6:8])
	pos := skipDNSName(resp, 12) + 4 // Skip the question's type and class.
	for range answers {
		pos = skipDNSName(resp, pos)
		if pos+10 > len(resp) {
			break
		}
		kind, size := binary.BigEndian.Uint16(resp[pos:]), int(binary.BigEndian.Uint16(resp[pos+8:]))
		pos += 10
		if kind == 1 && size == 4 && pos+size <= len(resp) {
			return net.IP(resp[pos : pos+size]).String()
		}
		pos += size
	}
	return ""
}

func (r *dohResolver) lookupA(ctx context.Context, host string) string {
	if net.ParseIP(host) != nil {
		return host
	}
	r.mu.RLock()
	ip, ok := r.cache[host]
	r.mu.RUnlock()
	if ok {
		return ip
	}
	q := buildDNSQueryA(host)
	if q == nil {
		return ""
	}
	for range 2 {
		u := dohURLs[dnsCounter.Add(1)%uint64(len(dohURLs))]
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader(q))
		if err != nil {
			return ""
		}
		req.Header.Set("Content-Type", "application/dns-message")
		req.Header.Set("Accept", "application/dns-message")
		resp, err := r.client.Do(req)
		if err != nil {
			continue
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
		_ = resp.Body.Close()
		if err == nil && resp.StatusCode == http.StatusOK {
			ip = parseDNSA(body)
			r.mu.Lock()
			if len(r.cache) > 120_000 {
				r.cache = make(map[string]string, 16384)
			}
			r.cache[host] = ip
			r.mu.Unlock()
			return ip
		}
	}
	return ""
}

func makeHTTPClient(concurrency int, customDNS bool) *http.Client {
	dialer := &net.Dialer{Timeout: 2200 * time.Millisecond, KeepAlive: 15 * time.Second}
	dialCtx := dialer.DialContext
	if customDNS {
		doh := &dohResolver{
			client: &http.Client{Timeout: 2500 * time.Millisecond, Transport: &http.Transport{
				ForceAttemptHTTP2: true, MaxIdleConns: 128, MaxIdleConnsPerHost: 32,
				IdleConnTimeout: 60 * time.Second, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12},
			}},
			cache: make(map[string]string, 16384),
		}
		dialCtx = func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return dialer.DialContext(ctx, network, addr)
			}
			if ip := doh.lookupA(ctx, host); ip != "" {
				return dialer.DialContext(ctx, "tcp4", net.JoinHostPort(ip, port))
			}
			return nil, fmt.Errorf("doh lookup failed for %s", host)
		}
	}
	return &http.Client{
		Transport: &http.Transport{
			DialContext: dialCtx, TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
			TLSHandshakeTimeout: 2500 * time.Millisecond, ResponseHeaderTimeout: 3 * time.Second,
			ExpectContinueTimeout: time.Second, IdleConnTimeout: 5 * time.Second,
			MaxIdleConns: concurrency * 2, MaxIdleConnsPerHost: 2, MaxConnsPerHost: 4,
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return http.ErrUseLastResponse
			}
			return nil
		},
	}
}

type iconCrawlOptions struct {
	input, output, retry       string
	workers, timeoutMS, cutoff int
	customDNS                  bool
}

func main() {
	var options iconCrawlOptions
	flag.StringVar(&options.input, "input", "", "Input TSV: domain\\torigin\\trank")
	flag.StringVar(&options.output, "output", "", "Output raw icon binary stream")
	flag.StringVar(&options.retry, "waf-out", "", "Output WAF/top-rank retry TSV")
	flag.IntVar(&options.workers, "concurrency", 600, "Concurrent worker goroutines")
	flag.IntVar(&options.timeoutMS, "timeout-ms", 5500, "Per-domain total timeout in ms")
	flag.IntVar(&options.cutoff, "waf-rank-cutoff", 101000, "Also send misses with rank <= cutoff to WAF retry")
	flag.BoolVar(&options.customDNS, "custom-dns", true, "Use pure-Go rotating multi-resolver UDP DNS (1.1.1.1/8.8.8.8/9.9.9.9)")
	flag.Parse()

	if options.input == "" || options.output == "" {
		fmt.Fprintln(os.Stderr, "Usage: icon_crawler -input domains.tsv -output raw.bin [-waf-out waf.tsv]")
		os.Exit(2)
	}
	if err := options.runIconCrawler(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func (options iconCrawlOptions) runIconCrawler() (err error) {
	in, err := os.Open(options.input)
	if err != nil {
		return fmt.Errorf("open input: %w", err)
	}
	defer func() { err = errors.Join(err, in.Close()) }()
	out, err := os.Create(options.output)
	if err != nil {
		return fmt.Errorf("create output: %w", err)
	}
	defer func() { err = errors.Join(err, out.Close()) }()
	results := crawlOutput{icons: bufio.NewWriterSize(out, 4*1024*1024), cutoff: options.cutoff, start: time.Now()}
	if options.retry != "" {
		file, err := os.Create(options.retry)
		if err != nil {
			return fmt.Errorf("create waf-out: %w", err)
		}
		defer func() { err = errors.Join(err, file.Close()) }()
		results.retry = bufio.NewWriterSize(file, 1024*1024)
	}
	jobs := make(chan iconCrawlJob, options.workers*4)
	written := make(chan error, 1)
	completed := make(chan crawlResult, 16)
	go func() { written <- results.collectIconCrawlResults(completed) }()

	client := makeHTTPClient(options.workers, options.customDNS)
	defer client.CloseIdleConnections()
	var wg sync.WaitGroup
	timeout := time.Duration(options.timeoutMS) * time.Millisecond
	for range options.workers {
		wg.Go(func() {
			for j := range jobs {
				data, svg, waf := crawlOne(client, j, timeout)
				completed <- crawlResult{j, data, svg, waf}
			}
		})
	}
	total, readErr := enqueueIconCrawlJobs(in, jobs)
	close(jobs)
	wg.Wait()
	close(completed)
	writeErr := <-written
	dt := time.Since(results.start).Seconds()
	fmt.Fprintf(os.Stderr, "[go-crawl DONE] %d/%d in %.2fs (%.1f/s) hits=%d (%.1f%%, svg=%d) waf_retry=%d\n",
		results.done, total, dt, float64(results.done)/max(0.01, dt), results.hits, results.hitPercent(), results.svg, results.waf)
	return errors.Join(readErr, writeErr)
}

func enqueueIconCrawlJobs(input io.Reader, jobs chan<- iconCrawlJob) (int, error) {
	sc := bufio.NewScanner(input)
	sc.Buffer(make([]byte, 256*1024), 1024*1024)
	total := 0
	for sc.Scan() {
		domain, rest, ok := strings.Cut(strings.TrimSpace(sc.Text()), "\t")
		if !ok {
			continue
		}
		origin, rest, _ := strings.Cut(rest, "\t")
		rankText, _, _ := strings.Cut(rest, "\t")
		rank, err := strconv.Atoi(rankText)
		if err != nil {
			rank = 9999999
		}
		jobs <- iconCrawlJob{domain, origin, rank}
		total++
	}
	return total, sc.Err()
}

type crawlResult struct {
	iconCrawlJob
	data     []byte
	svg, waf bool
}

type crawlOutput struct {
	icons, retry                 *bufio.Writer
	start                        time.Time
	cutoff, done, hits, svg, waf int
}

func (o *crawlOutput) collectIconCrawlResults(results <-chan crawlResult) error {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case r, ok := <-results:
			if !ok {
				err := o.icons.Flush()
				if o.retry != nil {
					err = errors.Join(err, o.retry.Flush())
				}
				return err
			}
			o.writeCrawledIcon(r)
		case <-ticker.C:
			if o.done > 0 {
				fmt.Fprintf(os.Stderr, "[go-crawl] done=%d (%.1f/s) hits=%d (%.1f%%, svg=%d) waf_retry=%d\n",
					o.done, float64(o.done)/time.Since(o.start).Seconds(), o.hits, o.hitPercent(), o.svg, o.waf)
			}
		}
	}
}

func (o *crawlOutput) hitPercent() float64 {
	return 100 * float64(o.hits) / max(1, float64(o.done))
}

// The buffered writers retain write errors for Flush.
func (o *crawlOutput) writeCrawledIcon(r crawlResult) {
	o.done++
	if r.data == nil {
		if o.retry != nil && (r.waf || r.rank <= o.cutoff) {
			o.waf++
			_, _ = fmt.Fprintf(o.retry, "%s\t%s\t%d\n", r.domain, r.origin, r.rank)
		}
		return
	}
	o.hits++
	var svg byte
	if r.svg {
		o.svg++
		svg = 1
	}
	if len(r.domain) >= 65535 {
		return
	}
	var hdr [7]byte
	binary.LittleEndian.PutUint16(hdr[:2], uint16(len(r.domain)))
	hdr[2] = svg
	binary.LittleEndian.PutUint32(hdr[3:], uint32(len(r.data)))
	_, _ = o.icons.Write(hdr[:2])
	_, _ = o.icons.WriteString(r.domain)
	_, _ = o.icons.Write(hdr[2:])
	_, _ = o.icons.Write(r.data)
}
