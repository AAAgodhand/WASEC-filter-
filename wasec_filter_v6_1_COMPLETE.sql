-- ================================================================
-- WASEC PROCUREMENT LEAD FILTER — V6.1 COMPLETE
-- One-file, re-runnable pipeline: raw opportunities in,
-- prioritised human review queue out.
--
-- HOW TO RUN
--   1. Load fresh data into master_opportunities (same 50-col schema).
--   2. Ensure member_capabilities exists (79 members, 17 categories).
--   3. Open this file in pgAdmin, select all, F5. (~seconds)
--   4. Read the reconciliation checks at the bottom.
--   5. Export:  SELECT * FROM v6_1_final_review_queue;
--   6. MANDATORY: human live-URL verification of the queue before
--      anything is circulated to members. See the runbook.
--
-- Dates are judged against CURRENT_DATE — run it any day and
-- expiry is computed for that day.
--
-- VERSION LINEAGE (every rule below carries its evidence)
--   v5.4         original scoring engine (analyst's own)
--   v5.5         test-record & munitions exclusions
--   v5.6         B-group rules: agri R&D, duplicates, overseas,
--                school works, boilerplate guard
--   v5.7/5.7.1   procurement-object classifier; date guard
--   V6 draft     clean 3-layer design; 4 defects found in review
--   V6.1         defects fixed; all legacy rules inherited;
--                hard-goods suppression; exact member crosswalk;
--                login-wall fallback; human decision layer
-- ================================================================


-- ----------------------------------------------------------------
-- 0. CLEANUP (makes the whole file safely re-runnable)
-- ----------------------------------------------------------------
DROP VIEW  IF EXISTS v6_1_final_review_queue CASCADE;
DROP TABLE IF EXISTS v6_1_login_wall_queue CASCADE;
DROP TABLE IF EXISTS v6_1_human_decisions CASCADE;
DROP TABLE IF EXISTS final_immediate_review_leads_v6_1_m CASCADE;
DROP VIEW  IF EXISTS v6_1_member_summary CASCADE;
DROP VIEW  IF EXISTS v6_1_member_matches CASCADE;
DROP TABLE IF EXISTS v6_1_category_crosswalk CASCADE;
DROP TABLE IF EXISTS final_immediate_review_leads_v6_1 CASCADE;
DROP TABLE IF EXISTS final_monitor_relationship_leads_v6_1 CASCADE;
DROP TABLE IF EXISTS final_excluded_archived_v6_1 CASCADE;
DROP TABLE IF EXISTS v6_1_scored_opportunities CASCADE;
DROP VIEW  IF EXISTS v6_1_rule_matches CASCADE;
DROP TABLE IF EXISTS v6_1_rule_dictionary CASCADE;
DROP VIEW  IF EXISTS v6_1_base_text CASCADE;


-- ----------------------------------------------------------------
-- 1. DATE PARSER
--    Handles the three date formats in the data. Parse failure
--    returns NULL — better unjudged than misjudged.
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION v6_parse_date(s text)
RETURNS date AS $$
BEGIN
    IF s IS NULL OR btrim(s) = '' OR upper(btrim(s)) = 'NULL' THEN
        RETURN NULL;
    END IF;
    IF s ~ '^\d{4}-\d{2}-\d{2}' THEN                 -- ISO: 2026-07-09T14:00
        RETURN substring(s from 1 for 10)::date;
    END IF;
    IF s ~ '^\d{4}/\d{1,2}/\d{1,2}' THEN             -- WA Tenders: 2026/7/9 14:30
        RETURN to_date(split_part(s, ' ', 1), 'YYYY/MM/DD');
    END IF;
    IF s ~ '^\d{1,2} [A-Za-z]{3} \d{4}' THEN         -- ICN: 9 Jul 2026
        RETURN to_date(s, 'DD Mon YYYY');
    END IF;
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- ----------------------------------------------------------------
-- 2. BASE TEXT VIEW
--    procurement_content_text = the procurement itself (what is
--      being bought; barriers) — agency text EXCLUDED so ministerial
--      boilerplate cannot contaminate object/barrier judgements.
--    all_text = everything incl. agency/region — context signals only.
-- ----------------------------------------------------------------
CREATE VIEW v6_1_base_text AS
SELECT
    m.*,
    LOWER(CONCAT_WS(' ',
        COALESCE(m.title, ''), COALESCE(m.category, ''),
        COALESCE(m.opportunity_type, ''), COALESCE(m.description, ''),
        COALESCE(m.conditions_for_participation, ''),
        COALESCE(m.participation_barrier, ''),
        COALESCE(m.readiness_level, ''), COALESCE(m.notes, ''),
        COALESCE(m.project_name, '')
    )) AS procurement_content_text,
    LOWER(CONCAT_WS(' ',
        COALESCE(m.title, ''), COALESCE(m.category, ''),
        COALESCE(m.opportunity_type, ''), COALESCE(m.description, ''),
        COALESCE(m.conditions_for_participation, ''),
        COALESCE(m.participation_barrier, ''),
        COALESCE(m.readiness_level, ''), COALESCE(m.notes, ''),
        COALESCE(m.project_name, ''), COALESCE(m.agency, ''),
        COALESCE(m.region, ''), COALESCE(m.source_system, ''),
        COALESCE(m.opportunity_source, '')
    )) AS all_text,
    COALESCE(
        NULLIF(m.close_date, ''), NULLIF(m.estimated_release_date, ''),
        NULLIF(m.project_close_date, ''), NULLIF(m.project_open_date, ''),
        NULLIF(m.open_date, ''), NULLIF(m.publish_date, '')
    ) AS action_date_display,
    COALESCE(
        v6_parse_date(NULLIF(m.close_date, '')),
        v6_parse_date(NULLIF(m.project_close_date, ''))
    ) AS close_date_parsed
FROM master_opportunities m;


-- ----------------------------------------------------------------
-- 3. RULE DICTIONARY
--    Positive service terms / supporting context signals / barriers.
--    The construction-adjacent pattern already includes the PK-135
--    word forms (maintenance trade / trade panel / maintenance panel
--    / trades) — the gap that once dropped a statewide maintenance
--    panel to Low priority.
-- ----------------------------------------------------------------
CREATE TABLE v6_1_rule_dictionary (
    rule_group   TEXT,
    filter_term  TEXT,
    priority_level TEXT,
    score_weight INTEGER,
    match_pattern TEXT,
    notes        TEXT
);

INSERT INTO v6_1_rule_dictionary
(rule_group, filter_term, priority_level, score_weight, match_pattern, notes)
VALUES
('service_capability', 'training / education / workforce development', 'High', 40,
 '(training service|training program|training delivery|workforce development|career transition|employment service|job readiness|skills development|vocational training|learning and development|education resource|rto|registered training organisation)',
 'Direct service capability aligned with WASEC member profiles.'),
('service_capability', 'interpreting / translation / CALD services', 'High', 40,
 '(interpreting|translation|translator|interpreter|cald|culturally and linguistically diverse|auslan|aboriginal language)',
 'Clear service category, strong fit.'),
('service_capability', 'community support / wellbeing services', 'High', 40,
 '(community support|wellbeing service|community service|support service|family support|youth service|social support|case management)',
 'Broad social enterprise service capability.'),
('service_capability', 'disability support', 'High', 40,
 '(disability support|ndis|people with disability|accessibility service|supported employment)',
 'Common social enterprise capability and impact area.'),
('service_capability', 'aged care / home care / companionship', 'High', 40,
 '(aged care|home care|companionship|older people|seniors support|in-home support|my aged care)',
 'Added from supervisor feedback.'),
('service_capability', 'housing / homelessness / tenancy support', 'High', 40,
 '(housing support|homelessness service|crisis accommodation|transitional housing|tenancy support|short stay accommodation|affordable housing service)',
 'Housing as a service capability, not only a context signal.'),
('service_capability', 'employment services / career pathways', 'High', 35,
 '(employment pathway|employment services|career transition|job placement|work readiness|labour market program)',
 'Strong fit where procurement is about employment delivery.'),
('service_capability', 'events / conference / facilitation', 'Medium', 30,
 '(event management|conference organiser|professional conference organiser|pco|facilitation|workshop delivery|community event)',
 'Possible fit for some members; may need capacity review.'),
('service_capability', 'cleaning / facilities / grounds maintenance', 'Medium', 30,
 '(cleaning|facility services|facilities maintenance|grounds maintenance|gardening|landscaping|vegetation management|pest control)',
 'Practical category; site and compliance conditions matter.'),
('service_capability', 'waste / recycling / circular economy', 'Medium', 30,
 '(waste management|recycling|reuse|circular economy|upcycling|resource recovery|repurpose)',
 'Relevant to circular economy social enterprises.'),
('service_capability', 'transport / logistics / community transport', 'Medium', 30,
 '(community transport|transport service|courier|freight|logistics|delivery service|passenger transport)',
 'Added from supervisor feedback.'),
('service_capability', 'food services / catering', 'Medium', 30,
 '(catering|food service|meal service|kitchen|hospitality|food preparation)',
 'Common practical service category.'),
('service_capability', 'financial capability / financial counselling', 'Medium', 25,
 '(financial counselling|financial capability|financial literacy|no interest loan|nils|microfinance)',
 'Added from supervisor feedback.'),
('service_capability', 'digital / website / data support', 'Medium', 25,
 '(website|digital service|data support|database|crm|content management|digital platform support)',
 'Possible fit for specialist members; SaaS/platform builds need review.'),
('service_capability', 'research / evaluation / consulting', 'Medium', 25,
 '(research|evaluation|consulting|consultancy|survey|analysis|review|program evaluation)',
 'Specialist fit, not automatically broad fit.'),
('service_capability', 'arts / culture / public art', 'Medium', 25,
 '(public art|arts|culture|creative service|artist|cultural program)',
 'Relevant to some members.'),
('service_capability', 'health / beauty / wellness', 'Medium', 20,
 '(health and beauty|beauty training|hairdressing|barber|wellness program|wellness service)',
 'Added from supervisor feedback.'),
('service_capability', 'social enterprise product supply', 'Medium', 20,
 '(social enterprise product|upcycled product|recycled product|locally made product|produce|retail goods)',
 'Prevents product supply being automatically treated as unsuitable.'),
('service_capability', 'construction-adjacent trades / property maintenance', 'Medium', 22,
 '(property maintenance|building maintenance|repairs and maintenance|maintenance service|maintenance trade|maintenance panel|trade panel|painting service|minor works|handyman|fencing|landscaping works|grounds work|trade services|trades)',
 'Construction-adjacent trades deliverable by employment-focused members. Word forms include maintenance trade/panel (PK 135 lesson).'),
('context_signal', 'social procurement / supplier diversity', 'Supporting', 12,
 '(social procurement|supplier diversity|social enterprise|buy social|local supplier|local business|buy local)',
 'Buyer openness signal; useful for relationship leads.'),
('context_signal', 'Aboriginal / Indigenous / First Nations', 'Supporting', 12,
 '(aboriginal|indigenous|first nations|aboriginal business|indigenous business|first nations business)',
 'Important social procurement and impact signal.'),
('context_signal', 'disability / accessibility', 'Supporting', 10,
 '(disability|accessibility|accessible|ndis)', 'Social impact context signal.'),
('context_signal', 'mental health / wellbeing', 'Supporting', 10,
 '(mental health|wellbeing|wellness|trauma|psychosocial)', 'Social impact context signal.'),
('context_signal', 'housing / homelessness', 'Supporting', 10,
 '(homeless|homelessness|housing|affordable housing|crisis accommodation)', 'Social impact context signal.'),
('context_signal', 'CALD / refugee / multicultural', 'Supporting', 10,
 '(cald|refugee|multicultural|migrant|culturally and linguistically diverse)', 'Social impact context signal.'),
('context_signal', 'community need / vulnerable groups', 'Supporting', 8,
 '(vulnerable|hardship|community need|public benefit|social impact|community benefit|inclusion)',
 'General social impact signal.'),
('context_signal', 'environment / circular economy', 'Supporting', 8,
 '(environment|climate|sustainability|circular economy|recycling|waste reduction)',
 'Relevant where service capability also matches.'),
('context_signal', 'regional / remote WA', 'Supporting', 6,
 '(regional wa|remote wa|kimberley|pilbara|gascoyne|wheatbelt|goldfields|great southern|mid west|south west)',
 'Regional relevance signal.'),
('barrier', 'weapons / munitions procurement', 'High', -80,
 '(munitions|ammunition|weapon|missile|ordnance|explosive)',
 'Hard barrier. Supplier-diversity exemption applied in scoring.'),
('barrier', 'security / classified / defence restriction', 'High', -60,
 '(classified tender|security clearance|defence security|protected information|classified information)',
 'Likely high compliance barrier.'),
('barrier', 'major construction / civil / engineering design', 'High', -50,
 '(major construction|civil works|engineering design|building design|construction works|road works|bridge|asphalt|structural design)',
 'Usually high barrier; specialist labour/site services may be watched.'),
('barrier', 'generic equipment / vehicle / technical goods supply', 'Medium', -35,
 '(industrial equipment|medical equipment|laboratory equipment|vehicle|truck|radio equipment|technical equipment|supply of equipment|training boards)',
 'Down-rank generic equipment supply unless clear social-enterprise product/service fit.'),
('barrier', 'school / university infrastructure or equipment', 'Medium', -35,
 '(school|tafe|university|campus).{0,40}(roof|cooler|air.?conditioning|electrical works|mechanical works|refurbishment|building works|toilet block|carpark|car park|playground|shade sail|fit.?out)',
 'DEFECT-1 fix: works keyword must sit within 40 chars of the education word ("capacity building" no longer false-hits).'),
('barrier', 'specialist laboratory / scientific / certification services', 'Medium', -30,
 '(laboratory|scientific testing|certification service|iso 9001|accreditation|quality certification|technical testing)',
 'Specialist requirement; needs manual review.'),
('barrier', 'interstate or overseas delivery', 'Medium', -25,
 '(sydney|melbourne|brisbane|canberra|tasmania|northern territory|overseas|vanuatu|antarctic|nauru|papua new guinea)',
 'May be unreachable for WA members unless remote delivery is possible.'),
('barrier', 'medical school / accredited university requirement', 'Medium', -30,
 '(medical school|university medical student|accredited university|clinical credential|specialist health education)',
 'Often requires institutional accreditation.');


-- ----------------------------------------------------------------
-- 4. RULE MATCHES VIEW
--    service/barrier terms scan procurement content only;
--    context signals may scan all_text.
-- ----------------------------------------------------------------
CREATE VIEW v6_1_rule_matches AS
SELECT
    b.opportunity_pk, r.rule_group, r.filter_term,
    r.priority_level, r.score_weight, r.match_pattern
FROM v6_1_base_text b
JOIN v6_1_rule_dictionary r
    ON (CASE
            WHEN r.rule_group IN ('service_capability', 'barrier')
                THEN b.procurement_content_text ~ r.match_pattern
            ELSE b.all_text ~ r.match_pattern
        END);


-- ----------------------------------------------------------------
-- 5. CATEGORY CROSSWALK (member matching)
--    Hand-verified 1:1 mapping between V6.1 service terms and the
--    member_capabilities category labels. EXACT equality only —
--    a fuzzy first-word version once matched a patrol vessel to
--    36 social enterprises. Never reintroduce fuzzy matching here.
-- ----------------------------------------------------------------
CREATE TABLE v6_1_category_crosswalk (
    v6_service_term  TEXT,
    member_category  TEXT
);

INSERT INTO v6_1_category_crosswalk (v6_service_term, member_category) VALUES
('training / education / workforce development', 'training / education / employment'),
('employment services / career pathways',        'training / education / employment'),
('social enterprise product supply',             'product / goods supply'),
('construction-adjacent trades / property maintenance', 'construction-adjacent / trades'),
('community support / wellbeing services',       'community / wellbeing / care services'),
('events / conference / facilitation',           'events / facilitation'),
('research / evaluation / consulting',           'consulting / research / evaluation'),
('digital / website / data support',             'digital / website / data support'),
('food services / catering',                     'food / catering / laundry'),
('waste / recycling / circular economy',         'waste / recycling / circular economy'),
('disability support',                           'disability / accessibility'),
('housing / homelessness / tenancy support',     'housing / homelessness support'),
('interpreting / translation / CALD services',   'interpreting / translation / CALD'),
('transport / logistics / community transport',  'transport / logistics'),
('aged care / home care / companionship',        'aged care / home care services'),
('financial capability / financial counselling', 'financial capability / counselling'),
('health / beauty / wellness',                   'health / beauty / wellness pathways');


-- ----------------------------------------------------------------
-- 6. SCORING (the heart of the pipeline)
--    Every rule carries its evidence. Order of exclusions matters.
-- ----------------------------------------------------------------
CREATE TABLE v6_1_scored_opportunities AS
WITH agg AS (
    SELECT
        b.opportunity_pk,
        STRING_AGG(DISTINCT rm.filter_term, '; ')
            FILTER (WHERE rm.rule_group = 'service_capability') AS matched_service_terms,
        STRING_AGG(DISTINCT rm.filter_term, '; ')
            FILTER (WHERE rm.rule_group = 'context_signal') AS matched_context_signals,
        STRING_AGG(DISTINCT rm.filter_term, '; ')
            FILTER (WHERE rm.rule_group = 'barrier') AS matched_barrier_terms,
        COALESCE(SUM(rm.score_weight) FILTER (WHERE rm.rule_group = 'service_capability'), 0) AS service_raw_score,
        COALESCE(SUM(rm.score_weight) FILTER (WHERE rm.rule_group = 'context_signal'), 0)     AS context_raw_score,
        COALESCE(SUM(rm.score_weight) FILTER (WHERE rm.rule_group = 'barrier'), 0)            AS barrier_raw_score
    FROM v6_1_base_text b
    LEFT JOIN v6_1_rule_matches rm ON b.opportunity_pk = rm.opportunity_pk
    GROUP BY b.opportunity_pk
),

-- R3 duplicates (evidence: fire-station tender under two IDs).
-- Key = title + agency + close date. Title-only once wrongly merged
-- four distinct ICN EOIs sharing a generic title — keep all 3 parts.
dupes AS (
    SELECT
        opportunity_pk,
        ROW_NUMBER() OVER (
            PARTITION BY LOWER(TRIM(COALESCE(title,''))),
                         LOWER(TRIM(COALESCE(agency,''))),
                         COALESCE(close_date_parsed, DATE '1900-01-01')
            ORDER BY opportunity_pk
        ) AS dup_rank
    FROM v6_1_base_text
    WHERE COALESCE(title,'') <> ''
),

features AS (
    SELECT
        b.*,
        a.matched_service_terms, a.matched_context_signals, a.matched_barrier_terms,
        LEAST(60, a.service_raw_score) AS service_score,
        LEAST(20, a.context_raw_score) AS context_score,
        a.barrier_raw_score            AS barrier_score,
        (d.dup_rank > 1)               AS is_duplicate,

        CASE
            WHEN b.opportunity_source ILIKE '%planned%' THEN 'Planned summary only'
            WHEN b.opportunity_source ILIKE '%early%'
                 OR NULLIF(b.estimated_release_date, '') IS NOT NULL THEN 'Early advice'
            WHEN b.opportunity_source ILIKE '%advertised%'
                 OR b.opportunity_source ILIKE '%current%'
                 OR b.source_system IN ('ICN Gateway', 'Water Corporation', 'Synergy') THEN 'Current detailed opportunity'
            ELSE 'Other / unclear'
        END AS data_maturity,

        CASE
            WHEN b.close_date_parsed IS NULL THEN 'No close date / verify'
            WHEN b.close_date_parsed < CURRENT_DATE THEN 'Expired'
            WHEN b.close_date_parsed < CURRENT_DATE + INTERVAL '7 days' THEN 'Closing within 7 days'
            ELSE 'Open'
        END AS date_status,

        -- weapons + supplier-diversity exemption (v5.5/v5.7.2)
        (b.procurement_content_text ~ '(munitions|ammunition|weapon|missile|ordnance|explosive)'
         AND b.procurement_content_text !~ '(supplier list|supplier diversity|indigenous supplier|aboriginal supplier|first nations supplier|industry engagement)'
        ) AS has_hard_weapons_signal,

        -- R1 test/demo (evidence: Demo ATM, DEMOTENDER)
        (b.all_text ~ '(demo atm|demonstration atm|demotender|test elodgement|test tender|do not respond)'
        ) AS is_test_record,

        -- R2 agricultural R&D (evidence: 5 GRDC research notices)
        (b.all_text ~ '(grdc|grains research|grains rd|agricultural research|crop research|plant breeding|blight|botrytis|ascochyta|grey mould|disease resistance|nitrogen mission|agronomy trial|variety trial)'
        ) AS is_agri_research,

        -- R4 overseas (evidence: Vanuatu adviser, 2 Antarctic)
        (b.all_text ~ '(vanuatu|antarctic|antarctica|nauru|papua new guinea|solomon islands|timor|overseas post|offshore delivery|international development)'
        ) AS is_overseas,

        -- R5 interstate, with WA-guard (evidence: Sydney Harbour works)
        (b.procurement_content_text ~ '(sydney|melbourne|brisbane|adelaide|canberra|hobart|darwin|new south wales|victoria state|queensland|tasmania|northern territory)'
         AND b.procurement_content_text !~ '(western australia|perth|wa wide|statewide wa)'
        ) AS is_interstate,

        -- HARD-GOODS SUPPRESSION (evidence: 15-record audit, 11 true
        -- mis-hits incl. patrol vessels scored as training).
        -- Exemption judged on TITLE ONLY: full-text exemption once let
        -- a patrol vessel escape because its spec said "towing
        -- capacity". Title = procurement object; spec text is noise.
        (
            b.procurement_content_text ~ '(patrol vessel|charter vessel|vessels and trailers|welder|welding machine|shiploader|blast and paint|tilt tray|transmission truck|forklift|compressed system|kitchen chemicals|laundry chemicals|medical grade footwear|precision machining|elevated work platform|ewp equipment|fishery monitoring)'
            AND LOWER(COALESCE(b.title,'')) !~ '(meals|catering|food service|fodder|hay|produce|towage|towing|cleaning service|laundry service|uniform|upcycled|recycled)'
        ) AS has_hard_goods_signal,

        (b.procurement_content_text ~ '(industrial equipment|medical equipment|laboratory equipment|vehicle|truck|radio equipment|technical equipment|training boards|supply of equipment)'
        ) AS has_generic_equipment_signal,

        (b.procurement_content_text ~ '(social enterprise product|upcycled product|recycled product|locally made product|produce|retail goods)'
        ) AS has_social_product_signal,

        (b.procurement_content_text ~ '(major construction|civil works|engineering design|building design|road works|bridge|asphalt|structural design)'
        ) AS has_major_construction_signal,

        -- DEFECT-1 fix: distance-constrained school infra detector
        (b.procurement_content_text ~ '(school|tafe|university|campus).{0,40}(roof|cooler|air.?conditioning|electrical works|mechanical works|refurbishment|building works|toilet block|carpark|car park|playground|shade sail|fit.?out)'
        ) AS has_school_infra_signal,

        -- DEFECT-2 fix: school MINOR works => specialist, not excluded
        (b.procurement_content_text ~ '(school|primary school|education).{0,40}(upgrade|shade sail|playground|minor works|fencing|painting|carpark|car park|power upgrade)'
         AND b.procurement_content_text !~ '(major construction|civil works|structural design|engineering design)'
        ) AS has_school_minor_works_signal,

        -- R7 procurement-object classifier (v5.7)
        CASE
            WHEN b.procurement_content_text ~ '(design and construct|main works|civil works|major works|construction of|refurbishment of)'
                THEN 'works / construction'
            WHEN b.procurement_content_text ~ '(licensing|saas|software platform|system replacement|hosting platform|content management system|cyber security)'
                THEN 'platform / software'
            WHEN b.procurement_content_text ~ '(research program|r&d|breeding|scientific|modelling|business case|feasibility)'
                THEN 'consulting / research'
            WHEN b.procurement_content_text ~ '(supply of|supply and delivery)'
                THEN 'product / goods'
            WHEN b.procurement_content_text ~ '(provision of.*(service|support|care|program|package)|delivery of.*(service|program))'
                THEN 'service delivery'
            ELSE 'unclear - inspect'
        END AS procurement_object,

        -- R6 buyer openness read from PROCUREMENT CONTENT only
        -- (evidence: pest-control tender carried social signals from
        -- the agency's ministerial blurb; agency text is excluded here)
        (b.procurement_content_text ~ '(social procurement|supplier diversity|social enterprise|buy social|aboriginal business|indigenous business|first nations business|australian disability enterprise)'
        ) AS has_buyer_openness_signal

    FROM v6_1_base_text b
    JOIN agg   a ON b.opportunity_pk = a.opportunity_pk
    JOIN dupes d ON b.opportunity_pk = d.opportunity_pk
),

labels1 AS (
    SELECT
        *,
        CASE
            WHEN has_hard_weapons_signal THEN 'High barrier'
            WHEN has_major_construction_signal THEN 'High barrier'
            WHEN has_school_infra_signal AND NOT has_school_minor_works_signal THEN 'High barrier'
            WHEN has_school_minor_works_signal THEN 'Medium barrier'
            WHEN has_hard_goods_signal THEN 'Medium barrier'
            WHEN has_generic_equipment_signal AND NOT has_social_product_signal THEN 'Medium barrier'
            WHEN barrier_score <= -30 THEN 'Medium barrier'
            ELSE 'Low barrier'
        END AS barrier_level,

        -- capability fit: suppressions FIRST, so equipment cannot be
        -- rated a service fit no matter what words its spec contains
        CASE
            WHEN has_hard_goods_signal THEN 'Low fit'
            WHEN is_agri_research      THEN 'Low fit'
            WHEN has_school_minor_works_signal THEN 'Specialist fit'
            WHEN service_score >= 35
                 AND NOT has_generic_equipment_signal
                 AND NOT has_major_construction_signal
                 AND NOT has_school_infra_signal THEN 'Broad fit'
            WHEN service_score >= 25 THEN 'Specialist fit'
            WHEN service_score > 0 THEN 'Possible specialist fit'
            ELSE 'Low fit'
        END AS capability_fit,

        CASE
            WHEN matched_context_signals IS NULL THEN 'No clear social impact signal'
            WHEN matched_context_signals ~ '(social procurement|supplier diversity|aboriginal|indigenous|first nations)'
                THEN 'Yes - explicit social procurement signal'
            ELSE 'Possible - community or target-group signal'
        END AS social_impact_signal,

        CASE
            WHEN data_maturity = 'Current detailed opportunity' THEN 15
            WHEN data_maturity = 'Early advice' THEN 5
            WHEN data_maturity = 'Planned summary only' THEN -5
            ELSE 0
        END AS data_maturity_score
    FROM features
),

labels2 AS (
    SELECT
        *,
        service_score + context_score + barrier_score + data_maturity_score AS final_score_v6_1,
        (COALESCE(matched_context_signals,'') <> ''
         AND procurement_object IN ('platform / software', 'consulting / research', 'works / construction')
        ) AS has_object_context_conflict,
        CASE
            WHEN has_buyer_openness_signal AND service_score = 0
                THEN 'Buyer openness / relationship lead'
            WHEN data_maturity = 'Planned summary only'
                THEN 'Monitor future opportunity'
            WHEN capability_fit IN ('Broad fit', 'Specialist fit', 'Possible specialist fit')
                 AND barrier_level IN ('Low barrier', 'Medium barrier')
                THEN 'Direct procurement opportunity'
            ELSE 'Low fit or unclear'
        END AS lead_type
    FROM labels1
)

SELECT
    *,
    CASE
        WHEN is_test_record          THEN 'Archive - test / demo record'
        WHEN is_duplicate            THEN 'Archive - duplicate record'
        WHEN has_hard_weapons_signal THEN 'Archive / verify only'
        WHEN is_overseas             THEN 'Archive - overseas delivery'
        WHEN date_status = 'Expired' THEN 'Archive - expired'
        WHEN is_interstate           THEN 'Low priority - interstate delivery'
        WHEN is_agri_research        THEN 'Low priority - agricultural R&D'
        WHEN has_object_context_conflict THEN 'Low priority - object/context mismatch'
        WHEN lead_type = 'Buyer openness / relationship lead' THEN 'Monitor / relationship lead'
        WHEN data_maturity = 'Planned summary only' AND capability_fit <> 'Low fit'
            THEN 'Priority 3 - monitor future opportunity'
        WHEN barrier_level = 'High barrier' THEN 'Low priority - high barrier'
        WHEN data_maturity = 'Current detailed opportunity'
             AND capability_fit = 'Broad fit' AND barrier_level = 'Low barrier'
            THEN 'Priority 1 - practical warm lead'
        WHEN data_maturity IN ('Current detailed opportunity', 'Early advice')
             AND capability_fit IN ('Specialist fit', 'Possible specialist fit')
             AND barrier_level IN ('Low barrier', 'Medium barrier')
            THEN 'Priority 2 - specialist review'
        WHEN data_maturity IN ('Current detailed opportunity', 'Early advice')
             AND capability_fit = 'Broad fit' AND barrier_level = 'Medium barrier'
            THEN 'Priority 2 - review'
        WHEN capability_fit IN ('Broad fit', 'Specialist fit', 'Possible specialist fit')
            THEN 'Manual triage required'
        WHEN capability_fit <> 'Low fit' THEN 'Priority 3 - monitor future opportunity'
        ELSE 'Low priority'
    END AS priority_for_wasec,

    CONCAT_WS('; ',
        CASE WHEN is_test_record   THEN 'EXCLUDED: test/demo record' END,
        CASE WHEN is_duplicate     THEN 'EXCLUDED: duplicate (same title+agency+close date)' END,
        CASE WHEN is_overseas      THEN 'EXCLUDED: overseas delivery' END,
        CASE WHEN is_interstate    THEN 'DOWNGRADED: interstate delivery' END,
        CASE WHEN is_agri_research THEN 'DOWNGRADED: agricultural R&D program' END,
        CASE WHEN has_hard_goods_signal
            THEN 'SUPPRESSED: procurement object is hard equipment / industrial works' END,
        CASE WHEN has_object_context_conflict
            THEN 'DOWNGRADED: social language present but the object is ' || procurement_object END,
        CASE WHEN matched_service_terms IS NOT NULL
            THEN 'Service match: ' || matched_service_terms END,
        CASE WHEN matched_context_signals IS NOT NULL
            THEN 'Context signal: ' || matched_context_signals END,
        CASE WHEN matched_barrier_terms IS NOT NULL
            THEN 'Barrier signal: ' || matched_barrier_terms END,
        CASE WHEN date_status = 'Expired'
            THEN 'Closed relative to run date ' || CURRENT_DATE END,
        CASE WHEN has_school_minor_works_signal
            THEN 'School minor works — construction-adjacent specialist match' END,
        CASE WHEN has_buyer_openness_signal AND service_score = 0
            THEN 'Buyer open to social procurement, but no direct service match' END
    ) AS analyst_reason
FROM labels2;


-- ----------------------------------------------------------------
-- 7. OUTPUT TABLES (three disjoint sets that sum to the source)
-- ----------------------------------------------------------------
CREATE TABLE final_immediate_review_leads_v6_1 AS
SELECT opportunity_pk, priority_for_wasec, lead_type, capability_fit,
       barrier_level, data_maturity, date_status, social_impact_signal,
       procurement_object, final_score_v6_1,
       source_system, opportunity_source, opportunity_id,
       title, agency, region, category, action_date_display, estimated_value,
       contact_name, contact_role_team, contact_phone, contact_email,
       matched_service_terms, matched_context_signals, matched_barrier_terms,
       analyst_reason, source_url
FROM v6_1_scored_opportunities
WHERE priority_for_wasec IN (
    'Priority 1 - practical warm lead', 'Priority 2 - review',
    'Priority 2 - specialist review', 'Manual triage required')
ORDER BY
    CASE priority_for_wasec
        WHEN 'Priority 1 - practical warm lead' THEN 1
        WHEN 'Priority 2 - review' THEN 2
        WHEN 'Priority 2 - specialist review' THEN 3
        WHEN 'Manual triage required' THEN 4 ELSE 5 END,
    final_score_v6_1 DESC, action_date_display NULLS LAST;

CREATE TABLE final_monitor_relationship_leads_v6_1 AS
SELECT opportunity_pk, priority_for_wasec, lead_type, capability_fit,
       barrier_level, data_maturity, date_status, social_impact_signal,
       procurement_object, final_score_v6_1,
       source_system, opportunity_source, opportunity_id,
       title, agency, region, category, action_date_display, estimated_value,
       contact_name, contact_role_team, contact_phone, contact_email,
       matched_service_terms, matched_context_signals, matched_barrier_terms,
       analyst_reason, source_url
FROM v6_1_scored_opportunities
WHERE priority_for_wasec IN (
    'Monitor / relationship lead', 'Priority 3 - monitor future opportunity')
ORDER BY priority_for_wasec, final_score_v6_1 DESC, action_date_display NULLS LAST;

CREATE TABLE final_excluded_archived_v6_1 AS
SELECT opportunity_pk, priority_for_wasec, lead_type, capability_fit,
       barrier_level, data_maturity, date_status, social_impact_signal,
       procurement_object, final_score_v6_1,
       source_system, opportunity_source, opportunity_id,
       title, agency, region, category, action_date_display, estimated_value,
       matched_service_terms, matched_context_signals, matched_barrier_terms,
       analyst_reason, source_url
FROM v6_1_scored_opportunities
WHERE priority_for_wasec NOT IN (
    'Priority 1 - practical warm lead', 'Priority 2 - review',
    'Priority 2 - specialist review', 'Manual triage required',
    'Monitor / relationship lead', 'Priority 3 - monitor future opportunity')
ORDER BY priority_for_wasec, final_score_v6_1 DESC;


-- ----------------------------------------------------------------
-- 8. MEMBER MATCHING
--    Exact category intersection via the crosswalk. Suppressed
--    (Low fit) records get no member matches.
--    KNOWN LIMIT: still over-inclusive when a broad service word
--    (e.g. "research", "maintenance") appears incidentally in an
--    unrelated tender — treat matched_members as INDICATIVE ONLY;
--    verifiers must confirm real capability. Do not present this
--    column to members without human review.
-- ----------------------------------------------------------------
CREATE VIEW v6_1_member_matches AS
WITH opp_terms AS (
    SELECT s.opportunity_pk, TRIM(term) AS opp_term
    FROM v6_1_scored_opportunities s,
         LATERAL UNNEST(string_to_array(COALESCE(s.matched_service_terms, ''), ';')) AS term
    WHERE COALESCE(s.matched_service_terms, '') <> ''
      AND s.capability_fit <> 'Low fit'
),
opp_categories AS (
    SELECT DISTINCT o.opportunity_pk, c.member_category
    FROM opp_terms o
    JOIN v6_1_category_crosswalk c ON o.opp_term = c.v6_service_term
),
mem_categories AS (
    SELECT m.member_name, m.statewide, TRIM(cap) AS member_category
    FROM member_capabilities m,
         LATERAL UNNEST(string_to_array(COALESCE(m.capability_categories, ''), ';')) AS cap
    WHERE COALESCE(m.capability_categories, '') <> ''
)
SELECT DISTINCT oc.opportunity_pk, mc.member_name, mc.statewide
FROM opp_categories oc
JOIN mem_categories mc ON oc.member_category = mc.member_category;

CREATE VIEW v6_1_member_summary AS
SELECT opportunity_pk, COUNT(*) AS matched_member_count,
       STRING_AGG(member_name, '; ' ORDER BY member_name) AS matched_members
FROM v6_1_member_matches GROUP BY opportunity_pk;

CREATE TABLE final_immediate_review_leads_v6_1_m AS
SELECT i.*, COALESCE(ms.matched_member_count, 0) AS matched_member_count, ms.matched_members
FROM final_immediate_review_leads_v6_1 i
LEFT JOIN v6_1_member_summary ms ON i.opportunity_pk = ms.opportunity_pk
ORDER BY
    CASE i.priority_for_wasec
        WHEN 'Priority 1 - practical warm lead' THEN 1
        WHEN 'Priority 2 - review' THEN 2
        WHEN 'Priority 2 - specialist review' THEN 3
        WHEN 'Manual triage required' THEN 4 ELSE 5 END,
    matched_member_count DESC, i.final_score_v6_1 DESC;


-- ----------------------------------------------------------------
-- 9. HUMAN DECISION LAYER
--    Live-URL verification results. These OVERRIDE rule verdicts.
--    Round 1 = 9 Jul, Round 2 = 11 Jul 2026. When re-running on NEW
--    data these decisions apply to the SAME opportunity_pk values
--    only — new snapshots need their own verification round.
-- ----------------------------------------------------------------
CREATE TABLE v6_1_human_decisions (
    opportunity_pk   INTEGER PRIMARY KEY,
    decision         TEXT,
    decision_date    DATE,
    decision_source  TEXT,
    notes            TEXT
);

INSERT INTO v6_1_human_decisions
(opportunity_pk, decision, decision_date, decision_source, notes) VALUES
(135, 'Verified - PROCEED NOW', DATE '2026-07-11', 'live page content (round 2)',
 'RE-CONFIRMED open, closes 23 Jul 2026. Replaces LVMP+SA12 — panel entry gates future government maintenance orders. Category 1 (breakdown repairs, routine maintenance, simple projects) fits construction-adjacent members (Kardan, Renew). Stage 1: Perth Metro, Peel, South West, Great Southern. No mandatory briefing mentioned. ACTION: circulate to construction-adjacent members this week.'),
(195, 'Removed - credential barrier', DATE '2026-07-11', 'public AusTender search (round 2)',
 'TRA assessments must be delivered by TRA-approved RTOs (Migration Regulations 1994); national scope. No member holds that credential. Supersedes 9 Jul proceed verdict.'),
(155, 'HIGH-PRIORITY future opportunity', DATE '2026-07-11', 'live page content (round 2)',
 'Early Tender Advice: DoE principal wellbeing panel. RFT mid-2026, 5-year term, statewide. Three categories (leadership coaching / mental health support / executive health checks), tender per-category allowed. Fits ADHD WA, Mettle, Mens Talk, Reboot, Perth Kids Hub. ACTION: brief wellbeing members NOW.'),
(164, 'Future - monitor for August release', DATE '2026-07-11', 'live page content (round 2)',
 'Early Tender Advice; WACHS Midwest pre-prepared meals; request anticipated early Aug 2026. Catering members are the audience.'),
(168, 'Specialist monitor - higher barrier than scored', DATE '2026-07-11', 'live page content (round 2)',
 'Scope includes evidence capture, forensic storage, authorised release — police evidence chain, not simple towing. Needs licences + secure premises. Low priority.'),
(116, 'Conditional - briefing gate', DATE '2026-07-09', 'live URL check (round 1)',
 'Mandatory site briefing ALREADY CLOSED; only attendees may tender. This gate class is invisible to every text rule.'),
(127, 'Conditional - briefing gate', DATE '2026-07-09', 'live URL check (round 1)',
 'Mandatory briefing closed AND licensed electrical contractor required.'),
(673, 'Relationship / supplier qualification lead', DATE '2026-07-09', 'live URL check (round 1)',
 'Login-restricted supplier QUALIFICATION pathway, not a biddable tender. Keep as relationship lead for GreenChair / Goodwill Engineering.'),
(169, 'Monitor - early advice', DATE '2026-07-09', 'live URL check (round 1)',
 'Early tender advice only; fire-protection accreditation will be required.'),
(222, 'Specialist monitor', DATE '2026-07-09', 'live URL check (round 1)',
 '500-delegate interstate conference needs mature PCO capability; no current member fit.'),
(108, 'Removed - closed + alliance-restricted', DATE '2026-07-09', 'live URL check (round 1)',
 'Closed, and restricted to BMW Service Alliance contractors. Alliance-only eligibility is invisible to text rules.'),
(687, 'Removed - closed', DATE '2026-07-09', 'live URL check (round 1)',
 'ICN shows the package closed; the snapshot carried a stale 2028 date.'),
(129, 'Removed - object mismatch', DATE '2026-07-09', 'live URL check (round 1)',
 'Welding EQUIPMENT, not training services. Now also caught by hard-goods suppression.'),
(210, 'Removed - eligibility restricted', DATE '2026-07-09', 'live URL check (round 1)',
 'Open only to qualified private hospital providers.');


-- ----------------------------------------------------------------
-- 10. LOGIN-WALL FALLBACK
--     Records whose detail sits behind an ICN login: the scraped
--     text is a bare noun phrase, so NO text method can score them
--     (keyword scoring finds nothing; member matching intersects an
--     empty set). Route to a human queue instead of silently
--     dropping — PK 673 was nearly lost exactly this way.
--     Prioritised: substantive work packages first, admin noise last.
-- ----------------------------------------------------------------
CREATE TABLE v6_1_login_wall_queue AS
SELECT
    s.opportunity_pk,
    CASE
        WHEN LOWER(COALESCE(s.title,'')) ~ '(keep me updated|general expression of interest|supplier capability questionnaire|unspecified|open entry)'
            THEN 'L3 - administrative / registration form, not an opportunity'
        WHEN LOWER(COALESCE(s.title,'')) ~ '(moog|saab|global supply chain|global export)'
            THEN 'L3 - defence prime supplier program, not a work package'
        WHEN LOWER(COALESCE(s.title,'')) ~ '(civil works)'
            THEN 'L3 - known hard barrier (civil construction)'
        ELSE 'L1 - substantive work package, check this first'
    END AS login_wall_priority,
    'L - login-wall, needs manual check' AS review_tier,
    s.title, s.agency, s.region, s.source_system, s.date_status,
    s.action_date_display, s.estimated_value,
    s.contact_name, s.contact_phone, s.contact_email, s.source_url,
    CASE
        WHEN LOWER(COALESCE(s.title,'')) ~ '(keep me updated|general expression of interest|supplier capability questionnaire|unspecified|open entry|moog|saab|global supply chain|global export|civil works)'
            THEN 'Login-walled; title indicates a registration form, prime-contractor program, or known hard barrier. Low value for manual checking.'
        ELSE 'Login-walled work package: substantive scope in the title but no scraped description. Open the source URL with an ICN account, read the package scope, judge member fit directly. Absence of a score is NOT absence of value (the PK-673 lesson).'
    END AS analyst_reason
FROM v6_1_scored_opportunities s
JOIN master_opportunities m ON s.opportunity_pk = m.opportunity_pk
WHERE m.login_required = 'Yes'
  AND COALESCE(s.matched_service_terms, '') = ''
  AND NOT s.has_hard_weapons_signal
  AND s.date_status <> 'Expired'
ORDER BY 1;


-- ----------------------------------------------------------------
-- 11. FINAL REVIEW QUEUE — the single export source
--     Rule-scored leads + member info + login-wall queue + human
--     decisions merged. Human-verified records surface as tier H.
-- ----------------------------------------------------------------
CREATE VIEW v6_1_final_review_queue AS
SELECT
    m.opportunity_pk,
    CASE
        WHEN h.decision IS NOT NULL THEN 'H - human verified'
        WHEN m.priority_for_wasec = 'Priority 1 - practical warm lead' THEN 'A - review first'
        WHEN m.priority_for_wasec = 'Priority 2 - review'              THEN 'B - review'
        WHEN m.priority_for_wasec = 'Priority 2 - specialist review'   THEN 'C - specialist review'
        ELSE 'D - manual triage'
    END AS review_tier,
    m.priority_for_wasec, m.capability_fit, m.barrier_level,
    m.date_status, m.procurement_object, m.social_impact_signal,
    m.title, m.agency, m.region, m.category, m.action_date_display, m.estimated_value,
    m.contact_name, m.contact_phone, m.contact_email,
    m.matched_member_count, m.matched_members,
    h.decision AS human_decision, h.decision_date,
    COALESCE(h.notes, m.analyst_reason) AS reason,
    m.source_url
FROM final_immediate_review_leads_v6_1_m m
LEFT JOIN v6_1_human_decisions h ON m.opportunity_pk = h.opportunity_pk

UNION ALL

SELECT
    l.opportunity_pk, l.review_tier,
    l.login_wall_priority, 'Unknown - text empty', 'Unknown',
    l.date_status, 'unclear - login required', 'Unknown',
    l.title, l.agency, l.region, NULL::text AS category, l.action_date_display, l.estimated_value,
    l.contact_name, l.contact_phone, l.contact_email,
    0, NULL,
    h.decision, h.decision_date,
    COALESCE(h.notes, l.analyst_reason),
    l.source_url
FROM v6_1_login_wall_queue l
LEFT JOIN v6_1_human_decisions h ON l.opportunity_pk = h.opportunity_pk;


-- ================================================================
-- RECONCILIATION CHECKS — read these after every run
-- ================================================================

-- CHECK 1: the three output tables must sum to the source count
SELECT 'immediate' AS t, COUNT(*) FROM final_immediate_review_leads_v6_1
UNION ALL SELECT 'monitor',  COUNT(*) FROM final_monitor_relationship_leads_v6_1
UNION ALL SELECT 'excluded', COUNT(*) FROM final_excluded_archived_v6_1
UNION ALL SELECT 'SOURCE TOTAL', COUNT(*) FROM master_opportunities;

-- CHECK 2: what each exclusion rule caught this run
SELECT 'R1 test/demo' AS rule, COUNT(*) FROM v6_1_scored_opportunities WHERE is_test_record
UNION ALL SELECT 'R2 agri R&D',        COUNT(*) FROM v6_1_scored_opportunities WHERE is_agri_research
UNION ALL SELECT 'R3 duplicates',      COUNT(*) FROM v6_1_scored_opportunities WHERE is_duplicate
UNION ALL SELECT 'R4 overseas',        COUNT(*) FROM v6_1_scored_opportunities WHERE is_overseas
UNION ALL SELECT 'R5 interstate',      COUNT(*) FROM v6_1_scored_opportunities WHERE is_interstate
UNION ALL SELECT 'R7 object conflict', COUNT(*) FROM v6_1_scored_opportunities WHERE has_object_context_conflict
UNION ALL SELECT 'hard goods',         COUNT(*) FROM v6_1_scored_opportunities WHERE has_hard_goods_signal;

-- CHECK 3: queue composition (what a human needs to look at)
SELECT review_tier, COUNT(*) AS n
FROM v6_1_final_review_queue
GROUP BY review_tier ORDER BY review_tier;

-- CHECK 4: nothing in more than one output table (expect 0 rows)
SELECT opportunity_pk FROM final_immediate_review_leads_v6_1
INTERSECT SELECT opportunity_pk FROM final_monitor_relationship_leads_v6_1;

-- EXPORT (paste into a new query tab, then use pgAdmin's download):
-- SELECT * FROM v6_1_final_review_queue;
