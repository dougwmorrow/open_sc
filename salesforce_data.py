"""
Salesforce Data Extraction Pipeline
====================================
Connects to Salesforce via REST API and extracts object data to CSV/JSON.

Libraries Used:
    - simple-salesforce (v1.12+)  : Salesforce REST API client
    - pandas (v2.0+)              : Data manipulation and CSV/JSON export
    - requests (v2.31+)           : HTTP transport (dependency of simple-salesforce)
    - python-dotenv (v1.0+)       : Loads credentials from .env file

Network Requirements (for firewall/security review):
    ┌──────────────────────────────────────────────────────────────────────┐
    │  OUTBOUND HTTPS (TCP 443) — All connections are TLS 1.2+           │
    │                                                                      │
    │  1. login.salesforce.com        — OAuth2 / password authentication  │
    │  2. test.salesforce.com         — Sandbox authentication            │
    │  3. <instance>.salesforce.com   — REST API data queries             │
    │     (e.g. na1, eu5, ap15, etc.  — assigned after login)             │
    │  4. <mydomain>.my.salesforce.com — If org uses My Domain            │
    │                                                                      │
    │  No inbound connections required.                                    │
    └──────────────────────────────────────────────────────────────────────┘

Install:
    pip install simple-salesforce pandas python-dotenv
"""

import os
import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Optional

import pandas as pd
from dotenv import load_dotenv
from simple_salesforce import Salesforce, SalesforceAuthenticationFailed, SalesforceExpiredSession

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────

load_dotenv()  # reads from .env file

LOG_FORMAT = "%(asctime)s [%(levelname)s] %(message)s"
logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)
logger = logging.getLogger("sf_pipeline")

# Output directory for extracted data
OUTPUT_DIR = Path(os.getenv("SF_OUTPUT_DIR", "./output"))
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


# ──────────────────────────────────────────────
# Authentication
# ──────────────────────────────────────────────

def connect_to_salesforce(
    username: Optional[str] = None,
    password: Optional[str] = None,
    security_token: Optional[str] = None,
    domain: str = "login",            # "login" for prod, "test" for sandbox
    consumer_key: Optional[str] = None,
    consumer_secret: Optional[str] = None,
    instance_url: Optional[str] = None,
    session_id: Optional[str] = None,
) -> Salesforce:
    """
    Authenticate to Salesforce using one of the supported methods.

    Method 1 — Username + Password + Security Token (simplest):
        Requires: SF_USERNAME, SF_PASSWORD, SF_SECURITY_TOKEN env vars.

    Method 2 — OAuth2 Connected App (recommended for production):
        Requires: SF_CONSUMER_KEY, SF_CONSUMER_SECRET, SF_USERNAME, SF_PASSWORD env vars.

    Method 3 — Pre-existing Session (for SSO / external auth flows):
        Requires: SF_INSTANCE_URL, SF_SESSION_ID env vars.

    Network call:
        POST https://{domain}.salesforce.com/services/oauth2/token
        (returns an instance_url like https://na85.salesforce.com)
    """
    username       = username       or os.getenv("SF_USERNAME")
    password       = password       or os.getenv("SF_PASSWORD")
    security_token = security_token or os.getenv("SF_SECURITY_TOKEN", "")
    consumer_key   = consumer_key   or os.getenv("SF_CONSUMER_KEY")
    consumer_secret = consumer_secret or os.getenv("SF_CONSUMER_SECRET")
    instance_url   = instance_url   or os.getenv("SF_INSTANCE_URL")
    session_id     = session_id     or os.getenv("SF_SESSION_ID")
    domain         = os.getenv("SF_DOMAIN", domain)

    try:
        # Method 3: Pre-existing session
        if session_id and instance_url:
            logger.info("Authenticating with existing session ID")
            sf = Salesforce(instance_url=instance_url, session_id=session_id)

        # Method 2: OAuth2 Connected App
        elif consumer_key and consumer_secret:
            logger.info("Authenticating via OAuth2 Connected App (domain=%s)", domain)
            sf = Salesforce(
                username=username,
                password=password,
                consumer_key=consumer_key,
                consumer_secret=consumer_secret,
                domain=domain,
            )

        # Method 1: Username / Password / Token
        else:
            logger.info("Authenticating with username/password/token (domain=%s)", domain)
            sf = Salesforce(
                username=username,
                password=password,
                security_token=security_token,
                domain=domain,
            )

        logger.info("Connected — instance: %s", sf.sf_instance)
        return sf

    except SalesforceAuthenticationFailed as e:
        logger.error("Authentication failed: %s", e)
        raise


# ──────────────────────────────────────────────
# Data Extraction
# ──────────────────────────────────────────────

def run_soql_query(sf: Salesforce, soql: str) -> pd.DataFrame:
    """
    Execute a SOQL query and return results as a DataFrame.
    Handles automatic pagination (query_more) for large result sets.

    Network call:
        GET https://<instance>.salesforce.com/services/data/vXX.X/query?q=<SOQL>
    """
    logger.info("Executing SOQL: %s", soql[:120])
    result = sf.query_all(soql)
    records = result.get("records", [])

    if not records:
        logger.warning("Query returned 0 records.")
        return pd.DataFrame()

    df = pd.DataFrame(records).drop(columns=["attributes"], errors="ignore")
    logger.info("Fetched %d records", len(df))
    return df


def describe_object(sf: Salesforce, object_name: str) -> dict:
    """
    Retrieve metadata/schema for a Salesforce object.

    Network call:
        GET https://<instance>.salesforce.com/services/data/vXX.X/sobjects/<object>/describe
    """
    logger.info("Describing object: %s", object_name)
    sobject = getattr(sf, object_name)
    description = sobject.describe()
    fields = [
        {
            "name": f["name"],
            "label": f["label"],
            "type": f["type"],
            "length": f.get("length"),
            "nillable": f["nillable"],
        }
        for f in description["fields"]
    ]
    logger.info("Object '%s' has %d fields", object_name, len(fields))
    return {"name": object_name, "fields": fields}


def extract_object(
    sf: Salesforce,
    object_name: str,
    fields: Optional[list[str]] = None,
    where_clause: str = "",
    limit: Optional[int] = None,
) -> pd.DataFrame:
    """
    Extract all records (or a filtered subset) from a Salesforce object.

    Args:
        object_name : e.g. "Account", "Contact", "Opportunity"
        fields      : list of field API names; None = all queryable fields
        where_clause: e.g. "WHERE CreatedDate > 2024-01-01T00:00:00Z"
        limit       : max rows to fetch
    """
    # Auto-discover fields if not specified
    if fields is None:
        meta = describe_object(sf, object_name)
        fields = [f["name"] for f in meta["fields"]]

    field_list = ", ".join(fields)
    soql = f"SELECT {field_list} FROM {object_name}"
    if where_clause:
        soql += f" {where_clause}"
    if limit:
        soql += f" LIMIT {limit}"

    return run_soql_query(sf, soql)


# ──────────────────────────────────────────────
# Export
# ──────────────────────────────────────────────

def save_dataframe(df: pd.DataFrame, name: str, fmt: str = "csv") -> Path:
    """Save a DataFrame to CSV or JSON in the output directory."""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"{name}_{timestamp}.{fmt}"
    filepath = OUTPUT_DIR / filename

    if fmt == "csv":
        df.to_csv(filepath, index=False, encoding="utf-8")
    elif fmt == "json":
        df.to_json(filepath, orient="records", indent=2, force_ascii=False)
    else:
        raise ValueError(f"Unsupported format: {fmt}")

    logger.info("Saved %d rows → %s", len(df), filepath)
    return filepath


# ──────────────────────────────────────────────
# Pipeline Orchestrator
# ──────────────────────────────────────────────

# Define which objects/fields to extract.
# Edit this list to match your org's needs.
EXTRACTION_PLAN = [
    {
        "object": "Account",
        "fields": ["Id", "Name", "Industry", "BillingCity", "BillingCountry", "CreatedDate"],
        "where": "",
    },
    {
        "object": "Contact",
        "fields": ["Id", "FirstName", "LastName", "Email", "AccountId", "CreatedDate"],
        "where": "",
    },
    {
        "object": "Opportunity",
        "fields": ["Id", "Name", "StageName", "Amount", "CloseDate", "AccountId"],
        "where": "WHERE StageName != 'Closed Lost'",
    },
]


def run_pipeline(export_format: str = "csv"):
    """
    Main entry point.  Authenticates, extracts each object in the plan,
    and writes output files.
    """
    logger.info("=" * 60)
    logger.info("Salesforce Extraction Pipeline — started")
    logger.info("=" * 60)

    sf = connect_to_salesforce()

    for task in EXTRACTION_PLAN:
        obj_name = task["object"]
        logger.info("— Extracting: %s", obj_name)

        try:
            df = extract_object(
                sf,
                object_name=obj_name,
                fields=task.get("fields"),
                where_clause=task.get("where", ""),
                limit=task.get("limit"),
            )
            if not df.empty:
                save_dataframe(df, obj_name, fmt=export_format)
        except Exception:
            logger.exception("Failed to extract %s — skipping", obj_name)

    logger.info("Pipeline complete.")


# ──────────────────────────────────────────────
if __name__ == "__main__":
    run_pipeline(export_format="csv")
