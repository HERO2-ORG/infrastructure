# Shared CI Actions and Config

## Composite Actions

### `docker-build-push`

Builds and pushes a Docker image to Docker Hub or GHCR.

| Input | Required | Description |
|---|---|---|
| `context` | yes | Build context path. |
| `image-name` | yes | Full image name. |
| `tags` | yes | Newline-separated list of tags. |
| `registry` | yes | `docker-hub` or `ghcr`. |
| `username` | yes | Registry username. |
| `password` | yes | Registry password or token. |

Output: `image-digest`.

### `health-check`

Polls a health endpoint with retry logic.

| Input | Required | Default | Description |
|---|---|---|---|
| `url` | yes | - | Health check URL. |
| `max-attempts` | no | `5` | Maximum retry attempts. |
| `retry-delay` | no | `10` | Delay between retries in seconds. |

### `lighthouse-check`

Runs a Lighthouse performance audit and uploads the report as a workflow artifact.

| Input | Required | Description |
|---|---|---|
| `url` | yes | Website URL to audit. |

### `semantic-release-node`

Runs semantic-release for Node.js repositories.

| Input | Required | Description |
|---|---|---|
| `github-token` | yes | GitHub token for creating releases. |

### `semantic-release-flutter`

Runs semantic-release for Flutter repositories and updates `pubspec.yaml`.

| Input | Required | Description |
|---|---|---|
| `github-token` | yes | GitHub token for creating releases. |

### `ssh-deploy`

Legacy SSH deployment action. New service-owned deploys should prefer service-local Ansible playbooks.

| Input | Required | Description |
|---|---|---|
| `host` | yes | Server IP address. |
| `user` | yes | SSH username. |
| `key` | yes | SSH private key. |
| `compose-file` | yes | Path to Docker Compose file. |
| `remote-path` | yes | Remote deployment directory. |
| `environment` | yes | Environment name. |

## Shared Config

| File | Purpose |
|---|---|
| `configs/.markdownlint.yaml` | Markdown lint rules. |
| `configs/.releaserc.base.json` | Base semantic-release config. |
| `configs/commitlint.config.js` | Conventional commit lint config. |
| `configs/lychee.toml` | Link checker config. |
