#!/usr/bin/env python3
# Written by AI on 2026.11.01 by model gpt-6.1-sol.
"""Harmless stdin consumer for the app's built-in example login. Prints nothing."""
from pathlib import Path
import os
import sys

if len(sys.argv) != 2:
    raise SystemExit(2)
value = sys.stdin.buffer.read()
if value != b'example-password':
    raise SystemExit(1)
result = Path(sys.argv[1])
previous = int(result.read_text()) if result.exists() else 0
with os.fdopen(os.open(result, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as output:
    output.write(str(previous + 1) + '\n')
