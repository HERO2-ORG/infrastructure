#!/usr/bin/env bash
# Runs the transit recorder tests in the Python the VM runs, with the same
# pinned packages as the role installs.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
pins="$(awk '/^transit_recorder_packages:/ {f=1; next} f && /^  - / {printf "%s ", $2; next} f {exit}' "$repo/ansible/roles/transit-recorder/defaults/main.yml")"
docker run --rm -v "$repo:/repo:ro" -w /repo python:3.12-slim sh -c \
  "pip install -q --disable-pip-version-check --root-user-action=ignore --retries 10 --timeout 60 $pins pytest==8.3.4 && python -m pytest -q -p no:cacheprovider scripts/transit-recorder-test"
