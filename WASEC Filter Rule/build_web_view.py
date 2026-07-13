#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WASEC warm-leads web view generator
====================================
Turns the queue CSV exported from PostgreSQL into the shareable web page.

USAGE
  1. In pgAdmin run:   SELECT * FROM v6_1_final_review_queue;
  2. Click the download button in the results panel -> save as queue.csv
  3. In a terminal (any machine with Python 3.8+, nothing to install):

       python build_web_view.py queue.csv web_view.html --date "15 September 2026"

  4. Open web_view.html in a browser. Done.

The script expects the CSV columns produced by v6_1_final_review_queue
(see wasec_filter_v6_1_COMPLETE.sql, section 11). Extra columns are ignored,
so adding columns to the view later will not break this script.

Design notes for whoever maintains this:
  - Action cards at the top are generated from the human_decision column:
    PROCEED -> green card, HIGH-PRIORITY/Future -> blue, Removed/Conditional -> red.
    If the snapshot has no verification decisions yet, an amber warning card
    is shown instead, telling readers nothing has been verified.
  - The social-impact note is computed from the data: if no row carries an
    explicit social-procurement signal, the honest "none found" text is shown.
  - This page is a SNAPSHOT. The banner and footer both say so.
"""
import argparse, csv, html, sys
from datetime import date

# ---------- plain-language labels ----------
TIER_LABEL = {
    "H": ("Verified",         "We checked the live page ourselves"),
    "A": ("Top lead",         "Strong fit - check, then circulate"),
    "B": ("Broad match",      "Looks like a fit for several members - needs a check"),
    "C": ("Specialist match", "Fits a specific member specialty - needs a check"),
    "D": ("Needs judgement",  "Mixed signals - a person must decide"),
    "L1":("Check first",      "Real work package - needs an ICN login to read"),
    "L3":("Low value",        "Registration form or prime-contractor program - skim only"),
}

def esc(s): return html.escape(str(s).strip()) if s and str(s).strip().upper() not in ("NULL","NONE") else ""

def tier_key(row):
    t = (row.get("review_tier") or "").strip()
    if t.startswith("L"):
        p = (row.get("priority_for_wasec") or "")
        return "L3" if p.startswith("L3") else "L1"
    return t[:1] if t[:1] in "HABCD" else "D"

def clean_industry(cat, title, is_login_wall):
    """Turn a raw platform category string into a short readable label."""
    cat = (cat or "").strip()
    if not cat or cat.upper() == "NULL":
        if is_login_wall:
            return (title or "").split(" - ")[-1].strip()[:34] + " (ICN)" if title else ""
        return ""
    # pick the dominant segment when the string is "A - (80%) , B - (20%)"
    best, best_pct = None, -1
    for seg in cat.split(","):
        seg = seg.strip()
        pct = 0
        if "(" in seg and "%" in seg:
            try: pct = int(seg[seg.rindex("(")+1 : seg.rindex("%")])
            except ValueError: pct = 0
        name = seg.split(" - (")[0].strip()
        # strip leading UNSPSC codes like "72100000 - Building..."
        parts = name.split(" - ", 1)
        if parts[0].strip().isdigit() and len(parts) > 1:
            name = parts[1].strip()
        if pct >= best_pct and name:
            best, best_pct = name, pct
    return (best or "")[:44]

def verdict_badge(dec):
    if not dec: return ""
    d = dec.lower()
    if "proceed" in d:                       cls, label = "b-go",  "GO — act now"
    elif "high-priority" in d:               cls, label = "b-fut", "PREPARE — big future opportunity"
    elif "future" in d or "monitor" in d:    cls, label = "b-fut", "WATCH — " + dec.split("-")[-1].strip()
    elif "relationship" in d:                cls, label = "b-fut", "RELATIONSHIP — not a tender"
    elif "removed" in d or "conditional" in d: cls, label = "b-stop","REMOVED — " + dec.split("-")[-1].strip()
    else:                                    cls, label = "b-fut", dec
    return f'<span class="badge {cls}">{esc(label)}</span>'

def default_note(k):
    if k == "L1": return ("The details sit behind an ICN Gateway login, so they could not be read automatically. "
                          "Someone with an ICN account should open the link and judge whether a member could deliver this.")
    if k == "L3": return "A registration form or a big contractor's supplier program rather than a specific job - low priority."
    return ("Not yet verified. Before sending to any member: open the link, confirm it is still open, "
            "and look for mandatory briefings or licence requirements.")

def row_html(row):
    k   = tier_key(row)
    tl, tt = TIER_LABEL[k]
    pk  = esc(row.get("opportunity_pk"))
    ttl = esc(row.get("title")); ag = esc(row.get("agency"))
    url = esc(row.get("source_url"))
    close = esc(row.get("action_date_display")) or "&ndash;"
    ind = esc(clean_industry(row.get("category"), row.get("title"), k.startswith("L")))
    dec = (row.get("human_decision") or "").strip()
    note = esc((row.get("reason") or "").strip()) if dec else esc(default_note(k))
    mn  = (row.get("matched_member_count") or "0").strip()
    mems = f"{mn} possible fits" if mn not in ("", "0") else "&ndash;"
    contact = " · ".join(x for x in [esc(row.get("contact_name")), esc(row.get("contact_phone")), esc(row.get("contact_email"))] if x)
    ind_div = f'<div class="ind">{ind}</div>' if ind else ""
    return (f'<tr class="t-{k}"><td class="id" title="Internal reference number - matches the Excel/CSV export">{pk}</td>'
            f'<td class="tier" title="{esc(tt)}">{esc(tl)}</td>'
            f'<td class="title"><a href="{url}" target="_blank">{ttl}</a><div class="agency">{ag}</div>{ind_div}</td>'
            f'<td class="close">{close}</td>'
            f'<td>{verdict_badge(dec)}<div class="note">{note}</div></td>'
            f'<td class="mem" title="Automatic first guess - always confirm real capability before contacting a member">{mems}</td>'
            f'<td class="contact">{contact}</td></tr>')

def make_cards(rows):
    go, fut, stop = [], [], []
    for r in rows:
        d = (r.get("human_decision") or "").lower()
        pk, ttl = r.get("opportunity_pk"), (r.get("title") or "")[:60]
        if not d: continue
        if "proceed" in d: go.append((pk, ttl, r))
        elif "high-priority" in d or ("future" in d and "monitor" in d) or d.startswith("future"): fut.append((pk, ttl, r))
        elif "removed" in d or "conditional" in d: stop.append((pk, ttl, r))
    cards = []
    for pk, ttl, r in go[:2]:
        cards.append(f'<div class="card go"><h3>ACT NOW — lead {pk}</h3><p><b>{esc(ttl)}</b>. '
                     f'{esc((r.get("reason") or "")[:220])}</p></div>')
    for pk, ttl, r in fut[:2]:
        cards.append(f'<div class="card fut"><h3>PREPARE — lead {pk}</h3><p><b>{esc(ttl)}</b>. '
                     f'{esc((r.get("reason") or "")[:220])}</p></div>')
    if stop:
        ids = " · ".join(str(pk) for pk, _, _ in stop[:6])
        cards.append(f'<div class="card stop"><h3>REMOVED AFTER CHECKING</h3><p>Leads {esc(ids)} were checked '
                     f'and are not eligible or already closed. Please do not circulate these — details in the table.</p></div>')
    if not cards:
        cards.append('<div class="card stop"><h3>NOT YET VERIFIED</h3><p>No verification round has been recorded for '
                     'this snapshot. Every row below must be checked against its live source page before anything '
                     'is sent to a member.</p></div>')
    return "\n".join(cards)

def main():
    ap = argparse.ArgumentParser(description="Build the WASEC warm-leads web page from the queue CSV.")
    ap.add_argument("csv_in"); ap.add_argument("html_out")
    ap.add_argument("--date", default=str(date.today()), help='Snapshot label, e.g. "15 September 2026"')
    a = ap.parse_args()

    with open(a.csv_in, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit("CSV appears empty - export SELECT * FROM v6_1_final_review_queue and try again.")
    need = {"opportunity_pk","review_tier","title","source_url"}
    if not need.issubset(rows[0].keys()):
        sys.exit(f"CSV missing expected columns {need - set(rows[0].keys())} - "
                 "make sure you exported v6_1_final_review_queue with headers.")

    main_rows = [r for r in rows if not (r.get("review_tier") or "").startswith("L")]
    lwall     = [r for r in rows if (r.get("review_tier") or "").startswith("L")]
    order = {"H":0,"A":1,"B":2,"C":3,"D":4}
    main_rows.sort(key=lambda r:(order.get(tier_key(r),9), int(r.get("opportunity_pk") or 0)))
    lwall.sort(key=lambda r:(tier_key(r), int(r.get("opportunity_pk") or 0)))

    explicit = [r for r in rows if "explicit" in (r.get("social_impact_signal") or "").lower()]
    if explicit:
        ids = ", ".join(r["opportunity_pk"] for r in explicit)
        social_note = (f'<b>Social impact in contracts:</b> {len(explicit)} lead(s) carry an explicit '
                       f'social-procurement signal (IDs {esc(ids)}) — prioritise these.')
    else:
        social_note = ('<b>On "social impact" in contracts — an honest finding.</b> No opportunity in this snapshot '
                       'carried an explicit social-procurement clause (no mention of social enterprise, supplier '
                       'diversity, or buy-social requirements). Some contain community/wellbeing wording, but it '
                       'comes from the service category itself rather than a buyer requirement — so none are marked '
                       'as social-impact opportunities. The absence is itself useful intelligence.')

    total = len(rows)
    page = f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WASEC Warm Leads — verified list, {esc(a.date)}</title>
<style>
:root {{ --navy:#1F3864; --line:#e3e6eb; }} * {{ box-sizing:border-box; }}
body {{ font-family:Arial,Helvetica,sans-serif; margin:0; color:#20242c; background:#f7f8fa; }}
header {{ background:var(--navy); color:#fff; padding:24px 34px; }}
header h1 {{ margin:0 0 6px; font-size:22px; }} header p {{ margin:0; opacity:.85; font-size:13px; max-width:900px; }}
.stale {{ background:#8a2f2f; color:#fff; text-align:center; padding:7px 12px; font-size:12.5px; font-weight:bold; }}
.wrap {{ max-width:1280px; margin:0 auto; padding:22px 26px 60px; }}
.cards {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)); gap:14px; margin:18px 0 22px; }}
.card {{ background:#fff; border:1px solid var(--line); border-left:5px solid var(--navy); border-radius:8px; padding:14px 16px; }}
.card.go {{ border-left-color:#2e7d32; }} .card.fut {{ border-left-color:#1565c0; }} .card.stop {{ border-left-color:#b23b3b; }}
.card h3 {{ margin:0 0 6px; font-size:14px; color:var(--navy); }} .card p {{ margin:0; font-size:12.5px; line-height:1.5; }}
h2 {{ color:var(--navy); font-size:17px; margin:28px 0 4px; }} .sub {{ color:#666; font-size:12.5px; margin:0 0 10px; }}
table {{ width:100%; border-collapse:collapse; background:#fff; border:1px solid var(--line); font-size:12.5px; }}
th {{ background:var(--navy); color:#fff; text-align:left; padding:8px 10px; font-size:12px; position:sticky; top:0; }}
td {{ padding:9px 10px; border-top:1px solid var(--line); vertical-align:top; }}
tr.t-H {{ background:#fbfdf7; }}
td.id {{ font-weight:bold; color:#888; width:44px; }} td.tier {{ font-weight:bold; width:105px; color:var(--navy); font-size:11.5px; }}
td.title a {{ color:var(--navy); font-weight:bold; text-decoration:none; }} td.title a:hover {{ text-decoration:underline; }}
.agency {{ color:#777; font-size:11.5px; margin-top:3px; }}
.ind {{ display:inline-block; margin-top:5px; padding:1px 8px; background:#eef1f6; color:#44506b; border-radius:9px; font-size:10.5px; font-weight:bold; }}
td.close {{ white-space:nowrap; width:110px; }} td.mem {{ width:105px; color:#555; }} td.contact {{ width:185px; color:#555; font-size:11.5px; }}
.badge {{ display:inline-block; padding:2px 9px; border-radius:10px; font-size:11px; font-weight:bold; margin-bottom:5px; }}
.b-go {{ background:#c6efce; color:#1e5e26; }} .b-fut {{ background:#ddebf7; color:#174a7c; }} .b-stop {{ background:#f2dcdb; color:#8a2f2f; }}
.note {{ font-size:11.5px; color:#555; line-height:1.45; max-width:420px; }}
.legend {{ background:#fff; border:1px solid var(--line); border-radius:8px; padding:12px 16px; font-size:12px; color:#444; margin:0 0 14px; line-height:1.7; }}
.foot {{ margin-top:34px; font-size:12px; color:#666; border-top:1px solid var(--line); padding-top:14px; line-height:1.65; }}
</style></head><body>
<div class="stale">Snapshot dated {esc(a.date)} — deadlines in this list expire. Re-check any lead against its live page before acting.</div>
<header><h1>WASEC Warm Leads — verified list</h1>
<p>Collected opportunities were filtered for expiry, duplicates, location and suitability, leaving <b>{total}</b> leads for review. Rows marked <b>Verified</b> were checked against the live tender pages; all others need a check before circulation. Internal working document — not for direct distribution to members.</p></header>
<div class="wrap">
<div class="cards">
{make_cards(rows)}
</div>
<div class="legend"><b>How to read the columns:</b> &nbsp;<b>ID</b> = internal reference number (matches the CSV/Excel export). &nbsp;<b>Status</b> = the attention each lead needs — <i>Verified</i> means the live page was checked; others are the filter's assessment. &nbsp;<b>Finding</b> = what we know and what to do next. &nbsp;<b>Possible member fits</b> = an automatic first guess only. &nbsp;The grey pill under each agency is the <b>industry</b>.</div>
<div class="legend" style="border-left:4px solid #b23b3b;">{social_note}</div>
<h2>Leads for review ({len(main_rows)})</h2>
<p class="sub">Green rows are verified. For all others: open the link and check it is still open before sending to a member.</p>
<table><thead><tr><th>ID</th><th>Status</th><th>Opportunity</th><th>Closes / expected</th><th>Finding &amp; next step</th><th>Possible member fits</th><th>Official contact</th></tr></thead>
<tbody>{''.join(row_html(r) for r in main_rows)}</tbody></table>
<h2>Opportunities behind the ICN Gateway login ({len(lwall)})</h2>
<p class="sub">Details are only visible after logging in to ICN Gateway, so these could not be filtered automatically. <b>Check first</b> rows look like real work packages. An ICN account is needed to assess them.</p>
<table><thead><tr><th>ID</th><th>Status</th><th>Opportunity</th><th>Closes (as listed)</th><th>Finding &amp; next step</th><th>Possible member fits</th><th>ICN contact</th></tr></thead>
<tbody>{''.join(row_html(r) for r in lwall)}</tbody></table>
<div class="foot">
<b>How this list is made:</b> an automated filter removes expired, duplicate, overseas/interstate, research-programme and equipment-only tenders, then a person checks the shortlist against the live pages. Human checks routinely change verdicts — that is why unverified leads must be opened before they go to a member.<br>
<b>Refreshing:</b> this page was generated by <code>build_web_view.py</code> from the queue CSV. New data → run the engine → export the queue → run this script → new page. See the Runbook.<br>
<i>Generated {date.today().isoformat()} from {esc(a.csv_in)}.</i>
</div>
</div></body></html>"""
    with open(a.html_out, "w", encoding="utf-8") as f:
        f.write(page)
    print(f"OK: {a.html_out} written — {len(main_rows)} review leads + {len(lwall)} login-wall rows.")

if __name__ == "__main__":
    main()
