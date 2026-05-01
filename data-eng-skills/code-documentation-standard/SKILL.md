---
name: code-documentation-standard
description: Use when authoring or reviewing module-level, file-level, function-level, or SQL-file documentation. Defines required header blocks for Python modules and SQL files (purpose, sources, sinks, schedule, owner, JIRA, Confluence link), Google-style docstrings on Python functions, and inline-comment guidance. Triggers when creating any new file, adding a new function or stored procedure, opening a code review where docs are missing, or asked "where should I document this".
---

# Code Documentation Standard

The team uses JIRA for tickets, Confluence for runbooks, and GitHub for code. This skill keeps the three linked: every code artifact points back to the JIRA ticket that justified it and the Confluence page that explains how to operate it.

The bar: a teammate who has never seen a file before should be able to read the header and answer **what does this do, who owns it, where do I learn more, who do I page if it breaks.**

## Python file headers

Every Python module that does real work (pipelines, transforms, I/O modules — not `__init__.py` or trivial utility) opens with a module docstring in this format:

```python
"""Load DNA member balances into acct.members_scd2 (daily SCD2 refresh).

Sources:
    - dna.member_accounts (SQL Server)
    - dna.balance_history (SQL Server)

Sinks:
    - acct.members_scd2 (Snowflake)

Schedule:
    Daily at 02:00 ET via Airflow DAG `acct_members_scd2_daily`.

Owner:
    @data-eng-team (primary: doug.morrow)

JIRA:
    DATA-1234 (initial build), DATA-1567 (added is_current flag)

Confluence:
    https://confluence.example.com/display/DATA/acct.members_scd2

PII:
    member_id (pseudonymous), date_of_birth (sensitive — masked in logs)
"""
```

Every field is required except `PII`, which is required only when the module touches PII columns.

## Python function docstrings — Google style

Every public function and method gets a docstring. Format:

```python
def load_scd2(
    source_df: pl.DataFrame,
    target_table: str,
    business_key: list[str],
    tracked_columns: list[str],
) -> int:
    """Apply SCD2 logic to load source_df into target_table.

    Compares incoming rows against the current version in target_table by
    hashing business_key + tracked_columns. New rows are inserted; changed
    rows close the prior version (set effective_to, is_current=false) and
    insert a new one. Unchanged rows are skipped.

    Args:
        source_df: Incoming snapshot. Must contain all business_key and
            tracked_columns. Must not contain effective_from/effective_to.
        target_table: Fully-qualified Snowflake table, e.g. "acct.members_scd2".
        business_key: Columns identifying a logical entity (e.g. ["member_id"]).
        tracked_columns: Columns whose changes should produce a new version.

    Returns:
        Number of new rows inserted.

    Raises:
        ValueError: If source_df is missing any required column.
        snowflake.connector.errors.ProgrammingError: On Snowflake failures.

    Side effects:
        Mutates target_table (transactional — rolled back on failure).
        Logs row counts at INFO level.
    """
```

**Skip the docstring** for trivial functions — one-line wrappers, simple property getters, or test fixtures. Don't waste space restating what a well-named function obviously does. The bar is "would a teammate need to read the body to know if this fits their need?" — if no, no docstring needed.

## SQL file headers

Every SQL file (stored procedure, view, table DDL) opens with a banner comment in this format:

```sql
/* ============================================================
   Object:        acct_ProcLoadDailyBalances
   Schema:        acct
   Type:          Stored Procedure
   Purpose:       Refresh daily account balance snapshot from
                  dna.balance_history into acct.daily_balances.

   Sources:       dna.balance_history, dna.member_accounts
   Sinks:         acct.daily_balances
   Refresh:       Daily at 02:00 ET (SQL Agent job: ACCT_DAILY_BALANCES)
   Dependencies:  dna_ProcRefreshAccounts must complete first.

   Owner:         @data-eng-team (primary: doug.morrow)
   JIRA:          DATA-1234
   Confluence:    https://confluence.example.com/display/DATA/acct.daily_balances

   Last updated:  2026-04-15 (DATA-1567 — added overdraft fee calc)
   ============================================================ */

CREATE OR ALTER PROCEDURE acct.acct_ProcLoadDailyBalances
AS
BEGIN
    ...
END
```

Every field is required. `Last updated` should be touched on every meaningful edit.

## Inline comments — what and what not

**Write a comment when:** the WHY is non-obvious. A workaround for a known bug, a hidden constraint from upstream, a specific business rule that won't be obvious from the code, the reason a "weird" join is correct.

```sql
-- Filter out test members (member_id < 1000 reserved for QA per DATA-987).
WHERE member_id >= 1000
```

```python
# Polars 0.20 drops nulls in pivot by default; explicit fill required for SCD2 hash stability.
df = df.fill_null("__NULL__")
```

**Do not write a comment when:** the code is self-evident, you're describing what the next line does in English, or you're narrating the change for a PR (that goes in the commit message).

## Confluence runbook expectation

Every pipeline (anything scheduled or triggered) must have a Confluence runbook page. The page covers:

1. **Purpose** — what this pipeline produces and why.
2. **Architecture diagram** — sources → transforms → sinks.
3. **Schedule** — when it runs, dependencies on other pipelines.
4. **On-call playbook** — common failure modes and how to recover (re-run command, manual catch-up steps).
5. **Data contracts** — schemas in/out, expected row count ranges.
6. **Change log** — JIRA tickets that have modified the pipeline.

The Python module header and the SQL file header link to this page via the `Confluence:` field. **The header in code should always be the entry point** — no teammate should ever have to grep Confluence to find the runbook for a piece of code.

## What to do when applying this skill

When creating or editing a file:

1. If the file is new, add the appropriate header block (Python module docstring or SQL banner) before writing any code.
2. If you're adding a new public function, write the Google-style docstring as you write the signature.
3. If editing an existing file, update `Last updated` (SQL) or extend the `JIRA:` line (Python) with the ticket driving the change.
4. If a pipeline doesn't have a Confluence runbook yet, flag that as a follow-up — don't ship the code without one.

## What NOT to do

- Do not write headers that say "TODO: fill in" — fill them in or don't add them.
- Do not write docstrings that just restate the function name.
- Do not put change history inline as comments — that's what `git log` is for. Only `Last updated` in SQL banners (because SQL has no commit-attached metadata when scripts are deployed via copy-paste).
- Do not skip the Confluence link "because there's no page yet" — create the stub page first, then link.
- Do not document private (`_underscored`) helpers unless they're tricky.
