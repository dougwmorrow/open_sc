---
name: pii-and-secrets-handling
description: Use whenever the work touches credentials (database passwords, API keys, private keys), member/customer PII (names, SSN, DOB, account numbers, addresses, balances), or both. Cuts across SQL, Python, BCP, Snowflake, and GitHub workflows. Defines how to load secrets, where they may and may not appear, how to mask PII in logs, how to handle data files locally, and how to respond to a leak. Triggers on any code that reads credentials, queries PII columns, writes log lines about data, exports data files, or commits config.
---

# PII and Secrets Handling

This is a credit-union data team — every member field is regulated PII, every credential is a path to that PII. This skill is the floor, not the ceiling. If you're unsure whether something is sensitive, treat it as sensitive.

## What counts as a secret

| Category | Examples |
|---|---|
| Database credentials | SQL Server / Snowflake passwords, Snowflake private keys (`*.p8`), BCP connection strings |
| Cloud credentials | AWS access keys, Azure service principal secrets, GCP service-account JSON |
| API tokens | Snowflake OAuth tokens, JIRA API tokens, GitHub PATs, Slack webhook URLs |
| Encryption material | Private keys (`.pem`, `.key`, `.p8`), JWT signing secrets |
| Connection strings | Anything containing user + password embedded |

## What counts as PII (member-level)

| Always PII | Often PII in context |
|---|---|
| Name (first, last, middle) | Account balance |
| SSN, EIN, ITIN | Transaction history |
| Date of birth | IP address |
| Account number, card number | Email, phone |
| Address (street, ZIP+4) | Device IDs |
| Driver's license, passport | Login timestamps |
| Member ID *(internal — still PII when joinable to the above)* | NPS comments |

Aggregates and counts are **not** PII (e.g., "1,247 members opened a CD this quarter"). Anything joinable back to one person is.

## Loading secrets — how

**Local development:** `.env` file, loaded via `python-dotenv`. Never committed.

```python
from dotenv import load_dotenv
import os

load_dotenv()  # reads .env in cwd
password = os.environ["SNOWFLAKE_PASSWORD"]
```

**`.env.example`** lives in git with placeholder values:

```
SNOWFLAKE_ACCOUNT=your-account.us-east-1
SNOWFLAKE_USER=your-user
SNOWFLAKE_PASSWORD=
SNOWFLAKE_PRIVATE_KEY_PATH=
SQLSERVER_USER=
SQLSERVER_PASSWORD=
```

**Production:** A real secrets manager (AWS Secrets Manager, Azure Key Vault, HashiCorp Vault). **Never `.env` in production.** Production code reads from the secrets manager at startup.

**Snowflake specifically:** prefer **key-pair authentication** over passwords for service accounts. Passwords end up in shell history, log lines, and process listings; private keys can be loaded from a file readable only by the service user.

## Where secrets may NOT appear

| Place | Why |
|---|---|
| Source code | Anyone with repo read access sees them; git history keeps them forever |
| `.env.example` | This file IS committed — values must be empty placeholders |
| Log lines | Logs aggregate to shared systems, often viewable by more people than code |
| Error messages and tracebacks | Frameworks sometimes echo the failing input; sanitize before raising |
| URLs in browser history / docs | Connection strings with embedded passwords leak via screen-shares |
| Command-line arguments | Visible in `ps`, in shell history, in process accounting |
| Slack messages, JIRA tickets, Confluence pages | Indexed and searchable across the org |

## BCP password handling — the easy footgun

BCP is a command-line tool, so credentials passed as `-P <password>` show up in:
- `ps aux` output
- Shell history (`~/.bash_history`, `~/.zsh_history`)
- Subprocess error messages if the command fails
- Audit logs on the host

**The fix:** use the `-T` flag for trusted (Windows integrated) auth where possible, or set the password in an environment variable and let BCP pick it up.

```python
# WRONG — password on command line
subprocess.run(["bcp", table, "out", path, "-S", server, "-U", user, "-P", password])

# RIGHT — env var, no password in argv
env = os.environ.copy()
env["BCP_PASSWORD"] = os.environ["SQLSERVER_PASSWORD"]
subprocess.run(
    ["bcp", table, "out", path, "-S", server, "-U", user],
    env=env,
    check=True,
    capture_output=True,
)
```

Also: **never use `shell=True`** with subprocess. It opens command injection if any argument comes from outside.

## PII in logs — masking patterns

Log row counts and schema-level facts. Never log row contents.

```python
# WRONG — leaks PII into log aggregator
logger.info(f"loaded member: {member_dict}")
logger.info(f"first row: {df.head(1)}")

# RIGHT — log shape, not contents
logger.info("loaded %d members into acct.members_scd2", df.height)
logger.info("schema: %s", df.schema)
```

If you absolutely need to log a value for debugging, mask it:

```python
def mask(s: str, keep: int = 4) -> str:
    """Mask a string, keeping only the last `keep` characters."""
    if not s:
        return ""
    return "*" * max(0, len(s) - keep) + s[-keep:]

logger.debug("processing account ending in %s", mask(account_number))
```

## PII in data files — local hygiene

Data files (CSV, Parquet, XLSX, BCP `.dat`) routinely contain raw PII. Rules:

1. **`.gitignore` covers all data extensions** — see github-repo-hygiene skill.
2. **Local data goes in a single ignored directory** (`data/`, `samples/`) — easier to clean up, easier to verify nothing leaked.
3. **Delete data files when done.** Don't let years of CSV exports accumulate on developer laptops.
4. **Test fixtures use synthetic data only** — generate fake names, fake account numbers, fake balances. Never copy a slice of real data into `tests/fixtures/`.
5. **Encrypt at rest** if a regulated dataset must persist locally — use full-disk encryption (FileVault on Mac, BitLocker on Windows) at minimum.

## PII in views and stored procedures

For views consumed by downstream non-data-eng users (BI, analysts, marketing):

- **Default to masked or aggregated.** Build a `*_VwMasked` variant alongside any view that exposes PII.
- **Use Snowflake dynamic data masking** for column-level masking based on role.
- **Document PII columns explicitly** in the SQL header (see code-documentation-standard skill).
- **Row-level security** for member data: analysts should only see members in their assigned segment, etc.

## Snowflake-specific PII patterns

- **Tagging:** apply Snowflake object tags (`PII = 'YES'`) to PII columns. Enables governance reporting.
- **Masking policies:** define once, apply via tag inheritance. A new column tagged `PII` automatically inherits the masking policy.
- **Access history:** Snowflake's `ACCESS_HISTORY` view tells you who queried PII columns when. Review it.
- **Time travel:** PII deletes don't actually delete for `DATA_RETENTION_TIME_IN_DAYS`. Plan accordingly for "right to be forgotten" requests.

## Pre-commit and CI guardrails

Every repo runs:

- **`detect-secrets`** pre-commit hook with a maintained `.secrets.baseline`. Catches credential-shaped strings (high-entropy tokens, AWS keys, private keys, etc.) before they hit the remote.
- **`ruff` rule `S` (bandit)** in CI — flags `subprocess` with `shell=True`, hardcoded passwords, etc.
- **GitHub Secret Scanning** at the repo level.

## Incident response — secret leak

When a secret hits a remote (or you suspect it has):

1. **Rotate the secret first.** Right now. Before anything else. Even a few minutes of exposure on a public repo is enough for automated scrapers to grab it.
2. **Audit access logs** for the leaked credential's identity. Look for unfamiliar IPs, unusual queries, off-hours activity.
3. **Notify the team** via the security channel with rotation status and exposure window.
4. **Clean history** with `git filter-repo` if the repo is public or shared widely. Coordinate the force-push — every collaborator must re-clone.
5. **Document** what happened, root cause, and the prevention change in Confluence.

**Order matters:** rotate first, clean history second. A pristine git history with a still-valid secret is a false sense of security.

## Incident response — PII leak

If raw PII has been written to an unexpected place (logs, a non-PII view, a public S3 bucket, an email):

1. **Stop the leak source.** Disable the log shipper, drop the view, revoke bucket access, recall the email.
2. **Quantify.** Which members, which fields, who has accessed the destination since the leak began?
3. **Engage compliance / legal immediately.** This is a regulated event with notification timelines (state breach laws, GLBA Safeguards Rule, NCUA guidance for credit unions).
4. **Remediate the destination.** Purge logs, drop the view, delete bucket contents.
5. **Patch the source** so it can't recur — code change, masking policy, role grant fix.
6. **Document** in an incident report; surface to the team in retro.

## What to do when applying this skill

Before writing or reviewing code that touches data:

1. Identify which columns are PII. Note them in the file header.
2. Identify how credentials are loaded. If hardcoded or argv-passed, fix before continuing.
3. Scan log statements for row-level data — replace with row-count or schema logs.
4. Verify `.gitignore` covers any data files that may land locally.
5. If shipping a new view to non-data-eng consumers, ensure it's masked or aggregated.

## What NOT to do

- Do not put credentials in source code, even temporarily. "I'll remove it before commit" fails reliably.
- Do not pass passwords as command-line arguments to BCP, sqlcmd, snowsql, or any CLI.
- Do not log full DataFrames, full result sets, or full member records.
- Do not copy production data into `tests/fixtures/`.
- Do not screenshot or paste connection strings into Slack, JIRA, or Confluence.
- Do not delay rotation after a leak to "investigate first." Rotate first, investigate second.
- Do not assume `--no-verify` on a commit is a harmless override — it's how secrets reach `main`.
