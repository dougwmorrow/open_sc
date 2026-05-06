"""
Jira Cloud metadata discovery.

Connects to your Jira instance and dumps everything you *could* extract:
  - All fields (system + custom) with IDs, types, and which schema they use
  - All projects
  - All issue types
  - All statuses (and their categories)
  - All priorities
  - All resolutions
  - All boards (if Jira Software is enabled)
  - One real sample issue with every field expanded, so you can see actual data shapes

Outputs:
  ./jira_metadata/fields.csv          <- the most useful file: field id -> name -> type
  ./jira_metadata/projects.csv
  ./jira_metadata/issue_types.csv
  ./jira_metadata/statuses.csv
  ./jira_metadata/priorities.csv
  ./jira_metadata/resolutions.csv
  ./jira_metadata/boards.csv
  ./jira_metadata/sample_issue.json   <- a real issue, all fields, for inspection
  ./jira_metadata/summary.txt         <- human-readable overview

Usage:
    pip install requests
    python jira_discover.py
"""

import os
import csv
import json
import base64
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


# --- Configuration ---------------------------------------------------------
JIRA_SITE   = os.getenv("JIRA_SITE",    "https://yoursite.atlassian.net")
JIRA_EMAIL  = os.getenv("JIRA_EMAIL",   "you@yourco.com")
JIRA_TOKEN  = os.getenv("JIRA_TOKEN",   "your-api-token-here")

# Optional: if set, we'll pull one sample issue from this project so you can
# see what real data looks like. Leave empty to skip.
SAMPLE_PROJECT = os.getenv("JIRA_PROJECT", "")

OUTPUT_DIR = Path("./jira_metadata")
# ---------------------------------------------------------------------------


def make_session() -> requests.Session:
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
        total=8, backoff_factor=2,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET", "POST"],
        respect_retry_after_header=True,
    )
    s.mount("https://", HTTPAdapter(max_retries=retry))
    return s


def get_json(session, path, params=None):
    """GET against the Jira site, return parsed JSON or None on 404."""
    url = f"{JIRA_SITE}{path}"
    r = session.get(url, params=params, timeout=30)
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return r.json()


def write_csv(path: Path, rows: list[dict], columns: list[str]) -> None:
    if not rows:
        return
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=columns, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


# --- Discovery functions ---------------------------------------------------

def discover_fields(session) -> list[dict]:
    """All fields available in this Jira — system + custom."""
    fields = get_json(session, "/rest/api/3/field") or []
    rows = []
    for f in fields:
        schema = f.get("schema") or {}
        rows.append({
            "id":            f.get("id"),
            "name":          f.get("name"),
            "custom":        f.get("custom"),
            "type":          schema.get("type"),
            "items":         schema.get("items"),         # for arrays: type of element
            "system":        schema.get("system"),
            "custom_schema": schema.get("custom"),        # custom field "kind" (e.g. select, sprint, gh-epic-link)
            "searchable":    f.get("searchable"),
            "navigable":     f.get("navigable"),
            "orderable":     f.get("orderable"),
        })
    rows.sort(key=lambda r: (not r["custom"], (r["name"] or "").lower()))
    return rows


def discover_projects(session) -> list[dict]:
    """All projects you can see."""
    projects, start = [], 0
    while True:
        page = get_json(session, "/rest/api/3/project/search",
                        params={"startAt": start, "maxResults": 50})
        if not page:
            break
        projects.extend(page.get("values", []))
        if page.get("isLast", True):
            break
        start += page.get("maxResults", 50)
    rows = [{
        "key":          p.get("key"),
        "id":           p.get("id"),
        "name":         p.get("name"),
        "project_type": p.get("projectTypeKey"),
        "style":        p.get("style"),                  # classic vs next-gen
        "lead":         (p.get("lead") or {}).get("displayName"),
        "simplified":   p.get("simplified"),
    } for p in projects]
    rows.sort(key=lambda r: r["key"] or "")
    return rows


def discover_issue_types(session) -> list[dict]:
    types = get_json(session, "/rest/api/3/issuetype") or []
    rows = [{
        "id":          t.get("id"),
        "name":        t.get("name"),
        "description": t.get("description"),
        "subtask":     t.get("subtask"),
        "hierarchy":   t.get("hierarchyLevel"),
    } for t in types]
    rows.sort(key=lambda r: (r["hierarchy"] is None, r["hierarchy"], r["name"] or ""))
    return rows


def discover_statuses(session) -> list[dict]:
    statuses = get_json(session, "/rest/api/3/status") or []
    rows = []
    for s in statuses:
        cat = s.get("statusCategory") or {}
        rows.append({
            "id":              s.get("id"),
            "name":            s.get("name"),
            "category_key":    cat.get("key"),     # new | indeterminate | done
            "category_name":   cat.get("name"),    # To Do | In Progress | Done
            "description":     s.get("description"),
        })
    rows.sort(key=lambda r: (r["category_key"] or "", r["name"] or ""))
    return rows


def discover_priorities(session) -> list[dict]:
    items = get_json(session, "/rest/api/3/priority") or []
    return [{"id": i.get("id"), "name": i.get("name"),
             "description": i.get("description")} for i in items]


def discover_resolutions(session) -> list[dict]:
    items = get_json(session, "/rest/api/3/resolution") or []
    return [{"id": i.get("id"), "name": i.get("name"),
             "description": i.get("description")} for i in items]


def discover_boards(session) -> list[dict]:
    """Agile boards. Returns [] if Jira Software / Agile API isn't available."""
    rows, start = [], 0
    while True:
        page = get_json(session, "/rest/agile/1.0/board",
                        params={"startAt": start, "maxResults": 50})
        if not page:
            break
        for b in page.get("values", []):
            loc = b.get("location") or {}
            rows.append({
                "id":           b.get("id"),
                "name":         b.get("name"),
                "type":         b.get("type"),         # scrum | kanban | simple
                "project_key":  loc.get("projectKey"),
                "project_name": loc.get("projectName"),
            })
        if page.get("isLast", True):
            break
        start += page.get("maxResults", 50)
    return rows


def fetch_sample_issue(session, project_key: str) -> dict | None:
    """Pull one real issue with every field expanded, so the user can see real data."""
    if not project_key:
        return None
    body = {
        "jql": f'project = "{project_key}" ORDER BY updated DESC',
        "fields": ["*all"],   # all fields (system + custom) the user has access to
        "maxResults": 1,
    }
    r = session.post(f"{JIRA_SITE}/rest/api/3/search/jql", json=body, timeout=30)
    r.raise_for_status()
    issues = r.json().get("issues", [])
    return issues[0] if issues else None


# --- Main ------------------------------------------------------------------

def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    session = make_session()

    # Auth check
    me = session.get(f"{JIRA_SITE}/rest/api/3/myself", timeout=15)
    if me.status_code == 401:
        raise SystemExit("Auth failed (401). Check JIRA_EMAIL and JIRA_TOKEN.")
    me.raise_for_status()
    print(f"Connected to {JIRA_SITE} as {me.json().get('displayName')}\n")

    # Discover everything
    print("Discovering fields...");      fields      = discover_fields(session)
    print("Discovering projects...");    projects    = discover_projects(session)
    print("Discovering issue types..."); issue_types = discover_issue_types(session)
    print("Discovering statuses...");    statuses    = discover_statuses(session)
    print("Discovering priorities..."); priorities  = discover_priorities(session)
    print("Discovering resolutions..."); resolutions = discover_resolutions(session)
    print("Discovering boards...");      boards      = discover_boards(session)

    sample = fetch_sample_issue(session, SAMPLE_PROJECT) if SAMPLE_PROJECT else None
    print()

    # Write CSVs
    write_csv(OUTPUT_DIR / "fields.csv",      fields,
              ["id", "name", "custom", "type", "items", "system", "custom_schema",
               "searchable", "navigable", "orderable"])
    write_csv(OUTPUT_DIR / "projects.csv",    projects,
              ["key", "id", "name", "project_type", "style", "lead", "simplified"])
    write_csv(OUTPUT_DIR / "issue_types.csv", issue_types,
              ["id", "name", "description", "subtask", "hierarchy"])
    write_csv(OUTPUT_DIR / "statuses.csv",    statuses,
              ["id", "name", "category_key", "category_name", "description"])
    write_csv(OUTPUT_DIR / "priorities.csv",  priorities,  ["id", "name", "description"])
    write_csv(OUTPUT_DIR / "resolutions.csv", resolutions, ["id", "name", "description"])
    write_csv(OUTPUT_DIR / "boards.csv",      boards,
              ["id", "name", "type", "project_key", "project_name"])

    if sample:
        (OUTPUT_DIR / "sample_issue.json").write_text(
            json.dumps(sample, indent=2), encoding="utf-8"
        )

    # Human-readable summary
    custom_fields = [f for f in fields if f["custom"]]
    summary_lines = [
        f"Jira site : {JIRA_SITE}",
        f"User      : {me.json().get('displayName')}",
        "",
        f"Fields      : {len(fields)} total ({len(custom_fields)} custom)",
        f"Projects    : {len(projects)}",
        f"Issue Types : {len(issue_types)}",
        f"Statuses    : {len(statuses)}",
        f"Priorities  : {len(priorities)}",
        f"Resolutions : {len(resolutions)}",
        f"Boards      : {len(boards)}",
        "",
        "--- Status categories on this instance ---",
    ]
    seen_cat = {}
    for s in statuses:
        seen_cat.setdefault(s["category_name"] or "?", []).append(s["name"])
    for cat, names in seen_cat.items():
        summary_lines.append(f"  {cat}: {', '.join(sorted(set(names)))}")

    summary_lines += ["", "--- Custom fields (most likely what you'll need to map) ---"]
    for f in custom_fields:
        summary_lines.append(
            f"  {f['id']:30s}  {f['name']:40s}  type={f['type']}"
        )

    summary_lines += ["", "--- Files written ---"]
    for p in sorted(OUTPUT_DIR.iterdir()):
        summary_lines.append(f"  {p}")

    summary_text = "\n".join(summary_lines)
    (OUTPUT_DIR / "summary.txt").write_text(summary_text, encoding="utf-8")

    print(summary_text)
    print("\nDone.")


if __name__ == "__main__":
    main()