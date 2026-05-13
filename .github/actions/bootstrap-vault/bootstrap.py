"""Fill missing generatable secrets in a decrypted vault from secrets-spec.yml.

Writes outputs to $GITHUB_OUTPUT:
  changed=true|false  -- whether any new value was generated
  missing=<...>  -- external keys still missing after generation
"""

import argparse
import os
import subprocess
import sys

import yaml


def load_yaml(path):
    if not os.path.exists(path):
        return {}
    with open(path) as fh:
        return yaml.safe_load(fh) or {}


def write_outputs(changed, missing):
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a") as fh:
        fh.write(f"changed={'true' if changed else 'false'}\n")
        fh.write(f"missing={' '.join(missing)}\n")


def fill_env(spec_secrets, env_secrets):
    changed = False
    for key, raw_meta in spec_secrets.items():
        meta = raw_meta or {}
        if env_secrets.get(key) not in (None, ""):
            continue
        cmd = meta.get("generate")
        if not cmd:
            continue
        result = subprocess.run(
            cmd, shell=True, check=True, capture_output=True, text=True
        )
        env_secrets[key] = result.stdout.rstrip("\n")
        changed = True
    return changed


def find_missing(spec_secrets, env_secrets, label):
    missing = []
    for key, raw_meta in spec_secrets.items():
        meta = raw_meta or {}
        if meta.get("external") and not env_secrets.get(key):
            missing.append(f"{label}{key}" if label else key)
    return missing


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--secrets", required=True)
    parser.add_argument("--spec", required=True)
    parser.add_argument("--layout", choices=["env", "flat"], default="env")
    parser.add_argument("--envs", default="")
    args = parser.parse_args()

    spec_secrets = load_yaml(args.spec).get("secrets") or {}
    data = load_yaml(args.secrets)

    changed = False
    missing = []

    if args.layout == "flat":
        for key in list(data.keys()):
            if key == "secrets" and not data[key]:
                del data[key]
        changed = fill_env(spec_secrets, data)
        missing = find_missing(spec_secrets, data, label="")
    else:
        envs = args.envs.split()
        if not envs:
            print("--envs required when --layout=env", file=sys.stderr)
            sys.exit(2)
        data.setdefault("secrets", {})
        for env in envs:
            env_secrets = data["secrets"].get(env) or {}
            data["secrets"][env] = env_secrets
            if fill_env(spec_secrets, env_secrets):
                changed = True
            missing.extend(find_missing(spec_secrets, env_secrets, label=f"{env}."))

    if changed:
        with open(args.secrets, "w") as fh:
            yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=True)

    write_outputs(changed, missing)


if __name__ == "__main__":
    main()
