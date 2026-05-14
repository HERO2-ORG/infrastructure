# Development Workflow

Full development lifecycle across Hero2 repositories — from picking up an issue to merging a pull request.

---

## 0. Branch Model

Repositories use one of two layouts depending on whether they deploy through a release cycle.

**Staging + production** (deployed services):

- `staging` is the default branch — all feature/fix PRs merge here.
- `production` is the release branch — promoted from `staging` on release.

**Single-branch** (tooling, research, repos without a separate release cadence):

- `main` is the only long-lived branch — all PRs merge here.

The conventions below apply to both layouts. Where a step says "the default branch", substitute `staging` or `main` accordingly.

---

## 1. Branch Naming

```
<type>/<feature>
<type>/<feature>-<specifier>
```

| Type | Use for |
|---|---|
| `feature` | New functionality |
| `fix` | Bug fixes |
| `refactor` | Code restructuring without behavior change |
| `docs` | Documentation only |
| `chore` | Build, CI/CD, dependencies, tooling |
| `perf` | Performance improvements |
| `test` | Adding or updating tests |

**Examples:**

- `feature/rewards-widget`
- `feature/rewards-widget-animation`
- `fix/auth-token-refresh`
- `refactor/trip-tracking-co2`
- `chore/ci-docker-cache`

Rules:

- Always one slash
- Lowercase, hyphens to separate words
- No ticket numbers in branch names

---

## 2. Creating a Branch

Branch from the default branch:

```bash
git fetch origin
git checkout -b feature/rewards-widget origin/staging   # or origin/main for single-branch repos
```

If your work builds on another in-progress branch, branch from that branch instead and note the dependency in your PR description.

---

## 3. Keeping Your Branch Up to Date

Always rebase onto the default branch, never merge:

```bash
git fetch origin
git rebase origin/staging   # or origin/main
```

Resolve conflicts commit by commit during the rebase. Do not create merge commits.

---

## 4. Opening a Pull Request

### Title

The PR title must follow [Conventional Commits](https://www.conventionalcommits.org/) format as it becomes the squash commit message and is linted by CI:

```
<type>(<scope>): <subject>
```

Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `revert`

**Examples:**

- `feat(rewards): add CO2 savings to widget`
- `fix(auth): handle expired refresh token`
- `refactor(trips): extract CO2 calculation into service`

Subject lowercase, no trailing period. Scope optional but encouraged when the change is clearly contained to one area.

### Description

Include at minimum:

- What the change does and why
- Any relevant context or decisions made
- Screenshots or recordings for UI changes

### Linking Issues

Always link related issues so they close automatically on merge:

```
Closes #42
```

Use `Relates to #42` for issues that are related but not fully resolved by this PR. Multiple issues can be linked on separate lines.

### Cross-Repo Changes

When two changes across different repositories depend on each other:

- Use the **exact same branch name** in both repositories
- Open both PRs at the same time
- Reference the other PR in each description: `Depends on HERO2-ORG/backend#123`
- Both PRs must reference the same issue(s)

### Draft PRs

Open a draft PR early if you want feedback or want CI to run before the work is complete. Rebase and convert to ready when all checks pass.

---

## 5. CI Checks

All checks must pass before merging.

| Check | What it enforces |
|---|---|
| **Commit lint** | PR title follows conventional commits format (`configs/commitlint.config.js`) |
| **Markdown lint** | Markdown style rules (`configs/.markdownlint.yaml`) |
| **Link check** | No broken external links in documentation (`configs/lychee.toml`) |

Repository-specific checks (tests, builds, type checks) are defined in each repository's own workflow files.

---

## 6. Merging

- Squash merge into the default branch
- The squash commit message must match the PR title (conventional commits format)
- The PR author merges once all checks pass and at least one review is approved
- Do not merge your own PR without a review unless explicitly agreed (e.g. hotfix, docs-only change)

---

## 7. Releasing

For staging + production repos: a release promotes the current `staging` HEAD into `production`. Hotfixes that need to bypass staging go directly to `production` and are then merged back into `staging`.

Single-branch repos have no release step — `main` is the live branch.
