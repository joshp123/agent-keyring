// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func (p *proof) idleProof() {
	raw, err := x509.MarshalPKCS8PrivateKey(signingKey())
	must(err)
	keyPath := filepath.Join(p.directory, "idle-apns.p8")
	must(os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: raw}), 0600))
	// No notification is queued; this still starts the real push worker.
	p.extraFlags = []string{"--apns-key", keyPath, "--apns-key-id", "DUMMYKEY01", "--apns-team-id", "DUMMYTEAM1", "--apns-topic", "test.agent-keyring.phone"}
	logPath := filepath.Join(p.directory, "idle-relay.log")
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY, 0600)
	must(err)
	p.relayLog = log
	p.start()
	defer p.stop()
	p.pair()
	defer p.work.Close()
	p.enrol()
	must(p.work.SetDeadline(time.Time{}))
	// Go records waitsince during GC, not when a goroutine first blocks. Allow
	// its two-minute forced-GC interval, then a full minute before SIGQUIT.
	// A 250 ms watcher or 1 s push poll cannot report a full minute in select.
	fmt.Println("Idle relay has an open approver watch and a push worker; observing for 185 seconds.")
	time.Sleep(185 * time.Second)
	must(p.process.Process.Signal(syscall.SIGQUIT))
	p.process.Wait()
	p.process = nil
	must(log.Close())
	trace, err := os.ReadFile(logPath)
	must(err)
	for _, function := range []string{"(*Server).serveConnection", "(*Server).maintain", "(*Server).sendPushes"} {
		blocked := false
		for _, goroutine := range strings.Split(string(trace), "\ngoroutine ") {
			header := strings.SplitN(goroutine, "\n", 2)[0]
			if strings.Contains(goroutine, function) && strings.Contains(header, "[select, ") && strings.Contains(header, " minutes]") {
				blocked = true
				break
			}
		}
		require(blocked, function+" did not stay idle for a full minute; see "+logPath)
	}
	fmt.Println("PASS idle WatchWork, deadline scheduler and push worker stayed blocked for a full minute; runtime trace:", logPath)
}
