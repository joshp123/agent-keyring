// Written by AI on 2026.11.23 by model claude opus 5.5; GET, tokens, modes
// and grants, as push.opentrawl.sh has them, on 2026.11.24.
//
// agent-keyring-box is the box relay, for anyone who would rather run their
// own than use https://push.opentrawl.sh: the same /v1/box
// (proto/agentkeyring/v2/keyring.proto, "Boxes"), answering case for case as
// that relay does, held in memory only. It logs nothing about a box or who
// sent it. Put it behind HTTPS with a certificate the iPhone and Apple Watch
// trust (one from a public authority such as Let's Encrypt: they refuse plain
// HTTP and self-signed certificates), then set it on the Mac or iPhone that
// shows the join code, whose code link names it. Memory only means a restart forgets every box:
// joins and answers in flight are asked again, a grant is gone (so an approval
// is not used until it is asked again), and update mailboxes wait for the
// next change on the Mac or iPhone.
//
//	agent-keyring-box [--listen 127.0.0.1:8447]
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/opentrawl/agent-keyring/internal/boxserver"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:8447", "IP:PORT to serve on")
	scale := flag.Float64("test-ttl-scale", 1, "multiply every box's lifetime by this, for tests only")
	flag.Parse()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	listener, err := (&net.ListenConfig{}).Listen(ctx, "tcp", *listen)
	if err != nil {
		fmt.Fprintln(os.Stderr, "agent-keyring-box:", err)
		os.Exit(1)
	}
	fmt.Println("agent-keyring-box is serving boxes at", listener.Addr())
	server := &http.Server{Handler: boxserver.NewRelayBoxHandler(ctx, *scale), ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second,
		WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, ErrorLog: log.New(io.Discard, "", 0)}
	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintln(os.Stderr, "agent-keyring-box:", err)
		os.Exit(1)
	}
}
