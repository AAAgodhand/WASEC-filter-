# WASEC Procurement Lead Filter — V6.1 Runbook

**Purpose:** turn a fresh scrape of procurement opportunities into a short, prioritised review queue for WASEC members.
**Engine:** `wasec_filter_v6_1_COMPLETE.sql` (one file, safely re-runnable).
**Last verified run:** 11 July 2026 · 687 records → 48-row human queue.

---

## 1. Prerequisites

| Object | What it must contain |
|---|---|
| `master_opportunities` | The scraped opportunities. Same 50-column schema as the June 2026 snapshot. Critical columns: `title`, `agency`, `description`, `close_date`, `opportunity_source`, `source_system`, `login_required`, `source_url`, contact fields. |
| `member_capabilities` | One row per WASEC member (currently 79) with `member_name`, `statewide`, and `capability_categories` — semicolon-separated labels drawn from the **17 fixed categories** (see §5). |

PostgreSQL 13+; run in pgAdmin or psql.

## 2. Refresh procedure

1. Load the new scrape into `master_opportunities` (replace or append — the engine reads the whole table).
2. Open `wasec_filter_v6_1_COMPLETE.sql`, select all, execute (F5). Runs in seconds; every object is dropped and rebuilt, so re-running is always safe.
3. Read the **four reconciliation checks** printed at the end:
   - **Check 1** — immediate + monitor + excluded must equal the source total. If not, stop and investigate.
   - **Check 2** — per-rule catch counts. Sudden large changes deserve a look.
   - **Check 3** — the human queue composition by tier.
   - **Check 4** — must return zero rows (no record in two tables).
4. Export the queue: `SELECT * FROM v6_1_final_review_queue;` → pgAdmin download button → CSV.
5. **Human verification (mandatory — see §4).**
6. Generate the shareable web page from the exported CSV (needs only Python 3, nothing to install):
   `python build_web_view.py queue.csv web_view_<date>.html --date "15 September 2026"`
   The script builds the action cards from recorded human decisions and shows a "not yet verified" warning if none exist for the snapshot.

Expiry is judged against `CURRENT_DATE`, so the same data gives correct date verdicts whenever you run it.

## 3. Reading the queue

| Tier | Meaning | What to do |
|---|---|---|
| **H** — human verified | A person has checked the live page | Read the `human_decision` and `reason`; re-check status only |
| **A** — review first | Rule-scored practical warm lead | Verify, then circulate |
| **B / C** — review / specialist | Broad or specialist capability match | Verify each against the live page |
| **D** — manual triage | Mixed signals; rules can't decide | Human judgement required |
| **L** — login-wall | Detail behind an ICN login; unscoreable | `L1` rows: open with an ICN account and judge manually. `L3` rows: registration forms / prime-contractor programs — skim only |

## 4. Human verification is a pipeline stage, not optional QA

Evidence from this dataset: round 1 (9 Jul) changed **7 of 11** verdicts; round 2 (11 Jul) changed **3 of 5**. The things that changed them are invisible to every text rule:

- **Mandatory site briefings that already closed** — capability is irrelevant if the briefing was missed (PK 116, 127).
- **Alliance-/panel-only eligibility** (PK 108) and **credential gates** — e.g. TRA assessments require TRA-approved RTO status (PK 195).
- **Stale snapshot dates** — a package the site shows as closed carried a 2028 date in the data (PK 687).
- **Object ≠ title** — "Educational Welders" is welding *equipment*, not training (PK 129).

For each queue row: open `source_url`, confirm it is still open, look for mandatory briefings, eligibility/credential gates, and what is actually being bought. Record verdicts in `v6_1_human_decisions` (INSERT ... ON CONFLICT DO UPDATE — see `wasec_v6_1_round2_decisions_20260711.sql` as a template). **Decisions apply to this snapshot's `opportunity_pk` values only; a new scrape needs a fresh round.**

Note: Tenders WA and AusTender block automated access — verification means a person opening pages in a browser.

## 5. Maintaining member data

`member_capabilities.capability_categories` uses exactly these 17 labels (the crosswalk in the engine maps scoring terms onto them — **exact string equality**, so spelling matters):

`training / education / employment` · `product / goods supply` · `construction-adjacent / trades` · `community / wellbeing / care services` · `events / facilitation` · `consulting / research / evaluation` · `uncategorised - review` · `digital / website / data support` · `food / catering / laundry` · `waste / recycling / circular economy` · `disability / accessibility` · `housing / homelessness support` · `interpreting / translation / CALD` · `transport / logistics` · `aged care / home care services` · `financial capability / counselling` · `health / beauty / wellness pathways`

Members join/leave/change: edit rows in `member_capabilities`, re-run the engine. No code changes needed. If you add an 18th category, also add a crosswalk row in §5 of the engine (`v6_1_category_crosswalk`).

## 6. Known blind spots (do not assume the engine sees these)

1. **Mandatory briefings / eligibility gates** — undetectable from text. Human step only.
2. **ICN login-wall content** — 38 records in the June data. The engine routes the substantive ones to tier L1 instead of silently dropping them, but a person with an ICN account must read them. *(WASEC should hold an institutional ICN Gateway account — raise with the supervisor if access is missing.)*
3. **`matched_members` is indicative, not reliable.** Broad service words ("research", "maintenance") appearing incidentally still inflate matches (e.g. a laboratory panel matching radio stations). Use it as a starting hint; never circulate it to members without human confirmation.
4. **Keyword scoring cannot see value that isn't in the text.** A bare noun-phrase title with a login-walled description scores zero regardless of its real worth — that is why tier L exists.

## 7. Rule-change discipline

Rules changed only on repeated evidence, never a single example. Each rule in the engine carries its evidence in comments. Before adding a rule: gather the instances, check what a candidate pattern would also catch (run it as a SELECT first), and protect known-good records (46 fodder, 164 meals, 168 towage were the protected set for the hard-goods rule).

## 8. File inventory

| File | Role |
|---|---|
| `wasec_filter_v6_1_COMPLETE.sql` | **The engine.** The only file needed for a refresh. |
| `WASEC_v6_1_RUNBOOK.md` | This document. |
| `wasec_v6_1_round2_decisions_20260711.sql` | Template for recording verification decisions. |
| `build_web_view.py` | **CSV → web page generator.** Turns the exported queue CSV into the shareable page — step 6 above. |
| `WASEC_warm_leads_v6_1_*.xlsx / .html` | Deliverables generated from the 11 Jul queue. |
| `wasec_v6_1_PART*.sql`, `*_RERUN_*, *_suppression*, *_inheritance*` etc. | Development history — superseded by COMPLETE; keep for audit only. |

## 9. Data acquisition (read before planning a refresh)

**The scraper code is not part of this package.** The June 2026 snapshot was collected with AI-assisted, ad-hoc scraping scripts that were not retained. This is less of a loss than it sounds — scrapers are the shortest-lived part of any pipeline (they break whenever a site changes) — but it means a refresh starts with rebuilding collection, not just re-running it.

What you need to rebuild it is already in this package:

- **What to collect:** the four platforms — WA Tenders (tenders.wa.gov.au), AusTender (tenders.gov.au), ICN Gateway (gateway.icn.org.au), GTE — plus any new platforms worth adding.
- **Which fields:** the 30 required columns in `WASEC_master_opportunities_schema.md` are the scraper's requirements specification. Land those columns (via an import mapping if names differ) and the engine works unchanged.
- **Known obstacles, from experience:** WA Tenders disallows robots (scrape politely / consider manual export options); AusTender has bot detection; ICN work-package detail sits behind a login (capture `login_required = 'Yes'` for those — the engine routes them to the manual queue by design).
- **Date formats per platform** are documented in the schema file; keep them as-is and the parser handles them.

Any AI coding assistant can regenerate a scraper from this specification in an afternoon. The durable assets are the schema contract, the rules, and this documentation — the scraper is a replaceable part.

## 10. Database backup

The package's documentation describes the database; it does not contain it. A full backup made with pgAdmin (right-click database → Backup, Format: Custom) accompanies this folder as `wasec_database_backup_<date>.backup`. Restoring it (right-click → Restore) recreates everything: `master_opportunities` (687 rows), **`member_capabilities` (79 members — this table exists nowhere else)**, all v6_1 tables, and the 14 human verification decisions. Without the backup, the engine is a machine with no fuel.

**To restore (first-time setup on a new machine):**
1. Install PostgreSQL 13+ and open pgAdmin. Right-click *Databases* → *Create* → name it (e.g. `wasec`).
2. Right-click the new database → **Restore...** → Format: *Custom or tar* → select `wasec_handover_3tables_20260712.backup` → Restore.
3. Verify: `SELECT COUNT(*) FROM master_opportunities;` → 687 · `SELECT COUNT(*) FROM member_capabilities;` → 79 · `SELECT COUNT(*) FROM v6_1_human_decisions;` → 14.
4. Open `wasec_filter_v6_1_COMPLETE.sql`, select all, F5. This rebuilds every v6_1 table and view from the three restored tables. Read the four reconciliation checks at the end (expect 28 / 81 / 578 / 687 on the June data).
5. `SELECT * FROM v6_1_final_review_queue;` → the 48-row queue. You are now exactly where the project left off.
