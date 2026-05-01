---
name: github-repo-hygiene
description: Use when working with this team's GitHub repos — branching, committing, opening PRs, configuring CI, managing secrets, or scaffolding a new repo. Defines branch naming (JIRA-key/slug), conventional commits, PR template, required CI checks (lint, type-check, secret scan), CODEOWNERS, branch protection rules, and incident response for leaked secrets. Triggers when starting a new branch, opening or reviewing a PR, committing changes, creating a new repo, scaffolding `.github/`, or responding to a leaked-secret alert.
---

# GitHub Repo Hygiene

The team uses **JIRA for tickets, Confluence for docs, GitHub for code**. This skill keeps GitHub clean and traceable: every change links back to a JIRA ticket, every PR has a structured review, and every repo has the same baseline guardrails.

## Branch naming

Pattern: `<JIRA-KEY>/<short-kebab-slug>`

| Example | Notes |
|---|---|
| `DATA-1234/add-membr-segmentation-view` | Standard feature work |
| `DATA-1567/fix-bcp-password-leak` | Bugfix |
| `DATA-1890/chore-bump-polars-1-9` | Maintenance |
| `hotfix/DATA-2001-prod-snowflake-creds` | Hotfix going to `main` directly — rare |

Rules:
- Always start with the JIRA key. No exceptions for "quick fixes" — they all need a ticket.
- Slug is kebab-case, lowercase, ≤ 50 characters, describes the change in plain English.
- Personal branches (`doug/scratch`) are fine **locally** but never pushed.

## Commit messages — conventional commits

Format: `<type>(<scope>): <imperative summary>`

```
feat(acct): add daily balance SCD2 transform

Implements DATA-1234. Loads dna.balance_history into acct.daily_balances
nightly with SCD2 effective dating. Hash-based change detection skips
unchanged rows.

Refs DATA-1234
```

| Type | Use |
|---|---|
| `feat` | New functionality |
| `fix` | Bug fix |
| `chore` | Tooling, deps, refactors with no behavior change |
| `docs` | Documentation only |
| `test` | Tests only |
| `ci` | CI/CD pipeline changes |
| `revert` | Reverting a prior commit |

Rules:
- Imperative mood ("add", not "added" or "adds").
- Scope is the schema or module touched (`acct`, `membr`, `pipelines`, etc.) — optional but encouraged.
- Body explains the WHY. The diff already shows the WHAT.
- Always include `Refs <JIRA-KEY>` (or `Closes <JIRA-KEY>` if the ticket is fully resolved by this commit).

## Pull requests

**PR title** mirrors the branch: `[DATA-1234] Add daily balance SCD2 transform`

**PR body** uses this template (lives at `.github/pull_request_template.md`):

```markdown
## Summary
<2-3 sentences: what changed, why>

## JIRA
[DATA-1234](https://jira.example.com/browse/DATA-1234)

## Confluence
<Link to runbook page if this affects a pipeline>

## Changes
- ...

## Test plan
- [ ] Unit tests pass (`uv run pytest tests/transforms`)
- [ ] Integration tests pass against test schema
- [ ] Manually verified row counts vs source
- [ ] Reviewed for PII / secrets in logs

## Reviewer checklist
- [ ] Schema follows naming conventions (sql-naming-conventions skill)
- [ ] Python style follows team standards (python-data-eng-style skill)
- [ ] File headers populated (code-documentation-standard skill)
- [ ] No secrets in code, env vars, or sample data
- [ ] Confluence runbook exists and is linked (for pipelines)
```

Rules:
- **One ticket per PR.** Don't bundle unrelated changes — it makes review and revert harder.
- **Squash merge only.** Keeps `main` history linear and one-commit-per-feature.
- **Delete the branch after merge.** Keep the remote branch list small.
- **No self-merge.** Always at least one reviewer (CODEOWNERS enforces this).

## Repo scaffolding — every new repo gets these files

```
my-repo/
├── README.md                          # what + why + how to run + links
├── .gitignore                         # see template below
├── .env.example                       # all env vars, placeholder values
├── .pre-commit-config.yaml            # ruff, mypy, detect-secrets
├── pyproject.toml                     # ruff + mypy config + deps
├── CODEOWNERS                         # required reviewers
├── .github/
│   ├── pull_request_template.md       # template above
│   └── workflows/
│       └── ci.yml                     # lint, type-check, test, secret-scan
└── src/, tests/                       # see python-data-eng-style skill
```

### `.gitignore` — required entries

```gitignore
# Python
__pycache__/
*.pyc
.venv/
*.egg-info/
.mypy_cache/
.pytest_cache/
.ruff_cache/

# Secrets & config
.env
.env.*
!.env.example
*.pem
*.key
credentials*
google-services.json

# Data files — NEVER commit these
*.csv
*.parquet
*.xlsx
*.xls
*.bcp
*.dat
data/
samples/

# OS
.DS_Store
Thumbs.db

# IDE
.vscode/
.idea/
```

If you genuinely need to commit a small sample CSV (e.g., as a test fixture), put it under `tests/fixtures/` and force-add: `git add -f tests/fixtures/sample.csv`. Then verify it contains zero PII before committing.

### `CODEOWNERS` — example

```
# Default owners
*                       @data-eng-team

# SQL changes need a SQL-trained reviewer
*.sql                   @data-eng-team @sql-leads

# Pipeline orchestration
src/*/pipelines/        @data-eng-team @platform-leads

# CI/CD
.github/workflows/      @platform-leads
```

### `.github/workflows/ci.yml` — minimum CI

Every CI run must pass:

1. **Format check** — `uv run ruff format --check`
2. **Lint** — `uv run ruff check`
3. **Type check** — `uv run mypy src/`
4. **Unit tests** — `uv run pytest tests/transforms tests/utils`
5. **Secret scan** — `detect-secrets scan --baseline .secrets.baseline`

Integration tests (Snowflake, BCP) run on a separate workflow against a test schema, gated on `pull_request` to `main`.

## Branch protection — `main` rules

Configure in repo Settings → Branches:

- **Require pull request reviews** — minimum 1 approving review.
- **Require review from CODEOWNERS** — yes.
- **Dismiss stale reviews when new commits are pushed** — yes.
- **Require status checks to pass** — all CI jobs.
- **Require branches to be up to date** — yes.
- **Do not allow bypassing the above settings** — yes (even for admins, except documented hotfix process).
- **Disallow force pushes** — yes.
- **Disallow deletions** — yes.

## Secrets — prevention and incident response

### Prevention (always on)

1. **`detect-secrets` pre-commit hook** — blocks commits containing secret-shaped strings.
2. **`detect-secrets scan --baseline`** in CI — fails the build if a new secret slips through.
3. **GitHub Secret Scanning** enabled in repo settings (free for public repos, included in Advanced Security for private).
4. **`.gitignore` covers `.env`, `*.pem`, `*.key`, `credentials*`** — see scaffold above.

### If a secret is committed (incident response)

The instant you notice:

1. **Rotate the secret immediately.** This is step one. The leaked value is compromised the moment it hits a remote — even a force-push doesn't undo what other people may have already pulled.
2. **Notify the team** in the security channel with the rotation status.
3. **Rewrite history only with coordination.** `git filter-repo` (or `BFG Repo-Cleaner`) can remove the secret from history, but force-pushing a rewritten history requires every collaborator to re-clone. Coordinate before doing this.
4. **Document the incident** — Confluence page or JIRA ticket. What leaked, when, how, what changed to prevent recurrence.

**Order matters: rotate first, clean history second.** A clean history with a still-valid secret is a false sense of security.

## What to do when applying this skill

When the user is about to:
- **Start work** → confirm there's a JIRA ticket; create the branch with the right name.
- **Commit** → confirm the message follows the conventional-commits format; remind about JIRA reference.
- **Open a PR** → fill the template; verify checklist items before pushing.
- **Scaffold a new repo** → copy the file set above; configure branch protection same day.
- **React to a leaked secret** → rotate first, then clean history.

## What NOT to do

- Do not push directly to `main`. Ever. Branch protection should make this impossible — if it's possible, fix the protection rules.
- Do not `git push --force` to a shared branch.
- Do not commit `.env`, credentials, keys, or data files. The pre-commit hook catches these — don't bypass it with `--no-verify`.
- Do not merge your own PR without review.
- Do not let CI failures linger. A red `main` blocks everyone.
- Do not amend or rebase commits that have been pushed and reviewed — that invalidates the review.
- Do not skip the Confluence link in the PR template for pipeline changes.
