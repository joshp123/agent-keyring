#!/usr/bin/env python3
"""Deterministic local architecture and hygiene boundary checker (zero waivers)."""
# Written by AI on 2026.11.27 by model gemini-4-neon.

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

PROD_LINE_CAP = 600
TEST_LINE_CAP = 700

PROD_SWIFT_PREFIXES = (
    "AgentKeyringPackage/Sources/",
    "AgentKeyringPackage/Tools/",
    "AgentKeyring/",
    "AgentKeyringCredentialProvider/",
    "AgentKeyringPhone",
    "AgentKeyringWatch",
)
PROD_GO_PREFIXES = ("cmd/", "internal/", "developer/", "script/")
TEST_PREFIXES = ("AgentKeyringPackage/Tests/", "e2e/")

APPROVAL_UI_PREFIX = "AgentKeyringPackage/Sources/AgentKeyringApprovalUI/"
WATCH_UI_PREFIX = "AgentKeyringPackage/Sources/AgentKeyringWatchUI/"
APPROVAL_UI_FORBIDDEN_IMPORTS = frozenset({
    "CloudKit",
    "LocalAuthentication",
    "LocalAuthenticationEmbeddedUI",
    "WatchConnectivity",
    "Security",
    "AgentKeyringProtocol",
    "AgentKeyringSealing",
    "AgentKeyringEngine",
    "AgentKeyringScreenBackends",
})
# Apple Watch's pages read the Watch's request and setup step, which live in AgentKeyringSealing.
WATCH_UI_FORBIDDEN_IMPORTS = APPROVAL_UI_FORBIDDEN_IMPORTS - {"AgentKeyringSealing"}

# The Watch app and the notification extensions link only AgentKeyringSealing and what it needs.
SLIM_APP_PREFIXES = (
    "AgentKeyringPhoneNotificationService/",
    "AgentKeyringWatch/",
    "AgentKeyringWatchNotificationService/",
)
SLIM_APP_FORBIDDEN_IMPORTS = frozenset({
    "CloudKit",
    "AgentKeyringApprovalUI",
    "AgentKeyringEngine",
    "AgentKeyringScreenBackends",
    "AgentKeyringSiteIcons",
})

DOMAIN_TARGETS = (
    "AgentKeyringApprovalCore",
    "AgentKeyringSealing",
    "AgentKeyringEngine",
)
DOMAIN_FORBIDDEN_IMPORTS = frozenset({
    "SwiftUI",
    "AppKit",
    "UIKit",
    "AgentKeyringApprovalUI",
    "AgentKeyringWatchUI",
    "AgentKeyringDesign",
})

USERDEFAULTS_FORBIDDEN_PREFIXES = (
    "AgentKeyringPackage/Sources/AgentKeyringSealing/",
    "AgentKeyringPackage/Sources/AgentKeyringEngine/Cloud/",
    "AgentKeyringPackage/Sources/AgentKeyringEngine/Phone/",
)

# Exact external-boundary allowlist for JSON/plist decoders (not app persistence):
JSON_PLIST_ALLOWLIST = frozenset({
    # Daily HTTP JSON version check against push.opentrawl.sh/v1/version.
    "AgentKeyringPackage/Sources/AgentKeyringApprovalCore/VersionCheck.swift",
    # Reads Apple's embedded.mobileprovision signed XML plist for aps-environment.
    "AgentKeyringPackage/Sources/AgentKeyringSealing/PushEnvironment.swift",
    # Reads /Applications/AgentKeyring.app/Contents/Info.plist for CFBundleIdentifier.
    "AgentKeyringPackage/Sources/AgentKeyringEngine/Mac/AgentBridge.swift",
})

STATE_MACHINE_FILES = frozenset({
    "MacFirstRunFlow.swift",
    "MacHardwareSetupFlow.swift",
    "SelectiveImportSession.swift",
    "PhoneFirstRun.swift",
    "PhoneAddWatch.swift",
    "PhoneSheet.swift",
    "WatchOnboardingStep.swift",
    "WatchStateCoordinator.swift",
    "CloudReplicaHost.swift",
    "CloudReplicaSyncCoordinator.swift",
    "CloudReplicaPush.swift",
    "CloudDeviceRemoval.swift",
})

IMPORT_RE = re.compile(
    r"^\s*(?:@(?:_exported|testable|preconcurrency|implementationOnly)\s+)*"
    r"(?:(?:public|internal|package|private|fileprivate)\s+)?"
    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"([A-Za-z_]\w*)"
)
JSON_PLIST_RE = re.compile(
    r"\b(JSONEncoder|JSONDecoder|PropertyListEncoder|PropertyListDecoder|PropertyListSerialization)\b"
)
USERDEFAULTS_RE = re.compile(r"\bUserDefaults\b")
DEFAULT_CASE_RE = re.compile(r"^\s*default\s*:")
BACKEND_PROTO_RE = re.compile(r"\bprotocol\s+(\w+Backend)\b")
BACKEND_EXT_RE = re.compile(
    r"^\s*(?:(?:public|internal|package|private|fileprivate)\s+)?extension\s+(\w+Backend)\b"
)
LINT_WAIVER_RE = re.compile(r"\bswiftlint:disable\b|//[^\S\n]*nolint\b|/\*\s*nolint\b")
HYGIENE_TOKENS = ("/Users/" + "josh", "tail" + "b7ad2a")


SWIFT_TOKEN_RE = re.compile(
    r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/'
)
HYGIENE_RE = re.compile("|".join(re.escape(t) for t in HYGIENE_TOKENS))
BINARY_SUFFIXES = frozenset({
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".icns",
    ".ttf", ".otf", ".woff", ".woff2", ".bin", ".zlib", ".zip", ".pdf",
})


def _strip_nested_block_comments(source: str) -> str:
    out: list[str] = []
    i, n, depth = 0, len(source), 0
    while i < n:
        nxt = source[i : i + 2]
        if nxt == "/*":
            depth += 1
            i += 2
        elif nxt == "*/" and depth:
            depth -= 1
            i += 2
        elif depth:
            out.append("\n" if source[i] == "\n" else " ")
            i += 1
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def strip_swift_comments(source: str) -> list[str]:
    """Return comment-stripped lines while preserving exact 1-based line alignment."""
    if "//" not in source and "/*" not in source:
        return source.splitlines()

    def replace(match: re.Match[str]) -> str:
        tok = match.group(0)
        if tok.startswith("//"):
            return ""
        if tok.startswith("/*"):
            return "\n" * tok.count("\n")
        return tok

    if "/*" in source:
        stripped = SWIFT_TOKEN_RE.sub(replace, source)
        if "/*" in stripped:
            stripped = _strip_nested_block_comments(stripped)
        return stripped.splitlines()
    return SWIFT_TOKEN_RE.sub(replace, source).splitlines()


def is_generated(rel: str) -> bool:
    return rel.startswith("gen/") or rel.endswith(".pb.swift") or rel.endswith(".pb.go")


def is_prod_swift(rel: str) -> bool:
    return rel.endswith(".swift") and not is_generated(rel) and any(
        rel.startswith(p) for p in PROD_SWIFT_PREFIXES
    ) and not rel.startswith("AgentKeyringPackage/Tests/")


def is_test_source(rel: str) -> bool:
    if is_generated(rel):
        return False
    if rel.endswith(".go") and rel.endswith("_test.go"):
        return True
    return (rel.endswith(".swift") or rel.endswith(".go")) and any(rel.startswith(p) for p in TEST_PREFIXES)


def is_prod_go(rel: str) -> bool:
    return (
        rel.endswith(".go")
        and not rel.endswith("_test.go")
        and not is_generated(rel)
        and any(rel.startswith(p) for p in PROD_GO_PREFIXES)
    )


def swift_package_target(rel: str) -> str | None:
    prefix = "AgentKeyringPackage/Sources/"
    if not rel.startswith(prefix):
        return None
    parts = rel[len(prefix) :].split("/", 1)
    return parts[0] if len(parts) == 2 else None


def discover_backend_protocols(root: pathlib.Path) -> set[str]:
    protocols: set[str] = set()
    sources_dir = root / "AgentKeyringPackage" / "Sources"
    if not sources_dir.is_dir():
        return protocols
    for path in sources_dir.rglob("*.swift"):
        if path.name.endswith(".pb.swift"):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if "Backend" not in text or "protocol " not in text:
            continue
        for line in strip_swift_comments(text):
            for match in BACKEND_PROTO_RE.finditer(line):
                protocols.add(match.group(1))
    return protocols


def check_request_lifecycle_block(rel: str, stripped: list[str], errors: list[str]) -> None:
    in_block, seen_open, depth = False, False, 0
    for lineno, line in enumerate(stripped, 1):
        if not in_block and re.search(r"\benum\s+CredentialRequestLifecycle\b", line):
            in_block = True
        if in_block:
            if DEFAULT_CASE_RE.match(line):
                errors.append(
                    f"{rel}:{lineno}: state-machine-default: forbidden 'default:' catch-all inside CredentialRequestLifecycle"
                )
            if "{" in line:
                seen_open = True
            depth += line.count("{") - line.count("}")
            if seen_open and depth <= 0:
                in_block = seen_open = False


def check_file(root: pathlib.Path, rel: str, backend_protocols: set[str], errors: list[str]) -> None:
    path = root / rel
    if path.suffix.lower() in BINARY_SUFFIXES or not path.is_file():
        return
    raw = path.read_bytes()
    if b"\x00" in raw:
        return
    text = raw.decode("utf-8", errors="replace")

    # 1. Public repo hygiene across all tracked text files (fast substring pre-check).
    if HYGIENE_RE.search(text):
        for lineno, line in enumerate(text.splitlines(), 1):
            for token in HYGIENE_TOKENS:
                if token in line:
                    errors.append(f"{rel}:{lineno}: repo-hygiene: forbidden private machine reference '{token}'")

    if is_generated(rel):
        return

    if not (rel.endswith(".swift") or rel.endswith(".go")):
        return

    lines = text.splitlines()

    # 2. Line caps (prod Swift/Go <= 600, test Swift/Go <= 700).
    if is_test_source(rel):
        if len(lines) > TEST_LINE_CAP:
            errors.append(f"{rel}:1: file-length: test file has {len(lines)} lines (cap {TEST_LINE_CAP})")
    elif is_prod_swift(rel) or is_prod_go(rel):
        if len(lines) > PROD_LINE_CAP:
            errors.append(f"{rel}:1: file-length: prod file has {len(lines)} lines (cap {PROD_LINE_CAP})")

    # 3. Lint waivers & em dashes in Swift/Go source files.
    for match in LINT_WAIVER_RE.finditer(text):
        lineno = text.count("\n", 0, match.start()) + 1
        errors.append(f"{rel}:{lineno}: lint-waiver: forbidden inline lint suppression")
    if "\u2014" in text:
        for lineno, line in enumerate(lines, 1):
            if "\u2014" in line:
                errors.append(f"{rel}:{lineno}: em-dash: forbidden U+2014 em dash")

    if not rel.endswith(".swift"):
        return

    stripped = strip_swift_comments(text)
    target = swift_package_target(rel)

    # 4. UI / Domain / NotificationService import firewall.
    forbidden_imports: frozenset[str] = frozenset()
    if rel.startswith(APPROVAL_UI_PREFIX):
        forbidden_imports = APPROVAL_UI_FORBIDDEN_IMPORTS
    elif rel.startswith(WATCH_UI_PREFIX):
        forbidden_imports = WATCH_UI_FORBIDDEN_IMPORTS
    elif rel.startswith(SLIM_APP_PREFIXES):
        forbidden_imports = SLIM_APP_FORBIDDEN_IMPORTS
    elif target in DOMAIN_TARGETS:
        forbidden_imports = DOMAIN_FORBIDDEN_IMPORTS

    if forbidden_imports:
        for lineno, line in enumerate(stripped, 1):
            m = IMPORT_RE.match(line)
            if m and m.group(1) in forbidden_imports:
                errors.append(f"{rel}:{lineno}: import-firewall: forbidden import '{m.group(1)}'")

    # 5. Zero JSON/plist codecs in prod Swift sources (outside documented external-format allowlist).
    if is_prod_swift(rel) and rel not in JSON_PLIST_ALLOWLIST:
        for lineno, line in enumerate(stripped, 1):
            m = JSON_PLIST_RE.search(line)
            if m:
                errors.append(f"{rel}:{lineno}: no-json-plist: forbidden '{m.group(1)}' in Swift domain/app source")

    # 6. Zero UserDefaults in sealing, sync and iPhone engine code.
    if rel.startswith(USERDEFAULTS_FORBIDDEN_PREFIXES):
        for lineno, line in enumerate(stripped, 1):
            if USERDEFAULTS_RE.search(line):
                errors.append(f"{rel}:{lineno}: no-userdefaults: forbidden 'UserDefaults' in {pathlib.Path(rel).parent}")

    # 7. Zero default: catch-alls in explicit domain state machine reducers.
    if rel.startswith("AgentKeyringPackage/Sources/"):
        if pathlib.Path(rel).name in STATE_MACHINE_FILES:
            for lineno, line in enumerate(stripped, 1):
                if DEFAULT_CASE_RE.match(line):
                    errors.append(f"{rel}:{lineno}: state-machine-default: forbidden 'default:' catch-all in reducer")
        elif rel == "AgentKeyringPackage/Sources/AgentKeyringSealing/CredentialSealing.swift":
            check_request_lifecycle_block(rel, stripped, errors)

    # 8. Zero silent *Backend protocol extension defaults (concrete class extensions remain allowed).
    if rel.startswith("AgentKeyringPackage/Sources/") and backend_protocols:
        for lineno, line in enumerate(stripped, 1):
            m = BACKEND_EXT_RE.match(line)
            if m and m.group(1) in backend_protocols:
                errors.append(
                    f"{rel}:{lineno}: backend-protocol-extension: forbidden extension on protocol '{m.group(1)}'"
                )


def collect_files(root: pathlib.Path, argv: list[str]) -> list[str]:
    if argv:
        rels: list[str] = []
        for raw_arg in argv:
            p = pathlib.Path(raw_arg)
            if not p.is_absolute():
                p = (pathlib.Path.cwd() / p).resolve()
            else:
                p = p.resolve()
            try:
                rel = p.relative_to(root).as_posix()
            except ValueError:
                continue
            if (root / rel).is_file():
                rels.append(rel)
        return sorted(set(rels))
    out = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
    )
    return sorted(os.fsdecode(path) for path in out.split(b"\0") if path)


def main(argv: list[str]) -> int:
    root = ROOT
    if argv[:1] == ["--snapshot"]:
        if len(argv) != 2 or not pathlib.Path(argv[1]).is_dir():
            print("Usage: check_boundaries.py --snapshot DIRECTORY", file=sys.stderr)
            return 2
        root = pathlib.Path(argv[1]).resolve()
        argv = []
    files = collect_files(root, argv)
    backend_protocols = discover_backend_protocols(root)
    errors: list[str] = []
    for rel in files:
        check_file(root, rel, backend_protocols, errors)
    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        print(f"check_boundaries: {len(errors)} violation(s) found.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
