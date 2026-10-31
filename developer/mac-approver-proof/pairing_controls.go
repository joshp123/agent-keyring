// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
)

func (p *proof) probeAddress(address, host string, allowed bool) {
	listener, err := tls.Listen("tcp", net.JoinHostPort(address, "0"), &tls.Config{
		Certificates: []tls.Certificate{identity()}, MinVersion: tls.VersionTLS13, ClientAuth: tls.RequireAnyClientCert,
	})
	must(err)
	defer listener.Close()
	result := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			result <- err
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(15 * time.Second))
		if err = conn.(*tls.Conn).Handshake(); err != nil {
			result <- err
			return
		}
		if allowed {
			request := new(pb.RelayWireRequest)
			err = authority.ReadFrame(conn, request)
			if err == nil && request.GetPairApprover() == nil {
				err = fmt.Errorf("expected pairing request")
			}
			if err == nil {
				err = authority.WriteFrame(conn, &pb.RelayWireResponse{Response: &pb.RelayWireResponse_EnrolStatus{
					EnrolStatus: &pb.EnrolStatus{State: pb.EnrolState_ENROL_STATE_PENDING},
				}})
			}
		} else {
			var bytes [4]byte
			n, readError := conn.Read(bytes[:])
			if n != 0 || readError == nil {
				err = fmt.Errorf("rejected destination received application data: %d, %v", n, readError)
			}
			if timeout, ok := readError.(net.Error); ok && timeout.Timeout() {
				err = readError
			}
		}
		result <- err
	}()
	port := strconv.Itoa(listener.Addr().(*net.TCPAddr).Port)
	if allowed {
		p.owner.action("pair", port, host, "false")
		p.owner.status()
		require(p.owner.pairVisible, "tailnet host did not reach comparison")
		p.owner.action("abandon")
	} else {
		failure := p.owner.expectFailure("pair", port, host, "false")
		require(strings.Contains(failure[2], "Tailscale"), "connection failed before checking its resolved address")
	}
	must(<-result)
}

func (p *proof) pendingPhone() (*tls.Conn, string, string) {
	phone := client{address: "127.0.0.1:17445", cert: identity()}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	must(err)
	public := elliptic.Marshal(elliptic.P256(), key.X, key.Y)
	spki, err := relaycrypto.CertificateSPKI(phone.cert)
	must(err)
	id := fmt.Sprintf("%x", relaycrypto.Hash(public))
	conn := phone.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PairApprover{PairApprover: &pb.PairApproverRequest{
		Key: &pb.ApproverKey{KeyId: id, Label: "Dummy phone comparison", PublicKey: public, TlsPublicKey: spki}, TlsPublicKey: spki,
	}}})
	status := receive(conn).GetEnrolStatus()
	require(status.State == pb.EnrolState_ENROL_STATE_PENDING, "phone pairing activated without confirmation")
	work := p.owner.wait(func(e []string) bool { return e[0] == "APPROVER" && e[1] == id })
	return conn, id, work[2]
}

func (p *proof) runPairingControls() {
	p.owner = startOwner(p.fixture, p.root)
	defer func() { p.owner.stop() }()
	addresses, err := net.InterfaceAddrs()
	must(err)
	var lan, tailnet string
	for _, address := range addresses {
		ip, _, err := net.ParseCIDR(address.String())
		if err != nil || ip.To4() == nil {
			continue
		}
		v4 := ip.To4()
		if v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127 {
			tailnet = ip.String()
		}
		if ip.IsPrivate() {
			lan = ip.String()
		}
	}
	require(lan != "" && tailnet != "", "mini proof needs its existing LAN and Tailscale addresses")
	p.probeAddress("127.0.0.1", "localhost", false)
	p.probeAddress(lan, lan, false)
	host := os.Getenv("AGENT_KEYRING_PROOF_TAILNET_HOST")
	require(host != "" && net.ParseIP(host) == nil, "supply the mini's MagicDNS name in AGENT_KEYRING_PROOF_TAILNET_HOST")
	p.probeAddress(tailnet, host, true)
	fmt.Println("PASS host name over Tailscale; LAN and default loopback refused before any protobuf bytes")
	p.startRelay()
	defer p.stopRelay()
	p.owner.action("pair", "17445", "localhost", "true")
	p.owner.status()
	require(p.owner.pairVisible, "proof loopback hostname did not reach comparison")
	p.owner.action("abandon")
	p.owner.status()
	require(!p.owner.pairVisible && p.owner.queued == 0 && p.owner.authorizations == 0, "abandon left pending setup or authorized anything")
	p.owner.stop()
	p.owner = startOwner(p.fixture, p.root)
	p.owner.status()
	require(!p.owner.pairVisible, "abandoned setup reappeared after restart")
	p.pair()
	fmt.Println("PASS abandoned setup stays unpaired after restart and can pair again")
	first, id, fingerprint := p.pendingPhone()
	defer first.Close()
	p.owner.status()
	before := p.owner.authorizations
	p.owner.action("dismiss-approver", id)
	p.owner.action("reconnect")
	second, secondID, _ := p.pendingPhone()
	defer second.Close()
	p.owner.status()
	require(p.owner.pendingApprovers == secondID, "dismissed pairing reappeared after reconnect")
	p.owner.stop()
	p.owner = startOwner(p.fixture, p.root)
	p.owner.wait(func(e []string) bool { return e[0] == "APPROVER" && e[1] == secondID })
	p.owner.status()
	require(p.owner.pendingApprovers == secondID, "dismissed pairing reappeared after restart")
	p.owner.expectFailure("confirm-approver", id, fingerprint)
	p.owner.status()
	require(p.owner.authorizations == before && p.owner.queued == 0, "dismissal authorized or queued a confirmation")
	fmt.Println("PASS dismissed phone pairing stays hidden across reconnect and restart; confirmation refused without a touch")
}
