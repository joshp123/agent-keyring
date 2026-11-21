// Written by AI on 2026.11.21 by model Gemini 4 Neon.
package remote

import (
	"context"
	"sync"
	"testing"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/clientstate"
)

func TestHasLiveWorkCoversPendingAndActiveLeases(t *testing.T) {
	now := int64(1000)
	if hasLiveWork(nil, now) {
		t.Fatal("nil state should not have live work")
	}
	if hasLiveWork(&clientstate.State{}, now) {
		t.Fatal("empty state should not have live work")
	}

	pending := &clientstate.State{Requests: []*clientstate.ExpectedRequest{{
		LeaseId: "req-1",
		Lease:   &pb.Lease{State: pb.LeaseState_LEASE_STATE_WAITING, AnswerByUnixSeconds: now + 60},
	}}}
	if !hasLiveWork(pending, now) {
		t.Fatal("unexpired pending request must count as live work")
	}
	if hasLiveWork(pending, now+60) {
		t.Fatal("expired pending request must not count as live work")
	}

	active := &clientstate.State{Requests: []*clientstate.ExpectedRequest{{
		LeaseId: "req-2",
		Lease:   &pb.Lease{State: pb.LeaseState_LEASE_STATE_APPROVED, NotAfterUnixSeconds: now + 1800},
	}}}
	if !hasLiveWork(active, now) {
		t.Fatal("active 30-minute approval must count as live work so Stop works without MacBook")
	}
	if hasLiveWork(active, now+1800) {
		t.Fatal("expired approval must not count as live work")
	}

	denied := &clientstate.State{Requests: []*clientstate.ExpectedRequest{{
		LeaseId: "req-3",
		Lease:   &pb.Lease{State: pb.LeaseState_LEASE_STATE_DENIED},
	}}}
	if hasLiveWork(denied, now) {
		t.Fatal("denied request must not count as live work")
	}
}

func TestHoldLockSingleInstanceUnderConcurrency(t *testing.T) {
	dir := t.TempDir()
	const workers = 12
	var wg sync.WaitGroup
	winners := make(chan func(), workers)

	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			unlock, ok, err := acquireHoldLock(dir)
			if err != nil {
				t.Errorf("acquireHoldLock error: %v", err)
				return
			}
			if ok {
				winners <- unlock
			}
		}()
	}
	wg.Wait()
	close(winners)

	var unlocks []func()
	for u := range winners {
		unlocks = append(unlocks, u)
	}
	if len(unlocks) != 1 {
		t.Fatalf("expected exactly 1 hold.lock winner among %d concurrent callers, got %d", workers, len(unlocks))
	}
	if !holderRunning(dir) {
		t.Fatal("holderRunning should report true while lock is held")
	}
	unlocks[0]()
	if holderRunning(dir) {
		t.Fatal("holderRunning should report false after lock is released")
	}
}

func TestHoldUntilIdleExitsCleanlyWhenNoLiveWork(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("AGENT_KEYRING_TEST_DOOR", "127.0.0.1:0")
	client := &Client{Store: clientstate.Store{Directory: dir}, label: "test"}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	start := time.Now()
	if err := client.holdUntilIdle(ctx, 20*time.Millisecond, 60*time.Millisecond); err != nil {
		t.Fatalf("holdUntilIdle returned error: %v", err)
	}
	if elapsed := time.Since(start); elapsed < 50*time.Millisecond {
		t.Fatalf("holdUntilIdle exited before grace window: %v", elapsed)
	}
	if holderRunning(dir) {
		t.Fatal("hold.lock must be released after holdUntilIdle exits")
	}
}
