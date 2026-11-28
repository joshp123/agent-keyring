// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package clientstate

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"syscall"
	"time"

	"google.golang.org/protobuf/proto"
)

const MaxStateBytes = 16 << 20

type ClientStateStore struct{ Directory string }

func DefaultClientStateStore() (ClientStateStore, error) {
	directory := os.Getenv("AGENT_KEYRING_STATE_DIR")
	if directory == "" {
		directory = os.Getenv("XDG_STATE_HOME")
		if directory == "" {
			home, e := os.UserHomeDir()
			if e != nil {
				return ClientStateStore{}, e
			}
			directory = filepath.Join(home, ".local/state")
		}
		directory = filepath.Join(directory, "agent-keyring")
	}
	directory, err := filepath.Abs(directory)
	return ClientStateStore{directory}, err
}
func privateInfo(info os.FileInfo) error {
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || owner.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0077 != 0 || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("Agent Keyring's local state must belong to you and be private to your user.")
	}
	return nil
}
func (s ClientStateStore) lockClientStateFile(ctx context.Context) (func(), error) {
	if err := os.MkdirAll(s.Directory, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(s.Directory)
	if err != nil {
		return nil, err
	}
	if err = privateInfo(info); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(s.Directory, "state.lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	fd := int(file.Fd())
	info, err = file.Stat()
	if err == nil {
		err = privateInfo(info)
	}
	if err != nil {
		_ = file.Close()
		return nil, err
	}
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	for {
		err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			// Closing this descriptor releases the flock.
			return func() { _ = file.Close() }, nil
		}
		if errors.Is(err, syscall.EINTR) {
			continue
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			_ = file.Close()
			return nil, err
		}
		select {
		case <-ctx.Done():
			_ = file.Close()
			return nil, ctx.Err()
		case <-deadline.C:
			_ = file.Close()
			return nil, errors.New("Another Agent Keyring command is still saving its state. Try again.")
		case <-time.After(25 * time.Millisecond):
		}
	}
}
func (s ClientStateStore) readClientStateMessage(name string, message proto.Message) error {
	file, err := os.OpenFile(filepath.Join(s.Directory, name), os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	defer func() { _ = file.Close() }()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if err = privateInfo(info); err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() > MaxStateBytes {
		return errors.New("Agent Keyring's local state file is invalid.")
	}
	data := make([]byte, info.Size())
	defer clear(data)
	if _, err = file.ReadAt(data, 0); err != nil {
		return err
	}
	if err = proto.Unmarshal(data, message); err != nil {
		return errors.New("Cannot read Agent Keyring's saved state.")
	}
	return nil
}
func (s ClientStateStore) writeClientStateMessage(name string, message proto.Message) error {
	data, err := proto.Marshal(message)
	if err != nil {
		return err
	}
	defer clear(data)
	if len(data) > MaxStateBytes {
		return fmt.Errorf("Agent Keyring's local state file %s exceeds the %d MiB write limit.", name, MaxStateBytes>>20)
	}
	file, err := os.CreateTemp(s.Directory, ".saving-")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer func() { _ = file.Close(); _ = os.Remove(temporary) }()
	if err = file.Chmod(0600); err == nil {
		_, err = file.Write(data)
	}
	if err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(temporary, filepath.Join(s.Directory, name))
	}
	if err == nil {
		directory, e := os.Open(s.Directory)
		if e == nil {
			err = errors.Join(directory.Sync(), directory.Close())
		} else {
			err = e
		}
	}
	return err
}
func (s ClientStateStore) UpdateClientState(ctx context.Context, change func(*State) error) error {
	unlock, err := s.lockClientStateFile(ctx)
	if err != nil {
		return err
	}
	defer unlock()
	state := new(State)
	if err = s.readClientStateMessage("state.pb", state); err != nil && !os.IsNotExist(err) {
		return err
	}
	pruneOperations(state)
	pruneApprovals(state)
	if err = change(state); err != nil {
		return err
	}
	return s.writeClientStateMessage("state.pb", state)
}

// pruneApprovals deletes each saved approval whose window has ended, and
// forgets requests a day after they were asked, as the devices' history does.
func pruneApprovals(state *State) {
	now := time.Now().Unix()
	for _, request := range state.Requests {
		if notAfter := request.GetLease().GetNotAfterUnixSeconds(); len(request.Approval) > 0 && notAfter > 0 && now >= notAfter {
			request.Approval = nil
		}
	}
	state.Requests = slices.DeleteFunc(state.Requests, func(request *ExpectedRequest) bool {
		return now-request.GetLease().GetAnswerByUnixSeconds() > 86400 && now >= request.GetLease().GetNotAfterUnixSeconds()
	})
}
func (s ClientStateStore) LoadClientState(ctx context.Context) (*State, error) {
	unlock, err := s.lockClientStateFile(ctx)
	if err != nil {
		return nil, err
	}
	defer unlock()
	state := new(State)
	err = s.readClientStateMessage("state.pb", state)
	if os.IsNotExist(err) {
		return state, nil
	}
	return state, err
}
func (s ClientStateStore) LoadOrCreateClientKeys(ctx context.Context, create func() (*PrivateKeys, error)) (*PrivateKeys, error) {
	unlock, err := s.lockClientStateFile(ctx)
	if err != nil {
		return nil, err
	}
	defer unlock()
	data, err := s.loadPrivateKeys()
	if err == nil {
		defer clear(data)
		keys := new(PrivateKeys)
		if e := proto.Unmarshal(data, keys); e != nil {
			return nil, errors.New("Cannot read this machine's Agent Keyring keys.")
		}
		return keys, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("Cannot load this machine's Agent Keyring keys: %w", err)
	}
	if create == nil {
		return nil, errors.New("This machine is not enrolled. Run 'agent-keyring enrol --name NAME --code CODE' with a code from Add Another Computer on the Mac or iPhone.")
	}
	keys, err := create()
	if err != nil {
		return nil, err
	}
	data, err = proto.Marshal(keys)
	if err != nil {
		return nil, err
	}
	defer clear(data)
	if err = s.savePrivateKeys(data); err != nil {
		return nil, err
	}
	return keys, nil
}
