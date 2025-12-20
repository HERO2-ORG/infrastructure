# Hero2 Infrastructure Repository

This repository serves two purposes:
1. **CI/CD Infrastructure** - Reusable GitHub Actions and shared configurations
2. **iOS Code Signing** - Fastlane match certificates and provisioning profiles

---

## CI/CD Infrastructure

Centralized CI/CD infrastructure for the Hero2 organization. Provides reusable GitHub Actions composite actions and shared configurations for consistent workflows across all Hero2 repositories.

### Composite Actions

#### 1. SSH Deploy (`ssh-deploy`)

Deploys applications to remote servers via SSH using Docker Compose.

**Inputs:**
- `host` (required): Server IP address
- `user` (required): SSH username
- `key` (required): SSH private key
- `compose-file` (required): Path to docker-compose file
- `remote-path` (required): Remote deployment directory
- `environment` (required): Environment name (staging/production)

**Example Usage:**
```yaml
- name: Deploy to Production
  uses: HERO2-ORG/infrastructure/.github/actions/ssh-deploy@main
  with:
    host: ${{ secrets.SERVER_IP }}
    user: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_KEY }}
    compose-file: docker-compose.deploy.yml
    remote-path: /srv/stack/backend
    environment: production
```

#### 2. Health Check (`health-check`)

Validates service availability by checking health endpoints with retry logic.

**Inputs:**
- `url` (required): Health check URL
- `max-attempts` (optional, default: 5): Maximum retry attempts
- `retry-delay` (optional, default: 10): Delay between retries (seconds)

**Example Usage:**
```yaml
- name: Verify Deployment
  uses: HERO2-ORG/infrastructure/.github/actions/health-check@main
  with:
    url: https://api.hero2.org/health
    max-attempts: 5
    retry-delay: 10
```

#### 3. Semantic Release Node (`semantic-release-node`)

Automated semantic versioning for Node.js projects using conventional commits.

**Inputs:**
- `github-token` (required): GitHub token for creating releases

**Behavior:**
- Analyzes conventional commit messages
- Determines next version (major/minor/patch)
- Generates CHANGELOG.md
- Creates GitHub release with release notes
- Tags release with v* format (e.g., v1.2.3)

**Example Usage:**
```yaml
- name: Semantic Release
  uses: HERO2-ORG/infrastructure/.github/actions/semantic-release-node@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

#### 4. Semantic Release Flutter (`semantic-release-flutter`)

Automated semantic versioning for Flutter projects.

**Inputs:**
- `github-token` (required): GitHub token for creating releases

**Behavior:**
- Analyzes conventional commit messages
- Determines next version
- Updates pubspec.yaml version field
- Creates v* tag (e.g., v1.2.3)
- Creates GitHub release
- Triggers Xcode Cloud builds (if configured to watch v* tags)

**Example Usage:**
```yaml
- name: Semantic Release
  uses: HERO2-ORG/infrastructure/.github/actions/semantic-release-flutter@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

#### 5. Lighthouse CI (`lighthouse-check`)

Runs Lighthouse performance checks on websites.

**Inputs:**
- `url` (required): Website URL to test

**Behavior:**
- Runs Lighthouse performance audit
- Uploads artifacts (reports)
- Publishes results to temporary public storage

**Example Usage:**
```yaml
- name: Lighthouse Check
  uses: HERO2-ORG/infrastructure/.github/actions/lighthouse-check@main
  with:
    url: https://hero2.org
```

#### 6. Docker Build and Push (`docker-build-push`)

Builds and pushes Docker images to container registries.

**Inputs:**
- `context` (required): Build context path
- `image-name` (required): Full image name
- `tags` (required): Newline-separated list of tags
- `registry` (required): Registry type (docker-hub or ghcr)
- `username` (required): Registry username
- `password` (required): Registry password/token

**Outputs:**
- `image-digest`: Image SHA256 digest

**Example Usage:**
```yaml
- name: Build and Push
  uses: HERO2-ORG/infrastructure/.github/actions/docker-build-push@main
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

### Shared Configurations

#### Semantic Release (`.releaserc.base.json`)

Base configuration for semantic-release. Repositories can extend this by creating their own `.releaserc.json`:

```json
{
  "extends": "https://raw.githubusercontent.com/HERO2-ORG/infrastructure/main/configs/.releaserc.base.json"
}
```

**Features:**
- Conventional commits analysis
- Automated CHANGELOG.md generation
- GitHub release creation
- Git tag creation

#### Markdown Lint (`.markdownlint.yaml`)

Markdown linting configuration with relaxed rules for flexibility.

**Disabled Rules:**
- **MD013**: Line length - Disabled to allow long lines (links, tables, code examples)
- **MD045**: Images should have alternate text - Disabled to allow images without alt text in documentation

See `configs/.markdownlint.yaml` for inline comments explaining each rule.

**Usage in Workflows:**
```yaml
- uses: DavidAnson/markdownlint-cli2-action@v18
  with:
    config: 'https://raw.githubusercontent.com/HERO2-ORG/infrastructure/main/configs/.markdownlint.yaml'
    globs: '**/*.md'
```

#### Commit Lint (`commitlint.config.js`)

Enforces conventional commit message format.

**Allowed Types:**
- `feat`: New feature (triggers minor version bump)
- `fix`: Bug fix (triggers patch version bump)
- `docs`: Documentation changes
- `style`: Code style changes (formatting, semicolons, etc.)
- `refactor`: Code refactoring
- `perf`: Performance improvements (triggers patch version bump)
- `test`: Test additions or modifications
- `chore`: Build process or auxiliary tool changes
- `revert`: Revert previous commit

**Format:** `<type>(<scope>): <subject>`

**Examples:**
- `feat(auth): add OAuth login`
- `fix(rewards): calculate correct CO2 savings`
- `perf(database): optimize trip query`
- `docs(readme): update deployment instructions`

**Usage in Workflows:**
```yaml
- run: |
    npm install -g @commitlint/cli @commitlint/config-conventional
    echo "${{ github.event.pull_request.title }}" | commitlint \
      --config https://raw.githubusercontent.com/HERO2-ORG/infrastructure/main/configs/commitlint.config.js
```

### Private Repository Access

All HERO2 organization repositories automatically have access to these reusable actions via `GITHUB_TOKEN`. No additional permissions configuration is required.

When a workflow runs in any HERO2 private repository, the default `GITHUB_TOKEN` has read access to other private repositories in the same organization, allowing seamless use of composite actions.

### Repository Structure

```
infrastructure/
├── .github/
│   └── actions/                      # Reusable composite actions
│       ├── docker-build-push/
│       ├── ssh-deploy/
│       ├── health-check/
│       ├── semantic-release-node/
│       ├── semantic-release-flutter/
│       └── lighthouse-check/
├── configs/                          # Shared configurations
│   ├── .releaserc.base.json
│   ├── .markdownlint.yaml
│   └── commitlint.config.js
├── certs/                            # iOS certificates
├── profiles/                         # iOS provisioning profiles
└── README.md                         # This file
```

---

## [fastlane match](https://docs.fastlane.tools/actions/match/)

This repository contains all your certificates and provisioning profiles needed to build and sign your applications. They are encrypted using OpenSSL via a passphrase.

**Important:** Make sure this repository is set to private and only your team members have access to this repo.

### Installation

Make sure you have the latest version of the Xcode command line tools installed:

```
xcode-select --install
```

Install _fastlane_ using bundler by following instructions here on [fastlane docs](https://docs.fastlane.tools).

or alternatively using

`brew install fastlane`

### Usage

Navigate to your project folder and run

```
fastlane match appstore
```

```
fastlane match adhoc
```

```
fastlane match development
```

```
fastlane match enterprise
```

For more information open [fastlane match git repo](https://docs.fastlane.tools/actions/match/)

### Content

#### certs

This directory contains all your certificates with their private keys

#### profiles

This directory contains all provisioning profiles

---

For more information open [fastlane match git repo](https://docs.fastlane.tools/actions/match/)
