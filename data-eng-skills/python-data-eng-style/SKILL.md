---
name: python-data-eng-style
description: Use when writing or reviewing Python code for this team's data engineering pipelines — Polars dataframes, Snowflake loads, BCP (SQL Server bulk copy) exports, and SCD2 transforms. Defines tooling (ruff, mypy, uv), naming conventions, project layout, error handling, logging, testing, and patterns specific to Polars/Snowflake/BCP. Triggers when starting a new .py file, adding a Polars transform, calling Snowflake or BCP from Python, structuring a new repo, or reviewing Python style.
---

# Python Data Engineering Style

The team adopted Python in October 2025 — these conventions exist so we converge on one way of doing things while we're still new. Follow them on new code; refactor old code opportunistically when you're already touching it.

## Tooling — single source of truth

Every Python repo on this team uses:

| Tool | Use | Why |
|---|---|---|
| **Python 3.11+** | Runtime | Stable, fast, modern type syntax |
| **`uv`** | Dependency + venv manager | Replaces pip + venv + poetry; fast and `pyproject.toml`-native |
| **`ruff`** | Linter + formatter | Replaces black + flake8 + isort + pyupgrade in one tool |
| **`mypy`** | Static type checker | Catches data shape bugs before runtime |
| **`pytest`** | Test runner | Standard |
| **`pre-commit`** | Pre-commit hook runner | Enforces ruff, mypy, secret scanning before every commit |

**Setup commands** for a new repo:

```bash
uv init
uv add polars snowflake-connector-python python-dotenv
uv add --dev ruff mypy pytest pre-commit detect-secrets
uv run pre-commit install
```

## Project layout

```
my-pipeline/
├── pyproject.toml          # ruff + mypy config lives here
├── README.md
├── .env.example            # placeholder values; .env itself is git-ignored
├── .gitignore
├── .pre-commit-config.yaml
├── src/
│   └── my_pipeline/        # snake_case package name
│       ├── __init__.py
│       ├── pipelines/      # orchestration entry points
│       ├── transforms/     # pure Polars transforms (testable)
│       ├── io/             # Snowflake, BCP, file readers/writers
│       └── utils/          # logging, config, helpers
└── tests/
    ├── transforms/
    └── io/
```

Why `src/` layout: prevents accidentally importing the source tree directly from the repo root, forces a real install (`uv pip install -e .`), and makes test imports unambiguous.

## Naming conventions

| Item | Convention | Example |
|---|---|---|
| Modules / files | `snake_case.py` | `load_dna_accounts.py` |
| Packages / directories | `snake_case` | `my_pipeline/` |
| Classes | `PascalCase` | `SnowflakeLoader` |
| Functions, methods, variables | `snake_case` | `load_accounts()`, `row_count` |
| Constants | `UPPER_SNAKE_CASE` | `MAX_BATCH_SIZE = 50_000` |
| Private (module/class internal) | `_leading_underscore` | `_validate_schema()` |
| Type aliases | `PascalCase` | `RowDict = dict[str, Any]` |
| Polars DataFrame columns | `snake_case` | `member_id`, `effective_from` — matches SQL |

Match Polars column names to SQL column names so data flows through without renaming.

## Type hints — REQUIRED

Every function and method signature MUST have type hints, including the return type. This is non-negotiable: type hints are documentation that the type checker enforces.

```python
import polars as pl

def filter_active_members(df: pl.DataFrame, as_of: str) -> pl.DataFrame:
    return df.filter(pl.col("is_active") & (pl.col("effective_from") <= as_of))
```

For Polars: be explicit about `pl.DataFrame` vs `pl.LazyFrame` in signatures — they are not interchangeable and confusing them is the most common Polars bug.

## Polars-specific patterns

**Use lazy frames for anything > ~100MB.** Build the query plan with `pl.scan_*` / `lf.<ops>`, then `.collect()` once at the end. This lets Polars push filters and projections down.

```python
result = (
    pl.scan_parquet("data/accounts.parquet")
    .filter(pl.col("status") == "active")
    .select(["member_id", "balance", "effective_from"])
    .collect()
)
```

**Declare schemas explicitly for production loads.** Don't trust schema inference:

```python
schema = {"member_id": pl.Int64, "balance": pl.Float64, "effective_from": pl.Date}
df = pl.read_csv("input.csv", schema=schema)
```

**Don't use `print(df)` to inspect — use `df.head()`, `df.glimpse()`, or `df.describe()`** in development, and `logger.info(f"row_count={df.height}")` in production. Printing a full DataFrame in a production log can leak PII.

## Snowflake patterns

**Connection — never hard-code credentials.** Read from environment:

```python
import os
import snowflake.connector

conn = snowflake.connector.connect(
    account=os.environ["SNOWFLAKE_ACCOUNT"],
    user=os.environ["SNOWFLAKE_USER"],
    password=os.environ.get("SNOWFLAKE_PASSWORD"),  # or private_key for key-pair auth
    warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
    database=os.environ["SNOWFLAKE_DATABASE"],
    schema=os.environ["SNOWFLAKE_SCHEMA"],
)
```

**Prefer key-pair authentication over passwords** for service accounts. Passwords end up in shell history, log files, and process listings; private keys can be loaded directly.

**Always wrap loads in transactions and assert row counts before commit:**

```python
with conn.cursor() as cur:
    cur.execute("BEGIN")
    cur.execute("INSERT INTO acct.members_scd2 ...")
    inserted = cur.rowcount
    if inserted != expected_count:
        cur.execute("ROLLBACK")
        raise RuntimeError(f"row mismatch: expected {expected_count}, got {inserted}")
    cur.execute("COMMIT")
```

## SCD2 patterns

For Type 2 slowly-changing dimensions, every target table must have:

| Column | Type | Purpose |
|---|---|---|
| `effective_from` | `TIMESTAMP_NTZ` | When this version became active |
| `effective_to` | `TIMESTAMP_NTZ` (NULL = current) | When this version was superseded |
| `is_current` | `BOOLEAN` | Indexed flag for "give me the current row" queries |
| `record_hash` | `VARCHAR(64)` | SHA-256 of business-key + tracked attributes; powers change detection |

The change-detection pattern: hash the tracked columns, compare to the current row's hash, and only insert a new version when the hash changes. Never use `UPDATE` to mutate history — always close the prior row (set `effective_to`, `is_current = false`) and `INSERT` a new one.

## BCP patterns (SQL Server bulk copy)

`bcp` is a command-line tool, which means **password handling is a footgun**. Two rules:

**1. Never pass passwords on the command line.** They show up in `ps`, in shell history, and in subprocess error messages. Use a connection file or environment variable.

```python
import os
import subprocess

env = os.environ.copy()
env["BCP_PASSWORD"] = os.environ["SQLSERVER_PASSWORD"]

result = subprocess.run(
    ["bcp", "acct.members", "out", "members.dat", "-S", server, "-U", user, "-T"],
    env=env,
    check=True,
    capture_output=True,
    text=True,
)
```

**2. Never use `shell=True` with any user-supplied input.** This is a command injection vector. Always pass `subprocess.run` a list of arguments, not a string.

After every BCP load, validate the row count against the source — BCP failures can be silent.

## Logging — `logging`, not `print`

Production code uses the standard `logging` module. `print` statements are for one-off scripts only.

```python
import logging
logger = logging.getLogger(__name__)

logger.info("loaded %d rows into acct.members_scd2", row_count)
logger.warning("schema drift detected: new column %r in source", new_col)
logger.exception("snowflake load failed")  # includes traceback
```

**Never log secrets or full DataFrames.** Log row counts, schema names, JIRA keys, timing — not contents.

## Error handling

- **Catch specific exceptions**, not bare `except:` or `except Exception:` (unless re-raising).
- **Log, then re-raise** — don't swallow errors silently. Pipeline failures must surface.
- **Fail loudly on data contract violations.** A wrong column count, missing column, or unexpected null is an error, not a warning.

```python
if df.height == 0:
    raise ValueError("source returned zero rows — refusing to load")
```

## Testing

- Tests live in `tests/`, mirroring `src/<package>/` structure.
- **Pure transforms** (no I/O) get unit tests with small synthetic Polars DataFrames — fast, deterministic.
- **I/O code** (Snowflake, BCP) gets integration tests against a dedicated test schema — never prod.
- Use `pytest` fixtures for connection setup; mark integration tests with `@pytest.mark.integration` so they can be skipped in pre-commit.

## What NOT to do

- Do not commit `.env` files. Ever. Pre-commit hook should block this.
- Do not `print` DataFrames or connection strings in production code.
- Do not use `shell=True` with `subprocess`.
- Do not use bare `except:`.
- Do not pass database passwords as command-line arguments to `bcp`, `sqlcmd`, etc.
- Do not write to production schemas from a script that hasn't been code-reviewed and merged.
- Do not skip type hints "because it's a quick script" — they cost ~10 seconds and prevent real bugs.
