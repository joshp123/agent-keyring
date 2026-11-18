#!/usr/bin/env bash
# Written by AI on 2026.11.18 by model claude opus 5.5.
#
# The end-to-end steps of e2e/e2e_test.go, across real machines: a test relay
# on one machine's Tailscale address, the command on two machines, and the
# stand-in device (software keys for the iPhone's chip) on this one. Made-up
# logins only. Everything it starts is stopped, and its folders removed, at
# the end. Never use the port of a relay in daily use.
#
#   developer/e2e/run.sh RELAY_HOST RELAY_TAILSCALE_IP PORT MACHINE_A MACHINE_B
#
# Hosts are SSH names; machine B may be the relay host.
set -euo pipefail
relay_host=$1 relay_ip=$2 port=$3 machine_a=$4 machine_b=$5
here=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d /tmp/akr-e2e.XXXXXX)
remote=/tmp/akr-e2e-$$
address=$relay_ip:$port
failures=0

platform() { ssh -o BatchMode=yes "$1" 'echo "$(uname -s | tr A-Z a-z)/$(uname -m | sed s/x86_64/amd64/)"'; }
build() { # build OUTPUT PACKAGE GOOS/GOARCH
	(cd "$here" && CGO_ENABLED=0 GOOS=${3%/*} GOARCH=${3#*/} go build -trimpath -o "$1" "$2")
}
on() { ssh -o BatchMode=yes "$@"; }
check() { # check NAME CONDITION...
	if "${@:2}"; then echo "PASS  $1"; else echo "FAIL  $1"; failures=$((failures + 1)); fi
}
contains() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

cleanup() {
	on "$relay_host" "pkill -f '$remote/relay' || true; rm -rf '$remote'" || true
	for host in "$machine_a" "$machine_b"; do on "$host" "rm -rf '$remote'" || true; done
	rm -rf "$work"
}
trap cleanup EXIT

echo "Building for each machine."
for host in "$relay_host" "$machine_a" "$machine_b"; do
	target=$(platform "$host")
	mkdir -p "$work/$host"
	build "$work/$host/relay" ./cmd/agent-keyring-relay "$target"
	build "$work/$host/agent-keyring" ./cmd/agent-keyring "$target"
	on "$host" "mkdir -m 700 -p '$remote/state'"
	scp -q "$work/$host/relay" "$work/$host/agent-keyring" "$host:$remote/"
done
(cd "$here" && go build -o "$work/test-device" ./developer/test-device)

echo "Starting the test relay on $relay_host at $address."
on "$relay_host" "nohup '$remote/relay' --listen '$address' --state '$remote/relay-state' --answer-within 20s > '$remote/relay.log' 2>&1 &"
sleep 2
on "$relay_host" "cat '$remote/relay.log'"

device() { "$work/test-device" "$1" --state "$work/device" "${@:2}"; }
agent() { # agent HOST ARGS...: the command as an agent on that machine runs it
	local host=$1; shift
	on "$host" "AGENT_KEYRING_STATE_DIR='$remote/state' '$remote/agent-keyring' $(printf '%q ' "$@")"
}

device init --relay "$address"

echo "Both machines ask to join; the device approves them."
agent "$machine_a" enrol --name "Machine A" --invite "$(device invite)" >"$work/join-a" 2>&1 &
join_a=$!
agent "$machine_b" enrol --name "Machine B" --invite "$(device invite)" >"$work/join-b" 2>&1 &
join_b=$!
for _ in $(seq 1 40); do
	device approve-joins >/dev/null 2>&1 || true
	if ! kill -0 $join_a 2>/dev/null && ! kill -0 $join_b 2>/dev/null; then break; fi
	sleep 0.5
done
wait $join_a || true
wait $join_b || true
check "$machine_a joined" contains "$(cat "$work/join-a")" "Joined"
check "$machine_b joined" contains "$(cat "$work/join-b")" "Joined"

echo "1. Approved: a program on $machine_a gets the password through a pipe."
agent "$machine_a" lease login-ask --task invoice --reason "You asked me to download October's invoice." >"$work/lease-1" 2>"$work/lease-1.err" &
asking=$!
device answer --approve
wait $asking || true
lease=$(cat "$work/lease-1")
on "$machine_a" "AGENT_KEYRING_STATE_DIR='$remote/state' '$remote/agent-keyring' read '$lease' --field password | cat > '$remote/received'" 2>&1 || true
check "the program received the password" test "$(on "$machine_a" "cat '$remote/received'")" = "example-ask-password"

echo "2. Nobody answers, on $machine_a."
agent "$machine_a" lease login-ask --task invoice --reason "Second try." >/dev/null 2>"$work/lease-2.err" &
asking=$!
device answer --ignore
wait $asking || true
check "the agent is told there was no answer" contains "$(cat "$work/lease-2.err")" "No answer. Nobody answered within 10 minutes. This is not a refusal."

echo "3. Denied with words, on $machine_a."
agent "$machine_a" lease login-ask --task invoice --reason "Third try." >/dev/null 2>"$work/lease-3.err" &
asking=$!
device answer --deny "The invoice is in my email. Use that."
wait $asking || true
check "the agent gets the words" contains "$(cat "$work/lease-3.err")" "denied. Reply: The invoice is in my email. Use that."
again=$(agent "$machine_a" lease login-ask --task invoice --reason "Fourth try." 2>&1 || true)
check "the login is held off for 30 minutes" contains "$again" "Josh denied this login for this machine"

echo "4. Denied with no words, on $machine_b."
agent "$machine_b" lease login-ask --task invoice --reason "From machine B." >/dev/null 2>"$work/lease-4.err" &
asking=$!
device answer --deny-plain
wait $asking || true
check "the agent is told it was denied" contains "$(cat "$work/lease-4.err")" "This lease is denied."
check "with no words" lacks "$(cat "$work/lease-4.err")" "Reply:"

echo "5. Automatic, with no question, on $machine_b."
lease=$(agent "$machine_b" lease login-automatic --task report --reason "Nightly report." 2>/dev/null)
value=$(agent "$machine_b" read "$lease" --field password 2>/dev/null)
check "the machine opened its own copy" test "$value" = "example-automatic-password"

echo
echo "Relay log:"
on "$relay_host" "cat '$remote/relay.log'"
echo
if [ $failures -eq 0 ]; then echo "All steps passed."; else echo "$failures step(s) failed."; exit 1; fi
