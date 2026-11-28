#!/usr/bin/env bash
# Written by AI on 2026.11.27 by model gemini-4-neon.
#
# Local deterministic quality gate (zero GitHub Actions CI, zero waivers).
#   script/check.sh --fast   pre-commit (staged tree + targeted tests)
#   script/check.sh --full   pre-push / manual full verification

set -euo pipefail

MODE="${1:---full}"
case "$MODE:$#" in
  --fast:1|--full:0|--full:1|--full:2) ;;
  *) echo "usage: $0 [--fast|--full [commit]]" >&2; exit 2 ;;
esac

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
OS="$(uname -s)"
BOUNDARY_CHECK="$ROOT/script/check_boundaries.py"
CHECK_TEMP_DIR=""

cleanup() {
  if [[ -n "$CHECK_TEMP_DIR" && -d "$CHECK_TEMP_DIR" ]]; then
    chmod -R u+w "$CHECK_TEMP_DIR"
    rm -r "$CHECK_TEMP_DIR"
  fi
}
trap cleanup EXIT

make_temp_dir() {
  CHECK_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-keyring-check.XXXXXX")"
}

clear_git_environment() {
  local git_var
  # Hooks inherit Git's repository environment. Child tools must see the exported tree.
  for git_var in $(git rev-parse --local-env-vars); do
    unset "$git_var"
  done
}

enter_snapshot() {
  ROOT="$CHECK_TEMP_DIR/tree"
  cd "$ROOT"
}

run_tool() {
  local tool="$1"
  shift
  if command -v "$tool" >/dev/null 2>&1; then
    "$tool" "$@"
  elif command -v nix >/dev/null 2>&1; then
    nix develop --command "$tool" "$@"
  else
    echo "error: '$tool' not found in PATH and 'nix' is unavailable. Run inside 'nix develop'." >&2
    exit 1
  fi
}

run_xcode_tool() {
  local tool="$1"
  shift
  local clean_path="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
  for extra in /opt/homebrew/bin "${HOME:-}/.nix-profile/bin" /run/current-system/sw/bin /nix/var/nix/profiles/default/bin; do
    [[ -d "$extra" ]] && clean_path="$clean_path:$extra"
  done
  env -i \
    HOME="${HOME:-}" \
    USER="${USER:-}" \
    LOGNAME="${LOGNAME:-}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    LANG="${LANG:-en_US.UTF-8}" \
    PATH="$clean_path" \
    "/usr/bin/$tool" "$@"
}

is_prod_swift_for_lint() {
  local f="$1"
  [[ "$f" == *.swift ]] || return 1
  [[ "$f" != *.pb.swift ]] || return 1
  [[ "$f" != AgentKeyringPackage/Sources/AgentKeyringProtocol/agentkeyring/* ]] || return 1
  [[ "$f" != AgentKeyringPackage/Tests/* ]] || return 1
  [[ "$f" != AgentKeyringPackage/Tools/* ]] || return 1
  return 0
}

run_fast() {
  git diff --cached --check
  make_temp_dir
  # Treat a rename as a deletion and an addition so both packages are checked.
  git diff --cached --no-renames --name-only -z --diff-filter=ACMRD > "$CHECK_TEMP_DIR/paths"
  mkdir "$CHECK_TEMP_DIR/tree"
  git checkout-index --all --ignore-skip-worktree-bits --prefix="$CHECK_TEMP_DIR/tree/"
  clear_git_environment
  enter_snapshot
  # The copy tests use Git to list Swift sources.
  git init --quiet
  git add --force --all
  run_tool python3 "$BOUNDARY_CHECK" --snapshot "$ROOT"

  local go_dirs=()
  local swift_files=()
  local lint_all_go=0
  local run_state_tests=0
  local run_copy_tests=0
  local f dir seen existing

  while IFS= read -r -d '' f; do
    if [[ "$f" == go.mod || "$f" == go.sum || ( "$f" == *.go && ! -f "$f" ) ]]; then
      lint_all_go=1
    elif [[ "$f" == *.go && "$f" != gen/* && "$f" != *.pb.go ]]; then
      dir="$(dirname "$f")"
      [[ "$dir" == "." ]] || dir="./$dir"
      seen=0
      for existing in "${go_dirs[@]+"${go_dirs[@]}"}"; do
        [[ "$existing" == "$dir" ]] && seen=1 && break
      done
      (( seen == 0 )) && go_dirs+=("$dir")
    fi

    if [[ -f "$f" ]] && is_prod_swift_for_lint "$f"; then
      swift_files+=("$ROOT/$f")
    fi
    if [[ "$f" == *.swift && ! -f "$f" ]]; then
      run_state_tests=1
      run_copy_tests=1
    fi

    case "$f" in
      AgentKeyringPackage/Sources/AgentKeyringEngine/Mac/MacFirstRunFlow.swift|\
      AgentKeyringPackage/Sources/AgentKeyringEngine/Mac/MacVaultFileStore.swift|\
      AgentKeyringPackage/Sources/AgentKeyringEngine/Mac/MacHardwareSetupFlow.swift|\
      AgentKeyringPackage/Sources/AgentKeyringEngine/Mac/SelectiveImport*.swift|\
      AgentKeyringPackage/Sources/AgentKeyringEngine/Mac/StagedImport.swift|\
      AgentKeyringPackage/Sources/AgentKeyringApprovalCore/PhoneFirstRun.swift|\
      AgentKeyringPackage/Sources/AgentKeyringApprovalCore/PhoneAddWatch.swift|\
      AgentKeyringPackage/Sources/AgentKeyringApprovalCore/PhoneSheet.swift|\
      AgentKeyringPackage/Sources/AgentKeyringSealing/Watch/WatchOnboardingStep.swift|\
      AgentKeyringPackage/Sources/AgentKeyringSealing/Watch/WatchStateCoordinator.swift|\
      AgentKeyringPackage/Sources/AgentKeyringSealing/Watch/WatchCopiesStore.swift|\
      AgentKeyringPackage/Sources/AgentKeyringSealing/Watch/WatchPersistedState.swift|\
      AgentKeyringPackage/Sources/AgentKeyringSealing/CredentialSealing.swift|\
      AgentKeyringPackage/Sources/AgentKeyringEngine/Cloud/*.swift|\
      AgentKeyringPackage/Tests/AgentKeyringEngineTests/StateSpaceVerificationTests.swift)
        run_state_tests=1
        ;;
    esac

    case "$f" in
      *Copy.swift|AgentKeyringWatch/WatchApp.swift|AgentKeyringPackage/Tests/AgentKeyringCopyTests/*.swift)
        run_copy_tests=1
        ;;
    esac
  done < "$CHECK_TEMP_DIR/paths"

  if (( lint_all_go )); then
    GOFLAGS=-mod=readonly run_tool golangci-lint run ./...
  elif [[ -n "${go_dirs[*]-}" ]]; then
    GOFLAGS=-mod=readonly run_tool golangci-lint run "${go_dirs[@]}"
  fi

  if [[ "$OS" == "Darwin" && -n "${swift_files[*]-}" ]]; then
    run_tool swiftlint lint --config "$ROOT/.swiftlint.yml" --strict "${swift_files[@]}"
  fi

  if [[ "$OS" == "Darwin" ]]; then
    local filter=""
    if (( run_state_tests && run_copy_tests )); then
      filter="StateSpaceVerificationTests|EveryWordOnScreen"
    elif (( run_state_tests )); then
      filter="StateSpaceVerificationTests"
    elif (( run_copy_tests )); then
      filter="EveryWordOnScreen"
    fi
    if [[ -n "$filter" ]]; then
      run_xcode_tool swift test --package-path "$ROOT/AgentKeyringPackage" --filter "$filter"
    fi
  fi
}

run_full() {
  local commit="${1:-}"
  local boundary_args=()
  make_temp_dir
  if [[ -n "$commit" ]]; then
    commit="$(git rev-parse --verify "$commit^{commit}")"
    clear_git_environment
    git clone --quiet --shared --no-checkout "$ROOT" "$CHECK_TEMP_DIR/tree"
    enter_snapshot
    git checkout --quiet --detach "$commit"
    boundary_args=(--snapshot "$ROOT")
  fi

  echo "==> Checking architecture boundaries"
  run_tool python3 "$BOUNDARY_CHECK" "${boundary_args[@]+"${boundary_args[@]}"}"

  echo "==> Running golangci-lint"
  GOFLAGS=-mod=readonly run_tool golangci-lint run ./...

  if [[ "$OS" == "Darwin" ]]; then
    echo "==> Running swiftlint"
    local lint_dirs=()
    local d
    for d in \
      AgentKeyringPackage/Sources \
      AgentKeyring \
      AgentKeyringCredentialProvider \
      AgentKeyringPhone \
      AgentKeyringPhoneCredentialProvider \
      AgentKeyringPhoneNotificationContent \
      AgentKeyringPhoneNotificationService \
      AgentKeyringWatch \
      AgentKeyringWatchNotificationService; do
      [[ -d "$ROOT/$d" ]] && lint_dirs+=("$ROOT/$d")
    done
    run_tool swiftlint lint --config "$ROOT/.swiftlint.yml" --strict "${lint_dirs[@]}"
  fi

  echo "==> Running go test -race ./..."
  # Go's test cache cannot see the Swift sources that the E2E suite builds in a child process.
  GOFLAGS=-mod=readonly run_tool go test -race -count=1 ./...

  if [[ "$OS" == "Darwin" ]]; then
    echo "==> Running swift test"
    run_xcode_tool swift test --package-path "$ROOT/AgentKeyringPackage"

    if [[ ! -x "$ROOT/build/cli/macos/agent-keyring" ]]; then
      echo "==> Building the Go CLI for the macOS app bundle"
      mkdir -p "$ROOT/build/cli/macos"
      GOFLAGS=-mod=readonly CGO_ENABLED=0 run_tool go build -trimpath \
        -o "$ROOT/build/cli/macos/agent-keyring" ./cmd/agent-keyring
    fi

    echo "==> Building macOS app (xcodebuild)"
    build_app AgentKeyring "platform=macOS,arch=$(uname -m)" mac

    echo "==> Building generic iOS app (xcodebuild)"
    build_app AgentKeyringPhone "generic/platform=iOS" ios

    echo "==> Building generic iOS Simulator app (xcodebuild)"
    build_app AgentKeyringPhone "generic/platform=iOS Simulator" ios-simulator
  fi
}

build_app() {
  local app="$1" destination="$2" derived_dir="$3"
  run_xcode_tool xcodebuild -quiet \
    -project "$ROOT/$app.xcodeproj" \
    -scheme "$app" \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$CHECK_TEMP_DIR/$derived_dir" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
}

if [[ "$MODE" == "--fast" ]]; then
  run_fast
else
  run_full "${2:-}"
fi
