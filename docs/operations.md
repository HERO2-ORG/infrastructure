# Operations

## Local Setup

Install Ansible dependencies and create a local inventory override:

```bash
cd ansible
cp inventory/local.example.yml inventory/local.yml
make install
```

Set the private key path in `inventory/local.yml`:

```yaml
all:
  vars:
    ansible_ssh_private_key_file: ~/.ssh/hero2_ansible
```

If the key has a passphrase, add it to your SSH agent before running Ansible:

```bash
ssh-add ~/.ssh/hero2_ansible
```

## Connectivity Checks

```bash
make ping-internal
make ping-staging
make ping-production
```

## Applying Platform Roles

Run check mode before apply. Apply staging before production.

```bash
make check-internal
make apply-internal

make check-staging
make apply-staging

make check-production
make apply-production
```
