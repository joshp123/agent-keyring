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

// pushAll wakes every registered device for one request. Only a request that
// newly waits for Josh is a notification he sees and hears; every outcome
// (answered, stopped, released, no answer) is a silent push, so the devices
// take the notification away and nothing piles up.
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
	var waiting bool
	s.Store.read(func(data *saved) {
		r := data.Requests[id]
		if r == nil || r.Automatic { // An Automatic use is shown in the apps, never pushed.
			return
		}
		expires, waiting = r.AnswerBy, r.State == pb.LeaseState_LEASE_STATE_WAITING
		for keyID, raw := range data.Pushes {
			d := device(members, keyID)
			registration := &pb.PushRegistration{}
			if d == nil || unmarshal(raw, registration) != nil || (r.ForDevice != "" && r.ForDevice != d.KeyId) {
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
		payload := pushPayload(id, notice, waiting)
		result, err := s.Push.Send(ctx, t.registration.ApnsToken, t.registration.ApnsTopic, t.registration.ApnsProduction, id, expires, payload, waiting)
		if err == nil {
			slog.Info("push accepted by Apple", "id", id, "device", t.registration.DeviceKeyId, "visible", waiting, "topic", t.registration.ApnsTopic, "production", t.registration.ApnsProduction)
		} else {
			slog.Warn("push not delivered", "device", t.registration.DeviceKeyId, "status", result.Status, "reason", result.Reason)
			if result.InvalidToken {
				s.Store.update(func(data *saved) error { delete(data.Pushes, t.registration.DeviceKeyId); return nil })
			}
		}
	}
}

// pushPayload is what Apple carries: nothing readable about the request.
// Apple refuses one over 4096 bytes. `waiting`: a new request, shown and
// sounded; otherwise a silent push with the outcome for the app to act on.
func pushPayload(id string, notice *pb.Notice, waiting bool) []byte {
	aps := map[string]any{"content-available": 1, "thread-id": id}
	if waiting {
		aps = map[string]any{
			"alert":              map[string]string{"title": "Agent Keyring", "body": "A request is waiting."},
			"category":           "REQUEST",
			"interruption-level": "time-sensitive",
			"mutable-content":    1,
			"thread-id":          id,
			"sound":              "default",
		}
	}
	payload, _ := json.Marshal(map[string]any{"aps": aps, "id": id, "akr": base64.StdEncoding.EncodeToString(marshal(notice))})
	return payload
}
