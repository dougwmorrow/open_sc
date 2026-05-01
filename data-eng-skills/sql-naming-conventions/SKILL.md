---
name: sql-naming-conventions
description: Use when creating, naming, renaming, or reviewing SQL objects (schemas, tables, views, stored procedures, file names) in this team's SQL Server data warehouse. Defines mandatory schema namespaces (source-system schemas like dna/ccm/dmi/epicor/ecpm, domain schemas like acct/gl/membr/lc/risk, special schemas like dbo/ref/map/ops) and naming patterns for procs and views. Triggers when the user says "add a table", "create a view", "new stored procedure", "name this column", "which schema does this go in", or asks for a SQL file path.
---

# SQL Naming Conventions

This team's SQL Server warehouse uses **two kinds of schemas**: source-system schemas for raw landing through bronze layers, and domain schemas for curated data products. Every SQL object MUST live under exactly one schema from the lists below. If a new schema feels necessary, ask the team — do not create one ad hoc.

## Schema reference

### Source-system schemas — staging + bronze layers
All tables landing from a source system live under that system's schema. No cross-system tables in these schemas.

| Schema | Source system |
|---|---|
| `dna` | DNA core banking source system |
| `ccm` | CCM source system |
| `dmi` | DMI source system |
| `epicor` | Epicor source system |
| `ecpm` | Cloud EPM source system |
| `misc` | Source systems with no dedicated schema (e.g., BofA, Habitat) |

### Domain schemas — curated data products

| Schema | Domain | Includes |
|---|---|---|
| `acct` | Accounts & deposits | Savings, checking, CDs, money market, balances, activity, overdrafts, fees |
| `gl` | General Ledger | Core GL data |
| `membr` | Member & relationship | Onboarding, demographics, lifecycle, segmentation, NPS |
| `brnch` | Branch & sales operations | Branch performance, teller ops, facilities, operational efficiency |
| `lc` | Lending & credit | Mortgage, home equity, consumer lending, credit cards, origination, servicing, delinquency, charge-offs |
| `trans` | Payments & transactions | ACH, wire, bill pay, debit/credit transactions, P2P, ATM, branch transactions |
| `fin` | Finance, treasury & controller | GL, income/expense, ALM, liquidity & capital planning, investment portfolio |
| `mkt` | Marketing & campaigns | Campaign management, targeting, acquisition/retention, cross-sell, community engagement |
| `lend` | Lending & credit data product | Lending data product views/marts |
| `hr` | HR data product | Workforce planning, training, performance management |
| `mso` | Member service organization | MSO data product |
| `digital` | Digital banking & channel | Online banking, mobile, IVR, call center, chatbots, channel performance |
| `risk` | Risk & compliance | Credit risk, operational risk, BSA/AML, KYC, fraud, audit & controls |
| `call` | Operations / call center / member support | Call center & support data product |
| `it` | IT, data & technology | Data governance, quality & lineage, core banking, infra, cybersecurity |
| `strtgy` | Strategy & innovation | Product development, competitive intelligence, market research, innovation labs |

### Special schemas

| Schema | Use |
|---|---|
| `dbo` | Legacy (UDM 1.0). Also used for general-purpose stored procs, functions, tables that don't fit a domain. **Prefer a domain schema if one fits.** |
| `ref` | Cross-domain reference / lookup tables |
| `map` | Product mappings to help with joins (e.g., GL ↔ DNA Minor Code) |
| `ops` | Internal data pipeline operation events (run events, job metadata) |

## Object naming patterns

Stored procedures and views carry their schema name in their object name. This makes them grep-able and self-documenting.

| Object | Pattern | Example |
|---|---|---|
| Stored procedure | `{schema}_Proc{Name}` | `acct_ProcLoadDailyBalances`, `dna_ProcRefreshAccounts` |
| View | `{schema}_Vw{Name}` | `membr_VwActiveMembers`, `risk_VwBSAFlags` |
| SQL file name | Same as the object it defines | `acct_ProcLoadDailyBalances.sql`, `membr_VwActiveMembers.sql` |

**Casing:** schema is lowercase, the `Proc`/`Vw` token is PascalCase, the suffix is PascalCase. Keep names descriptive but compact.

## Decision rules when picking a schema

1. **Is the object loading raw data from a source system?** → Use the source-system schema (`dna`, `ccm`, etc.).
2. **Is it a curated data product or business view?** → Use the matching domain schema.
3. **Is it a lookup table referenced by multiple domains?** → Use `ref`.
4. **Is it a join-helper mapping table?** → Use `map`.
5. **Is it pipeline metadata (run logs, audit events)?** → Use `ops`.
6. **None of the above and it's truly cross-cutting utility code?** → `dbo`. Justify in the file header.

## What to do when applying this skill

When the user asks to create or name a SQL object:

1. Identify the right schema from the rules above. If two could apply, ask the user which fits.
2. Apply the `{schema}_Proc{Name}` or `{schema}_Vw{Name}` pattern.
3. Name the file identically to the object it defines.
4. If the user proposes a name that violates the pattern (e.g., `LoadAccounts.sql` with no schema prefix, or `acct.LoadAccounts` with a dot instead of underscore), call it out and propose the corrected name.
5. If a column name needs picking, prefer `snake_case` so it survives unmangled into Python/Polars downstream.

## What NOT to do

- Do not invent new schemas. Ask the team first.
- Do not put source-system raw tables under domain schemas.
- Do not put curated data products under source-system schemas.
- Do not omit the schema prefix from proc/view names — even if the object is in the same schema as everything else in the file.
- Do not use `dbo` as a default landing zone "until we figure out the right schema." Pick correctly the first time.
