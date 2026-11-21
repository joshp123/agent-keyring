// Written by AI on 2026.11.21 by model Gemini 4 Neon.
package remote

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/door"
)

// HoldState is the explicit two-state model of the single-instance detached door
// holder (`agent-keyring hold`), derived strictly from state.pb with zero hidden
// in-memory request state:
//   - holding: at least one request in state.pb is WAITING (before answer_by) or
//     APPROVED (before not_after). Port 17446 stays open for answers, arrivals,
//     and immediate Stop from iPhone/Watch even if the agent exits or Mac sleeps.
//   - idle: zero pending requests and zero active leases for holdGrace; close the
//     door cleanly, release hold.lock, and exit.
type HoldState string

const (
	HoldStateHolding HoldState = "holding"
	HoldStateIdle    HoldState = "idle"
)

const (
	defaultHoldPoll  = time.Second
	defaultHoldGrace = 5 * time.Second
)

// hasLiveWork reports whether state.pb holds any pending request or active
// approval whose window has not yet expired at `now`.
func hasLiveWork(state *clientstate.State, now int64) bool {
	if state == nil {
		return false
	}
	for _, saved := range state.Requests {
		if saved == nil || saved.Lease == nil {
			continue
		}
		switch saved.Lease.State {
		case pb.LeaseState_LEASE_STATE_WAITING:
			if now < saved.Lease.AnswerByUnixSeconds {
				return true
			}
		case pb.LeaseState_LEASE_STATE_APPROVED:
			if now < saved.Lease.NotAfterUnixSeconds {
				return true
			}
		}
	}
	return false
}

// acquireHoldLock acquires an exclusive non-blocking flock on <stateDir>/hold.lock.
// Returns (unlock, true, nil) if acquired, (nil, false, nil) if another holder already owns it.
func acquireHoldLock(dir string) (func(), bool, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, false, err
	}
	file, err := os.OpenFile(filepath.Join(dir, "hold.lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, false, err
	}
	fd := int(file.Fd())
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		if err == syscall.EWOULDBLOCK || err == syscall.EAGAIN {
			return nil, false, nil
		}
		return nil, false, err
	}
	return func() {
		_ = syscall.Flock(fd, syscall.LOCK_UN)
		_ = file.Close()
	}, true, nil
}

// holderRunning reports whether a live `agent-keyring hold` process currently holds hold.lock.
func holderRunning(dir string) bool {
	unlock, ok, err := acquireHoldLock(dir)
	if err != nil {
		return false
	}
	if ok {
		unlock()
		return false
	}
	return true
}

// ensureHold makes sure a single detached `agent-keyring hold` process is running
// for this computer's state directory so answers (10 min) and Stop (up to 30 min)
// still reach this computer if the calling agent exits or times out.
// Stdio is detached to /dev/null with Setsid so parent tool runners never hang on EOF.
func (c *Client) ensureHold() {
	if os.Getenv("AGENT_KEYRING_NO_DETACH") == "1" || door.Testing() {
		return
	}
	if holderRunning(c.Store.Directory) {
		return
	}
	exe, err := os.Executable()
	if err != nil {
		c.log("hold spawn-skipped reason=" + err.Error())
		return
	}
	devNull, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return
	}
	defer devNull.Close()
	cmd := exec.Command(exe, "hold")
	cmd.Stdin = devNull
	cmd.Stdout = devNull
	cmd.Stderr = devNull
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		c.log("hold spawn-failed reason=" + err.Error())
		return
	}
	_ = cmd.Process.Release()
}

// HoldUntilIdle runs the single-instance door holder until state.pb has neither
// pending requests nor active approvals for grace (default 5 seconds), then exits.
// If another `agent-keyring hold` already holds hold.lock, returns nil at once.
func (c *Client) HoldUntilIdle(ctx context.Context) error {
	return c.holdUntilIdle(ctx, defaultHoldPoll, defaultHoldGrace)
}

func (c *Client) holdUntilIdle(ctx context.Context, poll, grace time.Duration) error {
	unlock, acquired, err := acquireHoldLock(c.Store.Directory)
	if err != nil || !acquired {
		return err
	}
	defer unlock()

	c.log("hold started")
	defer c.log("hold exited")

	for {
		stop := door.Hold(ctx, c.Certificate, c.doorHandler(), func(address string) {
			c.log("hold door-open address=" + address)
		})
		var idleSince time.Time
		ticker := time.NewTicker(poll)
	loop:
		for {
			if err := c.settleDue(ctx); err != nil && ctx.Err() == nil {
				c.log("hold settle-error reason=" + err.Error())
			}
			state, loadErr := c.Store.Load(ctx)
			now := time.Now().Unix()
			if loadErr == nil && hasLiveWork(state, now) {
				idleSince = time.Time{}
			} else {
				if idleSince.IsZero() {
					idleSince = time.Now()
				} else if time.Since(idleSince) >= grace {
					break loop
				}
			}
			select {
			case <-ctx.Done():
				ticker.Stop()
				stop()
				return ctx.Err()
			case <-ticker.C:
			}
		}
		ticker.Stop()
		stop()

		// Re-check under state.pb right after closing the door so a request saved
		// during the final millisecond of shutdown is never dropped.
		if ctx.Err() != nil {
			return ctx.Err()
		}
		state, loadErr := c.Store.Load(ctx)
		if loadErr == nil && hasLiveWork(state, time.Now().Unix()) {
			continue
		}
		return nil
	}
}

// settleDue advances any expired waiting or approved requests in state.pb so
// unanswered requests send their clear pushes even after the agent has exited.
func (c *Client) settleDue(ctx context.Context) error {
	state, err := c.Store.Load(ctx)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	now := time.Now().Unix()
	for _, saved := range state.Requests {
		if saved == nil || saved.Lease == nil {
			continue
		}
		lease := saved.Lease
		if (lease.State == pb.LeaseState_LEASE_STATE_WAITING && now >= lease.AnswerByUnixSeconds) ||
			(lease.State == pb.LeaseState_LEASE_STATE_APPROVED && now >= lease.NotAfterUnixSeconds) {
			_, _ = c.settle(ctx, saved.LeaseId)
		}
	}
	return nil
}
