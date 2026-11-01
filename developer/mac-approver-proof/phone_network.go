// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"encoding/binary"
	"io"
	"net"
	"sync"
)

// Transparent TLS fault injection, adapted from script/relay_fixture/phone.go.
// Existing WatchWork connections remain intact. When armed, new Mac calls get
// the TLS handshake but lose application replies after the relay commits them.
type approvalNetwork struct {
	sync.Mutex
	target, address string
	listener        net.Listener
	connections     []net.Conn
	loseReply       bool
	passNewCalls    int
	pauseNewCalls   bool
	dropped         int
}

func (n *approvalNetwork) up() {
	listener, err := net.Listen("tcp", n.address)
	must(err)
	n.Lock()
	n.listener = listener
	n.address = listener.Addr().String()
	n.Unlock()
	go func() {
		for {
			downstream, err := listener.Accept()
			if err != nil {
				return
			}
			n.Lock()
			paused := n.pauseNewCalls
			n.Unlock()
			if paused {
				downstream.Close()
				continue
			}
			upstream, err := net.Dial("tcp", n.target)
			must(err)
			n.Lock()
			lose := n.loseReply
			if lose && n.passNewCalls > 0 {
				n.passNewCalls--
				lose = false
			}
			n.connections = append(n.connections, downstream, upstream)
			n.Unlock()
			go func() { defer downstream.Close(); defer upstream.Close(); io.Copy(upstream, downstream) }()
			go func() {
				defer downstream.Close()
				defer upstream.Close()
				encrypted := 0
				for {
					header := make([]byte, 5)
					if _, err := io.ReadFull(upstream, header); err != nil {
						return
					}
					payload := make([]byte, int(binary.BigEndian.Uint16(header[3:])))
					if _, err := io.ReadFull(upstream, payload); err != nil {
						return
					}
					if header[0] == 23 {
						encrypted++
					}
					if lose && encrypted > 5 {
						n.Lock()
						n.dropped++
						n.Unlock()
						continue
					}
					if _, err := downstream.Write(append(header, payload...)); err != nil {
						return
					}
				}
			}()
		}
	}()
}

func (n *approvalNetwork) down() {
	n.Lock()
	defer n.Unlock()
	n.listener.Close()
	for _, connection := range n.connections {
		connection.Close()
	}
	n.connections = nil
}
