# master_opportunities — Schema Reference for New Data Loads
**Companion to WASEC_v6_1_RUNBOOK.md · schema snapshot taken 12 July 2026**

The V6.1 engine reads from `master_opportunities`. A new scrape must land in this table with the column names below, **spelled exactly** (PostgreSQL is case-sensitive for quoted names; use lowercase). Not all 50 columns matter equally — they fall into three groups.

---

## Group 1 — REQUIRED: the engine reads these (30 columns)

Leave any of these out and the engine either errors or silently mis-scores.

| Column | Type | Role in the engine |
|---|---|---|
| `opportunity_pk` | integer | Primary key. Must be unique. |
| `source_system` | text | Data-maturity logic (ICN Gateway / Water Corporation / Synergy are treated as current-detail sources). |
| `opportunity_source` | text | Data-maturity logic (matches on %planned% / %early% / %advertised% / %current%). |
| `opportunity_id` | text | Carried into outputs for traceability. |
| `title` | text | **Most important field.** Scoring, hard-goods suppression (exemptions are judged on the title only), duplicate key. |
| `opportunity_type` | text | Part of scored text. |
| `agency` | text | Context text + duplicate key. Kept OUT of procurement text so agency boilerplate can't contaminate object judgements. |
| `region` | text | Context text + outputs. |
| `category` | text | Part of scored text. |
| `open_date` / `publish_date` | text | Display-date fallbacks. |
| `close_date` | text | **Expiry judgement.** Must parse (see date formats below). |
| `estimated_release_date` | text | Early-advice detection + display fallback. |
| `description` | text | Core scored text. |
| `conditions_for_participation` | text | Scored text (barriers often live here). |
| `estimated_value` | text | Carried into outputs. |
| `contact_name` / `contact_role_team` / `contact_phone` / `contact_email` | text | Carried into outputs — this is what members act on. |
| `source_url` | text | Carried into outputs; the human-verification entry point. |
| `readiness_level` / `participation_barrier` / `notes` | text | Scored text. |
| `login_required` | text | **Login-wall routing.** Convention: exactly `'Yes'` for login-walled records, NULL otherwise. Any other value silently misses the queue. |
| `project_name` | text | Scored text. |
| `project_open_date` | text | Display fallback. |
| `project_close_date` | text | Second source for expiry judgement. |

## Group 2 — STRUCTURAL: keep, may be empty (3 columns)

`source_table`, `status`, `organisation_type`, `financial_year_scope`, `created_at` — not read by the engine, but part of the table shape. New loads may leave them NULL (`created_at` defaults are fine).

## Group 3 — LEGACY: do NOT populate for new data (17 columns)

These are score/review artifacts written back by the **old v5.x system**. The V6.1 engine ignores them completely — its results live in its own tables (`v6_1_scored_opportunities`, `v6_1_human_decisions`), never written back into master.

`action_date`, `date_type`, `region_clean`, `has_contact`, `opportunity_stage`, `social_relevance_score`, `social_relevance_reason`, `review_status`, `review_notes`, `social_relevance_score_v2`, `social_relevance_reason_v2`, `review_status_v2`, `final_decision`, `final_review_notes`, `deliverability_score`, `deliverability_reason`, `deliverability_status`

**For a new snapshot, leave all of these NULL.** They exist only so the June-2026 table remains an intact historical record. If the table is ever rebuilt from scratch, these 17 columns can be dropped entirely — the engine will not notice.

---

## Date formats the parser understands

`close_date` / `project_close_date` (and the display dates) must be in one of:

| Format | Example | Source it came from |
|---|---|---|
| ISO | `2026-07-09T14:00` or `2026-07-09` | AusTender |
| Slash | `2026/7/9 14:30` or `2026/7/9` | WA Tenders |
| English month | `9 Jul 2026` | ICN Gateway |

Anything else parses to NULL → the record becomes "No close date / verify" instead of expiring. Not an error, but a silent quality loss — if a new platform uses a new format (e.g. `09-07-2026`), add one branch to `v6_parse_date()` at the top of the engine.

## If the scraper's column names change

Do **not** edit the engine. Map at import time instead:

```sql
INSERT INTO master_opportunities (opportunity_pk, title, close_date, agency, ...)
SELECT row_number() OVER (), scraped_title, closing_date, issuing_agency, ...
FROM staging_new_scrape;
```

The engine's schema is the contract; the import step is where adaptation happens. This keeps one stable interface no matter how the scrapers evolve.

## Pre-flight check before running the engine

```sql
-- 1. Row count sane?
SELECT source_system, COUNT(*) FROM master_opportunities GROUP BY source_system;

-- 2. Dates parsing? (should be mostly non-null for tender platforms)
SELECT COUNT(*) AS total, COUNT(v6_parse_date(close_date)) AS close_dates_parsed
FROM master_opportunities;

-- 3. Login-wall convention intact?
SELECT login_required, COUNT(*) FROM master_opportunities GROUP BY login_required;
-- expect: 'Yes' and NULL only
```

If all three look right, run `wasec_filter_v6_1_COMPLETE.sql`.
