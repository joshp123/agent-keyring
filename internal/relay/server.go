// Written by AI on 2026.11.18 by model claude opus 5.5.
package relay

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"log/slog"
	"net"
	"sync"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/apns"
	"github.com/joshp123/agent-keyring/internal/wire"
)

const (
	joinWithin = 10 * time.Minute
)

type Server struct {
	Store       *Store
	Push        *apns.Sender // Nil: no pushes; devices see work on their stream.
	Ring        *Ring        // The relay's own recent log lines; nil keeps none.
	logsMu      sync.Mutex
	pushLocks   sync.Map // Request id: *sync.Mutex, so its pushes keep their order.
	deviceLogs  map[string][]string // Device key id: its latest log.
	Certificate tls.Certificate
	Lookup      NodeLookup
	Now         func() time.Time
	// How long a request waits for an answer: 10 minutes, shorter only in tests.
	AnswerWithin time.Duration
}

func (s *Server) answerWithin() time.Duration {
	if s.AnswerWithin > 0 {
		return s.AnswerWithin
	}
	return 10 * time.Minute
}

// caller is who a connection belongs to, by the TLS key it presented.
type caller struct {
	spki    []byte
	device  *pb.Device  // A device in Members.
	machine *pb.Machine // A machine in Members.
	node    string      // Tailscale node name.
	local   bool        // Connected from the relay's own computer (its own address).
}

type failure struct {
	code    pb.ErrorCode
	message string
}

func (f failure) Error() string { return f.message }

func fail(code pb.ErrorCode, message string) error { return failure{code, message} }

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Server) ownSPKI() []byte {
	parsed, err := x509.ParseCertificate(s.Certificate.Certificate[0])
	if err != nil {
		return nil
	}
	return parsed.RawSubjectPublicKeyInfo
}

func (s *Server) Serve(ctx context.Context, listener net.Listener) error {
	config := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{s.Certificate}, ClientAuth: tls.RequestClientCert}
	go s.keepDeadlines(ctx)
	go func() { <-ctx.Done(); listener.Close() }()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go s.handle(ctx, tls.Server(conn, config))
	}
}

func (s *Server) handle(ctx context.Context, conn *tls.Conn) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	if err := conn.HandshakeContext(ctx); err != nil {
		return
	}
	peer := conn.ConnectionState().PeerCertificates
	if len(peer) > 1 {
		return
	}
	who := caller{}
	if remote, ok := conn.RemoteAddr().(*net.TCPAddr); ok {
		if own, ok := conn.LocalAddr().(*net.TCPAddr); ok {
			who.local = remote.IP.Equal(own.IP)
		}
	}
	if s.Lookup != nil {
		lookupContext, cancel := context.WithTimeout(ctx, 5*time.Second)
		node, err := s.Lookup(lookupContext, conn.RemoteAddr().String())
		cancel()
		if err != nil {
			slog.Warn("refused a connection Tailscale could not identify", "address", conn.RemoteAddr().String())
			return
		}
		who.node = node.Name
	}
	if len(peer) == 0 {
		s.serveWatchAnswer(ctx, conn) // HTTPS with no client certificate: only the Watch's answers.
		return
	}
	who.spki = peer[0].RawSubjectPublicKeyInfo
	members, _ := s.Store.documents()
	if members != nil {
		for _, d := range members.Devices {
			if len(d.TlsPublicKey) > 0 && string(d.TlsPublicKey) == string(who.spki) {
				who.device = d
			}
		}
		for _, m := range members.Machines {
			if string(m.TlsPublicKey) == string(who.spki) {
				who.machine = m
			}
		}
	}
	request := &pb.RelayRequest{}
	if err := wire.Read(conn, request); err != nil {
		return
	}
	conn.SetDeadline(time.Time{})
	connectionContext, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() { // A closed connection ends any stream.
		buffer := make([]byte, 1)
		conn.Read(buffer)
		cancel()
	}()
	send := func(response *pb.RelayResponse) error {
		conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
		return wire.Write(conn, response)
	}
	err := s.dispatch(connectionContext, who, request, send)
	if err != nil {
		var known failure
		if !errors.As(err, &known) {
			slog.Error("request failed", "error", err)
			known = failure{pb.ErrorCode_ERROR_CODE_UNAVAILABLE, "The relay could not do that. Try again."}
		}
		send(&pb.RelayResponse{Result: &pb.RelayResponse_Error{Error: &pb.Error{Code: known.code, Message: known.message}}, EndOfStream: true})
	}
}

func done() *pb.RelayResponse {
	return &pb.RelayResponse{Result: &pb.RelayResponse_Done{Done: &pb.Empty{}}, EndOfStream: true}
}

func signed(document *pb.Signed) *pb.RelayResponse {
	return &pb.RelayResponse{Result: &pb.RelayResponse_Signed{Signed: document}, EndOfStream: true}
}

func (s *Server) dispatch(ctx context.Context, who caller, request *pb.RelayRequest, send func(*pb.RelayResponse) error) error {
	isMachine := func() error {
		if who.machine == nil {
			return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "This machine has not joined. Run 'agent-keyring enrol'.")
		}
		return nil
	}
	isDevice := func() error {
		if who.device == nil {
			return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "This device has not joined.")
		}
		return nil
	}
	switch method := request.Method.(type) {
	case *pb.RelayRequest_AskSigned:
		if err := isMachine(); err != nil {
			return err
		}
		lease, err := s.ask(ctx, who, method.AskSigned)
		if err != nil {
			return err
		}
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_Lease{Lease: lease}, EndOfStream: true})
	case *pb.RelayRequest_Watch:
		if err := isMachine(); err != nil {
			return err
		}
		return s.watch(ctx, who, method.Watch.RequestId, send)
	case *pb.RelayRequest_Collect:
		if err := isMachine(); err != nil {
			return err
		}
		approval, err := s.collect(who, method.Collect.RequestId)
		if err != nil {
			return err
		}
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_Approval{Approval: approval}, EndOfStream: true})
	case *pb.RelayRequest_End:
		if who.machine == nil && who.device == nil {
			return isMachine()
		}
		lease, err := s.end(ctx, who, method.End.RequestId, method.End.AnsweredHere)
		if err != nil {
			return err
		}
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_Lease{Lease: lease}, EndOfStream: true})
	case *pb.RelayRequest_Find:
		if who.machine == nil && who.device == nil {
			return isMachine()
		}
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_Find{Find: s.find(method.Find.Query)}, EndOfStream: true})
	case *pb.RelayRequest_AutomaticLogins:
		if err := isMachine(); err != nil {
			return err
		}
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_SealedLogins{SealedLogins: s.sealedFor(who.machine.MachineId)}, EndOfStream: true})
	case *pb.RelayRequest_Members:
		if who.machine == nil && who.device == nil {
			return isMachine()
		}
		return s.sendDocument(true, send)
	case *pb.RelayRequest_Catalogue:
		if who.machine == nil && who.device == nil {
			return isMachine()
		}
		return s.sendDocument(false, send)
	case *pb.RelayRequest_WatchWork:
		if err := isDevice(); err != nil {
			return err
		}
		return s.watchWork(ctx, who, send)
	case *pb.RelayRequest_GetWork:
		if err := isDevice(); err != nil {
			return err
		}
		work, err := s.work(who.device, method.GetWork.RequestId, nil)
		if err != nil {
			return err
		}
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_Work{Work: work}, EndOfStream: true})
	case *pb.RelayRequest_Answer:
		if err := isDevice(); err != nil {
			return err
		}
		lease, err := s.answer(ctx, who, method.Answer)
		if err != nil {
			return err
		}
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_Lease{Lease: lease}, EndOfStream: true})
	case *pb.RelayRequest_TestRequest:
		if err := isDevice(); err != nil {
			return err
		}
		return s.testRequest(ctx, who, method.TestRequest, send)
	case *pb.RelayRequest_Arrived:
		if err := isDevice(); err != nil {
			return err
		}
		if err := s.arrived(method.Arrived); err != nil {
			return err
		}
		return send(done())
	case *pb.RelayRequest_SetupOffer:
		offer, err := s.setupOffer(who)
		if err != nil {
			return err
		}
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_SetupOffer{SetupOffer: offer}, EndOfStream: true})
	case *pb.RelayRequest_ReportLog:
		if err := isDevice(); err != nil {
			return err
		}
		if err := s.reportLog(method.ReportLog); err != nil {
			return err
		}
		return send(done())
	case *pb.RelayRequest_Logs:
		if who.machine == nil && who.device == nil {
			return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "Only a computer or device of Josh's may read the logs.")
		}
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_Logs{Logs: s.logs(method.Logs)}, EndOfStream: true})
	case *pb.RelayRequest_ReportSelfTest:
		if err := isDevice(); err != nil {
			return err
		}
		if err := s.reportSelfTest(who, method.ReportSelfTest); err != nil {
			return err
		}
		return send(done())
	case *pb.RelayRequest_MembersSince:
		if who.machine == nil && who.device == nil {
			return isMachine()
		}
		chain := &pb.MembersChain{}
		s.Store.read(func(data *saved) {
			history := data.MembersHistory
			if len(history) == 0 && len(data.Members) > 0 {
				history = [][]byte{data.Members}
			}
			for _, raw := range history {
				document, members := &pb.Signed{}, &pb.Members{}
				if unmarshal(raw, document) == nil && unmarshal(document.Payload, members) == nil && members.Revision > method.MembersSince {
					chain.Revisions = append(chain.Revisions, document)
				}
			}
		})
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_MembersChain{MembersChain: chain}, EndOfStream: true})
	case *pb.RelayRequest_SelfTests:
		if who.machine == nil && who.device == nil {
			return isMachine()
		}
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_SelfTests{SelfTests: s.selfTests()}, EndOfStream: true})
	case *pb.RelayRequest_RegisterPush:
		if err := isDevice(); err != nil {
			return err
		}
		if err := s.registerPush(who, method.RegisterPush); err != nil {
			return err
		}
		return send(done())
	case *pb.RelayRequest_PublishMembers:
		if err := s.publishMembers(who, method.PublishMembers); err != nil {
			return err
		}
		return send(done())
	case *pb.RelayRequest_PublishCatalogue:
		if err := isDevice(); err != nil {
			return err
		}
		if err := s.publishCatalogue(method.PublishCatalogue); err != nil {
			return err
		}
		return send(done())
	case *pb.RelayRequest_PublishSealedLogins:
		if err := isDevice(); err != nil {
			return err
		}
		if err := s.publishSealedLogins(method.PublishSealedLogins); err != nil {
			slog.Warn("sealed copies refused", "from", who.device.Label, "count", len(method.PublishSealedLogins.Logins), "error", err)
			return err
		}
		slog.Info("sealed copies taken", "from", who.device.Label, "count", len(method.PublishSealedLogins.Logins),
			"withdrawn", len(method.PublishSealedLogins.WithdrawnLoginIds))
		return send(done())
	case *pb.RelayRequest_SealedLogins:
		if err := isDevice(); err != nil {
			return err
		}
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_SealedLogins{SealedLogins: s.sealedFor(who.device.KeyId)}, EndOfStream: true})
	case *pb.RelayRequest_Join:
		return s.join(ctx, who, method.Join, send)
	case *pb.RelayRequest_RefuseJoin:
		// The Mac refuses the computer that stays on before it has joined
		// itself; the key, not the caller, says who may.
		if err := s.refuseJoin(method.RefuseJoin); err != nil {
			return err
		}
		return send(done())
	case *pb.RelayRequest_PendingJoins:
		// Before anyone has set the relay up, the first device sees the
		// machine it is setting up beside it; a join shows nowhere without a
		// proof that device checks.
		if members, _ := s.Store.documents(); members != nil {
			if err := isDevice(); err != nil {
				return err
			}
		}
		return send(&pb.RelayResponse{Result: &pb.RelayResponse_PendingJoins{PendingJoins: s.pendingJoins()}, EndOfStream: true})
	}
	return fail(pb.ErrorCode_ERROR_CODE_INVALID, "Unknown method. Update the app and the command together.")
}

func (s *Server) sendDocument(members bool, send func(*pb.RelayResponse) error) error {
	var raw []byte
	s.Store.read(func(data *saved) {
		raw = data.Catalogue
		if members {
			raw = data.Members
		}
	})
	if len(raw) == 0 {
		return fail(pb.ErrorCode_ERROR_CODE_NOT_FOUND, "Nothing has been published yet.")
	}
	document := &pb.Signed{}
	if err := unmarshal(raw, document); err != nil {
		return err
	}
	return send(signed(document))
}
