// Written by AI on 2026.11.18 by model claude opus 5.5.
package relay

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"log/slog"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/keyring"
)

// pushAll wakes every registered device for one request: when it arrives,
// and again with its outcome, which replaces the first on the Lock Screen.
func (s *Server) pushAll(ctx context.Context, id string) {
	if s.Push == nil {
		return
	}
	members, _ := s.Store.documents()
	type target struct {
		registration *pb.PushRegistration
		work         *pb.Work
	}
	var targets []target
	var expires int64
	s.Store.read(func(data *saved) {
		r := data.Requests[id]
		if r == nil {
			return
		}
		expires = r.AnswerBy
		for keyID, raw := range data.Pushes {
			d := device(members, keyID)
			registration := &pb.PushRegistration{}
			if d == nil || unmarshal(raw, registration) != nil || (r.ForDevice != "" && r.ForDevice != d.KeyId) || r.ProposedBy == d.KeyId {
				continue
			}
			if work, err := s.work(d, id, data); err == nil {
				targets = append(targets, target{registration, work})
			}
		}
	})
	for _, t := range targets {
		notice, err := keyring.SealNotice(t.work, t.registration.NoticePublicKey, t.registration.DeviceKeyId)
		if err != nil {
			slog.Error("could not seal a push", "device", t.registration.DeviceKeyId, "error", err)
			continue
		}
		payload, _ := json.Marshal(map[string]any{
			"aps": map[string]any{
				"alert":              map[string]string{"title": "Agent Keyring", "body": "A request is waiting."},
				"category":           "REQUEST",
				"interruption-level": "time-sensitive",
				"mutable-content":    1,
				"thread-id":          id,
				"sound":              "default",
			},
			"akr": base64.StdEncoding.EncodeToString(marshal(notice)),
		})
		result, err := s.Push.Send(ctx, t.registration.ApnsToken, t.registration.ApnsTopic, t.registration.ApnsProduction, id, expires, payload)
		if err != nil {
			slog.Warn("push not delivered", "device", t.registration.DeviceKeyId, "status", result.Status, "reason", result.Reason)
			if result.InvalidToken {
				s.Store.update(func(data *saved) error { delete(data.Pushes, t.registration.DeviceKeyId); return nil })
			}
		}
	}
}
