#!/usr/bin/env bash
# The production deploy runs its playbook with --check first. Applies the
# restic role in check mode to a fresh host (a Debian container) that has no
# restic yet, the state of every VM on the first rollout and every version bump,
# then for real, which must leave a working restic.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
name=hero2-backup-checkmode
work="$(mktemp -d)"
trap 'docker rm -f "$name" >/dev/null 2>&1; rm -rf "$work"' EXIT

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" debian:bookworm-slim sleep 600 >/dev/null
# Python and python3-apt only, like a fresh Ubuntu VM; and the empty binary a failed unpack once left
# on staging, which the role must replace rather than trust.
docker exec "$name" sh -c 'apt-get -qq update >/dev/null && apt-get -qq install -y python3 python3-apt >/dev/null && touch /usr/local/bin/restic-0.19.1'

cat > "$work/play.yml" <<PLAY
- hosts: $name
  gather_facts: true
  roles:
    - $here/../../ansible/roles/restic
PLAY
printf '%s ansible_connection=community.docker.docker ansible_python_interpreter=python3\n' "$name" > "$work/inventory"

ansible-playbook -i "$work/inventory" "$work/play.yml" --check
ansible-playbook -i "$work/inventory" "$work/play.yml"
docker exec "$name" restic version
