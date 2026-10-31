// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package clientstate

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"google.golang.org/protobuf/proto"
)

type Store struct{ Directory string }

func Default() (Store, error) {
	directory := os.Getenv("AGENT_KEYRING_STATE_DIR")
	if directory == "" {
		directory = os.Getenv("XDG_STATE_HOME")
		if directory == "" {
			home, e := os.UserHomeDir()
			if e != nil {
				return Store{}, e
			}
			directory = filepath.Join(home, ".local/state")
		}
		directory = filepath.Join(directory, "agent-keyring")
	}
	directory, err := filepath.Abs(directory)
	return Store{directory}, err
}
func privateInfo(info os.FileInfo) error {
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || owner.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0077 != 0 || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("Agent Keyring's local state must belong to you and be private to your user.")
	}
	return nil
}
func (s Store) lock(ctx context.Context) (func(), error) {
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
	fd, err := syscall.Open(filepath.Join(s.Directory, "state.lock"), syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), "state.lock")
	info, err = file.Stat()
	if err == nil {
		err = privateInfo(info)
	}
	if err != nil {
		file.Close()
		return nil, err
	}
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	for {
		err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return func() { syscall.Flock(fd, syscall.LOCK_UN); file.Close() }, nil
		}
		if err != syscall.EWOULDBLOCK {
			file.Close()
			return nil, err
		}
		select {
		case <-ctx.Done():
			file.Close()
			return nil, ctx.Err()
		case <-deadline.C:
			file.Close()
			return nil, errors.New("Another Agent Keyring command is still saving its state. Try again.")
		case <-time.After(25 * time.Millisecond):
		}
	}
}
func (s Store) read(name string, message proto.Message) error {
	fd, err := syscall.Open(filepath.Join(s.Directory, name), syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(fd), name)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if err = privateInfo(info); err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() > 16<<20 {
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
func (s Store) write(name string, message proto.Message) error {
	data, err := proto.Marshal(message)
	if err != nil {
		return err
	}
	defer clear(data)
	file, err := os.CreateTemp(s.Directory, ".saving-")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer func() { file.Close(); os.Remove(temporary) }()
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
			err = directory.Sync()
			directory.Close()
		} else {
			err = e
		}
	}
	return err
}
func (s Store) Update(ctx context.Context, change func(*State) error) error {
	unlock, err := s.lock(ctx)
	if err != nil {
		return err
	}
	defer unlock()
	state := new(State)
	if err = s.read("state.pb", state); err != nil && !os.IsNotExist(err) {
		return err
	}
	if err = change(state); err != nil {
		return err
	}
	return s.write("state.pb", state)
}
func (s Store) Load(ctx context.Context) (*State, error) {
	unlock, err := s.lock(ctx)
	if err != nil {
		return nil, err
	}
	defer unlock()
	state := new(State)
	err = s.read("state.pb", state)
	if os.IsNotExist(err) {
		return state, nil
	}
	return state, err
}
func (s Store) Keys(ctx context.Context, create func() (*PrivateKeys, error)) (*PrivateKeys, error) {
	unlock, err := s.lock(ctx)
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
		return nil, errors.New("This machine is not enrolled. Run 'agent-keyring enrol --name NAME --relay HOST:PORT'.")
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
