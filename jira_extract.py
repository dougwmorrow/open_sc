"""
Simple Jira Cloud issue extractor.

Pulls issues for a project via the v3 /search/jql endpoint (the new cursor-
paginated one) and writes both raw JSON and a flat CSV.

Usage:
    1. Generate an API token at https://id.atlassian.com/manage-profile/security/api-tokens
    2. Set the four env vars below (or edit the defaults).
    3. python jira_extract.py

Dependencies:
    pip install requests
"""

import os
import csv
import json
import time
import base64
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


# --- Configuration ---------------------------------------------------------
# Set via environment variables OR replace the defaults below.
JIRA_SITE   = os.getenv("JIRA_SITE",    "https://yoursite.atlassian.net")
JIRA_EMAIL  = os.getenv("JIRA_EMAIL",   "you@yourco.com")
JIRA_TOKEN  = os.getenv("JIRA_TOKEN",   "your-api-token-here")
PROJECT_KEY = os.getenv("JIRA_PROJECT", "ABC")

# JQL — "current state of the board" = everything not Done, plus recently closed.
# Tweak this to whatever your team wants (e.g. a specific board's filter).
JQL = (
    f'project = "{PROJECT_KEY}" '
    f'AND (statusCategory != Done OR resolutiondate >= -30d) '
    f'ORDER BY updated ASC'
)

# Fields to pull. Story Points / Sprint are custom fields — their IDs vary
# per Jira instance. Run print_fields() once (see bottom) to discover yours.
FIELDS = [
    "summary", "status", "assignee", "reporter", "priority",
    "issuetype", "created", "updated", "resolutiondate", "resolution",
    "labels", "components", "fixVersions", "parent", "duedate",
    # "customfield_10016",   # Story Points (typical) — uncomment & adjust
    # "customfield_10020",   # Sprint (typical) — uncomment & adjust
]

OUTPUT_DIR = Path("./jira_output")
# ---------------------------------------------------------------------------


def make_session() -> requests.Session:
    """Build a requests Session with auth headers and automatic retry on 429/5xx."""
    s = requests.Session()
    auth = "Basic " + base64.b64encode(
        f"{JIRA_EMAIL}:{JIRA_TOKEN}".encode()
    ).decode()
    s.headers.update({
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Authorization": auth,
    })
    retry = Retry(
        total=8,
        backoff_factor=2,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET", "POST"],
        respect_retry_after_header=True,
    )
    s.mount("https://", HTTPAdapter(max_retries=retry))
    return s


def fetch_issues(session: requests.Session) -> list[dict]:
    """Walk the cursor-paginated /search/jql endpoint until done."""
    url = f"{JIRA_SITE}/rest/api/3/search/jql"
    body = {
        "jql": JQL,
        "fields": FIELDS,
        # 100 is the effective per-page cap whenever you request fields
        # other than id/key — Jira silently caps the response.
        "maxResults": 100,
    }
    issues: list[dict] = []
    page = 0
    while True:
        page += 1
        r = session.post(url, json=body, timeout=60)
        r.raise_for_status()
        data = r.json()
        batch = data.get("issues", [])
        issues.extend(batch)
        print(f"  page {page}: {len(batch):>4} issues  (total so far: {len(issues)})")

        next_token = data.get("nextPageToken")
        if not next_token or data.get("isLast"):
            break
        body["nextPageToken"] = next_token
        time.sleep(0.5)  # gentle pacing under burst limits
    return issues


def flatten(issue: dict) -> dict:
    """Reduce a Jira issue dict to a flat row suitable for CSV / a SQL table."""
    f = issue.get("fields", {}) or {}

    def _name(obj):     return obj.get("name") if isinstance(obj, dict) else None
    def _display(obj):  return obj.get("displayName") if isinstance(obj, dict) else None
    def _joined(items, key="name"):
        if not items:
            return ""
        return "; ".join(i.get(key, "") for i in items if isinstance(i, dict))

    status = f.get("status") or {}
    return {
        "key":             issue.get("key"),
        "id":              issue.get("id"),
        "summary":         f.get("summary"),
        "issue_type":      _name(f.get("issuetype")),
        "status":          status.get("name"),
        "status_category": (status.get("statusCategory") or {}).get("key"),
        "priority":        _name(f.get("priority")),
        "assignee":        _display(f.get("assignee")),
        "reporter":        _display(f.get("reporter")),
        "labels":          "; ".join(f.get("labels") or []),
        "components":      _joined(f.get("components")),
        "fix_versions":    _joined(f.get("fixVersions")),
        "parent_key":      (f.get("parent") or {}).get("key"),
        "created":         f.get("created"),
        "updated":         f.get("updated"),
        "resolution_date": f.get("resolutiondate"),
        "resolution":      _name(f.get("resolution")),
        "due_date":        f.get("duedate"),
    }


def save_outputs(issues: list[dict]) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Raw JSON — full fidelity for downstream/replay.
    raw_path = OUTPUT_DIR / "issues_raw.json"
    raw_path.write_text(json.dumps(issues, indent=2), encoding="utf-8")
    print(f"  wrote {raw_path}  ({len(issues)} issues)")

    # Flat CSV — Excel-friendly, easy to eyeball.
    rows = [flatten(i) for i in issues]
    csv_path = OUTPUT_DIR / "issues_flat.csv"
    if rows:
        with csv_path.open("w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        print(f"  wrote {csv_path}  ({len(rows)} rows)")


def print_fields(session: requests.Session) -> None:
    """One-time helper: print every field name + id. Run this to find custom field IDs."""
    r = session.get(f"{JIRA_SITE}/rest/api/3/field", timeout=30)
    r.raise_for_status()
    for fld in sorted(r.json(), key=lambda x: x["name"]):
        print(f"{fld['id']:30s}  {fld['name']}")


def main() -> None:
    print(f"Jira site : {JIRA_SITE}")
    print(f"Project   : {PROJECT_KEY}")
    print(f"JQL       : {JQL}\n")

    session = make_session()

    # Auth sanity check
    me = session.get(f"{JIRA_SITE}/rest/api/3/myself", timeout=15)
    if me.status_code == 401:
        raise SystemExit("Auth failed (401). Check JIRA_EMAIL and JIRA_TOKEN.")
    me.raise_for_status()
    print(f"Authenticated as: {me.json().get('displayName')}\n")

    print("Fetching issues...")
    issues = fetch_issues(session)
    print(f"\nTotal issues fetched: {len(issues)}\n")

    print("Saving outputs...")
    save_outputs(issues)
    print("Done.")


if __name__ == "__main__":
    # To discover custom field IDs (Story Points, Sprint, Epic Link, etc.),
    # comment out main() and uncomment these two lines, then run once:
    # print_fields(make_session())
    # raise SystemExit
    main()
