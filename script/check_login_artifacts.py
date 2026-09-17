#!/usr/bin/env python3
"""Check text artifacts for generated fixture secrets without printing the values.

This detects literal and common encoded values. It does not inspect image pixels.
Exit status: 0 no matches, 1 matches, 2 unreadable input or invalid fixture.
"""

import argparse
import base64
import html
import json
from pathlib import Path
import sys
import time
import urllib.parse

from test_login_server import verification_code


def patterns(fixture):
    values = {fixture[key] for key in ("username", "password", "totp_secret")}
    secret = base64.b64decode(fixture["totp_secret"], validate=True)
    started_at = int(fixture["started_at"]) - 30
    for timestamp in range(started_at, int(time.time()) + 61, 30):
        values.add(verification_code(secret, timestamp))
    variants = set()
    for value in values:
        variants.update((value, html.escape(value), urllib.parse.quote(value, safe=""),
                         urllib.parse.quote_plus(value), json.dumps(value)[1:-1],
                         base64.b64encode(value.encode("utf-8")).decode("ascii")))
    return {value.encode("utf-8") for value in variants if value}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("artifacts", nargs="+", type=Path)
    arguments = parser.parse_args()
    try:
        fixture = json.loads(arguments.config.read_text())
        secret_patterns = patterns(fixture)
    except (OSError, ValueError, KeyError, TypeError):
        print(json.dumps({"error": "Cannot read synthetic fixture"}))
        return 2
    files = set()
    for artifact in arguments.artifacts:
        if artifact.is_dir():
            files.update(path for path in artifact.rglob("*") if path.is_file())
        else:
            files.add(artifact)
    matches = []
    unreadable = []
    for path in sorted(files):
        try:
            content = path.read_bytes()
        except OSError:
            unreadable.append(str(path))
            continue
        count = sum(content.count(pattern) for pattern in secret_patterns)
        if count:
            matches.append({"path": str(path), "matches": count})
    print(json.dumps({"files_scanned": len(files) - len(unreadable), "files_with_matches": len(matches),
                      "occurrences": sum(match["matches"] for match in matches),
                      "artifacts": matches, "unreadable_files": unreadable}))
    return 2 if unreadable else 1 if matches else 0


if __name__ == "__main__":
    sys.exit(main())
