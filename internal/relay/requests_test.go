// Written by AI on 2026.11.19 by model claude opus 5.5.
package relay

import (
	"context"
	"testing"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
)

// Another computer that claims to have answered its own request as the Mac
// would must not be shown as approved on the iPhone; only the Mac may.
func TestOnlyTheMacAnswersItsOwnRequest(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: store}
	linux := &pb.Machine{MachineId: "linux", Label: "Linux server"}
	mac := &pb.Machine{MachineId: "mac", Label: "MacBook Pro"}
	macDevice := &pb.Device{KeyId: "mac-device", Kind: pb.DeviceKind_DEVICE_KIND_MAC, Label: "MacBook Pro"}
	store.update(func(data *saved) error {
		data.Requests["from-linux"] = &request{MachineID: "linux", State: pb.LeaseState_LEASE_STATE_WAITING}
		data.Requests["from-mac"] = &request{MachineID: "mac", State: pb.LeaseState_LEASE_STATE_WAITING}
		return nil
	})
	lease, err := s.end(context.Background(), caller{machine: linux}, "from-linux", "approved")
	if err != nil || lease.State != pb.LeaseState_LEASE_STATE_CANCELLED || lease.AnsweredBy != "" {
		t.Fatalf("another computer marked its own request approved: %v %v", lease, err)
	}
	lease, err = s.end(context.Background(), caller{machine: mac, device: macDevice}, "from-mac", "approved")
	if err != nil || lease.State != pb.LeaseState_LEASE_STATE_APPROVED || lease.AnsweredBy != "MacBook Pro" {
		t.Fatalf("the Mac's own answer was not recorded: %v %v", lease, err)
	}
}
