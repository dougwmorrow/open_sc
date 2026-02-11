# Salesforce Data Pipeline — Network & Security Requirements

## Purpose
Python pipeline running on internal infrastructure that authenticates to Salesforce and extracts CRM data (Accounts, Contacts, Opportunities) via the Salesforce REST API.

---

## Firewall Rules Required

All connections are **outbound only** over **HTTPS (TCP port 443, TLS 1.2+)**. No inbound rules are needed.

| # | Destination | Port | Protocol | Purpose |
|---|-------------|------|----------|---------|
| 1 | `login.salesforce.com` | 443 | HTTPS | OAuth2 authentication (Production orgs) |
| 2 | `test.salesforce.com` | 443 | HTTPS | OAuth2 authentication (Sandbox orgs) |
| 3 | `*.salesforce.com` | 443 | HTTPS | REST API data queries (instance is assigned dynamically after login, e.g. `na85.salesforce.com`, `eu5.salesforce.com`) |
| 4 | `*.my.salesforce.com` | 443 | HTTPS | Orgs using Salesforce "My Domain" (e.g. `acme.my.salesforce.com`) |
| 5 | `pypi.org` / `files.pythonhosted.org` | 443 | HTTPS | One-time: Python package installation via pip |

> **Note:** If a wildcard rule for `*.salesforce.com` is not acceptable, the specific instance hostname (e.g. `na85.salesforce.com`) can be determined after initial login and hardcoded. However, Salesforce may migrate orgs between instances, so the wildcard is recommended.

---

## Authentication Flow

```
┌────────────┐         ┌──────────────────────┐         ┌──────────────────────────┐
│  Pipeline   │──POST──▶│ login.salesforce.com │──200───▶│ Returns:                 │
│  (internal) │  443    │ /services/oauth2/    │         │  • access_token          │
│             │         │ token                │         │  • instance_url          │
└─────┬───── ┘         └──────────────────────┘         │    (e.g. na85.sf.com)    │
      │                                                  └──────────────────────────┘
      │
      │  GET https://<instance>.salesforce.com/services/data/vXX.X/query?q=...
      │
      ▼
┌──────────────────────────┐
│  <instance>.salesforce.com│  ◀── All subsequent API calls go here
│  (REST API — port 443)    │
└──────────────────────────┘
```

---

## Python Libraries

| Library | Version | Role | Network Access? |
|---------|---------|------|-----------------|
| `simple-salesforce` | ≥ 1.12 | Salesforce REST API client | Yes — connects to salesforce.com |
| `pandas` | ≥ 2.0 | Data manipulation, CSV/JSON export | No |
| `requests` | ≥ 2.31 | HTTP transport (dependency) | Yes — used by simple-salesforce |
| `python-dotenv` | ≥ 1.0 | Loads `.env` credentials file | No |

### Install command
```bash
pip install simple-salesforce pandas python-dotenv
```

---

## Data Flow Summary

```
Salesforce Org                    Internal Network
┌─────────────┐                  ┌──────────────────────────────┐
│             │   HTTPS/443      │                              │
│  REST API   │◀─────────────────│   Python Pipeline            │
│             │─────────────────▶│     │                        │
│             │  JSON responses  │     ▼                        │
└─────────────┘                  │   CSV/JSON files → ./output/ │
                                 │                              │
                                 └──────────────────────────────┘
```

- **Data at rest:** Extracted files stored locally as CSV or JSON.
- **Data in transit:** TLS 1.2+ encrypted (enforced by Salesforce).
- **Credentials:** Stored in `.env` file (not committed to source control).

---

## Salesforce IP Allowlisting (Optional)

If your Salesforce org has **Login IP Ranges** or **Trusted IP Ranges** configured, the outbound IP of the server running this pipeline must be added to those allowlists in Salesforce Setup. Coordinate with your Salesforce admin.

Salesforce publishes its own IP ranges here:
https://help.salesforce.com/s/articleView?id=000321501&type=1

---

## Credentials Needed from Salesforce Admin

| Item | Where to Get It |
|------|-----------------|
| Username | Salesforce user account with API access |
| Password | Account password |
| Security Token | Salesforce → Settings → "Reset My Security Token" |
| Connected App keys (optional) | Salesforce Setup → App Manager → New Connected App |

The Salesforce user must have the **"API Enabled"** permission in their Profile or Permission Set.
