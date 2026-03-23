# Hero2 Infrastructure Repository

Centralized CI/CD infrastructure for the Hero2 organization — reusable GitHub Actions and shared configurations for consistent workflows across all repositories.

See [WORKFLOW.md](./WORKFLOW.md) for branch naming, PR conventions, and the full development lifecycle.

---

## Repository Contents

```
infrastructure/
├── .github/
│   └── actions/
│       ├── docker-build-push/
│       ├── health-check/
│       ├── lighthouse-check/
│       ├── semantic-release-flutter/
│       ├── semantic-release-node/
│       └── ssh-deploy/
└── configs/
    ├── .markdownlint.yaml
    ├── .releaserc.base.json
    ├── commitlint.config.js
    └── lychee.toml
```

---

## Composite Actions

### `ssh-deploy`

Deploys applications to remote servers via SSH using Docker Compose.

| Input | Required | Description |
|---|---|---|
| `host` | yes | Server IP address |
| `user` | yes | SSH username |
| `key` | yes | SSH private key |
| `compose-file` | yes | Path to docker-compose file |
| `remote-path` | yes | Remote deployment directory |
| `environment` | yes | Environment name (`staging`/`production`) |

```yaml
- uses: HERO2-ORG/infrastructure/.github/actions/ssh-deploy@main
  with:
    host: ${{ secrets.SERVER_IP }}
    user: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_KEY }}
    compose-file: docker-compose.deploy.yml
    remote-path: /srv/stack/backend
    environment: production
```

### `health-check`

Validates service availability by polling a health endpoint with retry logic.

| Input | Required | Default | Description |
|---|---|---|---|
| `url` | yes | — | Health check URL |
| `max-attempts` | no | `5` | Maximum retry attempts |
| `retry-delay` | no | `10` | Delay between retries (seconds) |

```yaml
- uses: HERO2-ORG/infrastructure/.github/actions/health-check@main
  with:
    url: https://api.hero2.org/health
    max-attempts: 5
    retry-delay: 10
```

### `semantic-release-node`

Automated semantic versioning for Node.js projects using conventional commits. Analyzes commit messages, bumps the version, generates `CHANGELOG.md`, and creates a GitHub release tagged `v*`.

| Input | Required | Description |
|---|---|---|
| `github-token` | yes | GitHub token for creating releases |

```yaml
- uses: HERO2-ORG/infrastructure/.github/actions/semantic-release-node@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

### `semantic-release-flutter`

Same as `semantic-release-node` but also updates `pubspec.yaml` and can trigger Xcode Cloud builds when configured to watch `v*` tags.

| Input | Required | Description |
|---|---|---|
| `github-token` | yes | GitHub token for creating releases |

```yaml
- uses: HERO2-ORG/infrastructure/.github/actions/semantic-release-flutter@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

### `lighthouse-check`

Runs a Lighthouse performance audit and uploads the report as a workflow artifact.

| Input | Required | Description |
|---|---|---|
| `url` | yes | Website URL to audit |

```yaml
- uses: HERO2-ORG/infrastructure/.github/actions/lighthouse-check@main
  with:
    url: https://hero2.org
```

### `docker-build-push`

Builds and pushes a Docker image to Docker Hub or GHCR.

| Input | Required | Description |
|---|---|---|
| `context` | yes | Build context path |
| `image-name` | yes | Full image name |
| `tags` | yes | Newline-separated list of tags |
| `registry` | yes | `docker-hub` or `ghcr` |
| `username` | yes | Registry username |
| `password` | yes | Registry password or token |

**Output:** `image-digest` — SHA256 digest of the pushed image.

```yaml
- uses: HERO2-ORG/infrastructure/.github/actions/docker-build-push@main
  with:
    context: .
    image-name: hero2original/hero2backend
    tags: |
      latest
      ${{ github.sha }}
    registry: docker-hub
    username: ${{ secrets.DOCKER_USERNAME }}
    password: ${{ secrets.DOCKER_PASSWORD }}
```

---

## Shared Configurations

### `.releaserc.base.json`

Base semantic-release configuration. Extend it in any repository:

```json
{
  "extends": "https://raw.githubusercontent.com/HERO2-ORG/infrastructure/main/configs/.releaserc.base.json"
}
```

### `.markdownlint.yaml`

Markdown linting rules used across all repositories. Reference it in workflows:

```yaml
- uses: DavidAnson/markdownlint-cli2-action@v18
  with:
    config: 'https://raw.githubusercontent.com/HERO2-ORG/infrastructure/main/configs/.markdownlint.yaml'
    globs: '**/*.md'
```

### `commitlint.config.js`

Enforces conventional commit format on PR titles. Reference it in workflows:

```yaml
- run: |
    npm install -g @commitlint/cli @commitlint/config-conventional
    echo "${{ github.event.pull_request.title }}" | commitlint \
      --config https://raw.githubusercontent.com/HERO2-ORG/infrastructure/main/configs/commitlint.config.js
```

### `lychee.toml`

Link checker configuration shared across repositories. Excludes localhost URLs.

```yaml
- uses: lycheeverse/lychee-action@v2
  with:
    args: --config https://raw.githubusercontent.com/HERO2-ORG/infrastructure/main/configs/lychee.toml
```

---

## Private Repository Access

All HERO2 organization repositories automatically have read access to this repository via the default `GITHUB_TOKEN` — no additional permissions configuration required.
