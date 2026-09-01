/* ============================================================================
   Multi-Tier (Waterfall) Competitor Discovery for Site Selection
   PostgreSQL + PostGIS
   ----------------------------------------------------------------------------
   Problem:
     For every candidate site, return the 10 most relevant competitors.
     A single fixed radius does not work: in a dense metro a 3-mile buffer
     returns 40 competitors, while in a rural market it returns zero.

   Approach:
     Define 5 tiers, from strictest to loosest. Every tier runs for every site,
     the results are stacked with UNION ALL, deduplicated keeping the strongest
     tier a competitor qualified under, then ranked by (tier, distance).
     This guarantees up to 10 rows per site while preserving match quality.

   Worked example uses early-education centres, but nothing here is
   domain-specific: swap the attribute filters and it applies to any
   retail or service network.
   ============================================================================ */

-- Tunables -------------------------------------------------------------------
--   :brand_name   operator brand to exclude from the competitor set (our own)
--   Radii are metres, because the working CRS is metric:
--       4828.02 m =  3 miles
--       8046.72 m =  5 miles
--      16093.40 m = 10 miles
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS site_selection.candidate_site_competitors;

CREATE TABLE site_selection.candidate_site_competitors AS
WITH all_tiers AS (

    -- Tier 1 - strictest: 3 miles, large capacity, high-income trade area
    SELECT
        s.site_id,
        s.site_address,
        f.facility_id,
        ROUND((ST_Distance(ST_Transform(s.geom, 2163),
                           ST_Transform(f.geom, 2163)) * 0.000621371)::numeric, 6)
            AS distance_miles,
        f.facility_name, f.address_line, f.city, f.state_code, f.postal_code,
        f.permitted_capacity, f.website_url,
        f.price_infant_full_day,    f.waitlist_infant_flag,
        f.price_preschool_full_day, f.waitlist_preschool_flag,
        f.median_hh_income, f.price_observed_date,
        1 AS tier
    FROM site_selection.candidate_sites   s
    JOIN poi.competitor_facilities        f
      ON f.operator_brand IS DISTINCT FROM :brand_name
     -- ST_DWithin is the index-accelerated predicate (GiST); the ST_Distance
     -- above only measures the pairs that already survived it.
     AND ST_DWithin(ST_Transform(s.geom, 2163), ST_Transform(f.geom, 2163), 4828.02)
    WHERE f.permitted_capacity >= 100
      AND f.median_hh_income   >= 80000

    UNION ALL

    -- Tier 2 - relax the radius and the capacity floor, drop the income filter
    SELECT
        s.site_id, s.site_address, f.facility_id,
        ROUND((ST_Distance(ST_Transform(s.geom, 2163),
                           ST_Transform(f.geom, 2163)) * 0.000621371)::numeric, 6),
        f.facility_name, f.address_line, f.city, f.state_code, f.postal_code,
        f.permitted_capacity, f.website_url,
        f.price_infant_full_day,    f.waitlist_infant_flag,
        f.price_preschool_full_day, f.waitlist_preschool_flag,
        f.median_hh_income, f.price_observed_date,
        2
    FROM site_selection.candidate_sites   s
    JOIN poi.competitor_facilities        f
      ON f.operator_brand IS DISTINCT FROM :brand_name
     AND ST_DWithin(ST_Transform(s.geom, 2163), ST_Transform(f.geom, 2163), 8046.72)
    WHERE f.permitted_capacity >= 75

    UNION ALL

    -- Tier 3 - 5 miles, any competitor regardless of size or trade area
    SELECT
        s.site_id, s.site_address, f.facility_id,
        ROUND((ST_Distance(ST_Transform(s.geom, 2163),
                           ST_Transform(f.geom, 2163)) * 0.000621371)::numeric, 6),
        f.facility_name, f.address_line, f.city, f.state_code, f.postal_code,
        f.permitted_capacity, f.website_url,
        f.price_infant_full_day,    f.waitlist_infant_flag,
        f.price_preschool_full_day, f.waitlist_preschool_flag,
        f.median_hh_income, f.price_observed_date,
        3
    FROM site_selection.candidate_sites   s
    JOIN poi.competitor_facilities        f
      ON f.operator_brand IS DISTINCT FROM :brand_name
     AND ST_DWithin(ST_Transform(s.geom, 2163), ST_Transform(f.geom, 2163), 8046.72)

    UNION ALL

    -- Tier 4 - widen to 10 miles for sparse, rural trade areas
    SELECT
        s.site_id, s.site_address, f.facility_id,
        ROUND((ST_Distance(ST_Transform(s.geom, 2163),
                           ST_Transform(f.geom, 2163)) * 0.000621371)::numeric, 6),
        f.facility_name, f.address_line, f.city, f.state_code, f.postal_code,
        f.permitted_capacity, f.website_url,
        f.price_infant_full_day,    f.waitlist_infant_flag,
        f.price_preschool_full_day, f.waitlist_preschool_flag,
        f.median_hh_income, f.price_observed_date,
        4
    FROM site_selection.candidate_sites   s
    JOIN poi.competitor_facilities        f
      ON f.operator_brand IS DISTINCT FROM :brand_name
     AND ST_DWithin(ST_Transform(s.geom, 2163), ST_Transform(f.geom, 2163), 16093.4)

    UNION ALL

    -- Tier 5 - last resort: no distance filter, just the nearest remaining rows.
    -- NOTE: this is a cartesian product. See the LATERAL/KNN rewrite at the
    -- bottom before running it against a large competitor table.
    SELECT
        s.site_id, s.site_address, f.facility_id,
        ROUND((ST_Distance(ST_Transform(s.geom, 2163),
                           ST_Transform(f.geom, 2163)) * 0.000621371)::numeric, 6),
        f.facility_name, f.address_line, f.city, f.state_code, f.postal_code,
        f.permitted_capacity, f.website_url,
        f.price_infant_full_day,    f.waitlist_infant_flag,
        f.price_preschool_full_day, f.waitlist_preschool_flag,
        f.median_hh_income, f.price_observed_date,
        5
    FROM site_selection.candidate_sites   s
    JOIN poi.competitor_facilities        f
      ON f.operator_brand IS DISTINCT FROM :brand_name
),

-- A competitor can qualify under several tiers at once. Keep the strongest one.
deduped AS (
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY site_id, facility_id
                   ORDER BY tier, distance_miles
               ) AS dup_rank
        FROM all_tiers
    ) t
    WHERE dup_rank = 1
),

-- Final ordering: match quality first, proximity second.
final_ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY site_id
               ORDER BY tier, distance_miles
           ) AS competitor_rank
    FROM deduped
)
SELECT
    site_id,
    site_address,
    competitor_rank,
    tier,
    facility_id,
    facility_name,
    address_line,
    city,
    state_code,
    postal_code,
    permitted_capacity,
    website_url,
    distance_miles,
    price_infant_full_day,
    waitlist_infant_flag,
    price_preschool_full_day,
    waitlist_preschool_flag,
    median_hh_income,
    price_observed_date
FROM final_ranked
WHERE competitor_rank <= 10;


/* ----------------------------------------------------------------------------
   Recommended rewrite of Tier 5: LATERAL + KNN instead of a cross join.
   The <-> operator uses the GiST index to walk outward from each site and
   stops after 10 rows, instead of scoring every site x facility pair.
   ---------------------------------------------------------------------------- */
-- SELECT s.site_id, n.facility_id, n.facility_name
-- FROM site_selection.candidate_sites s
-- CROSS JOIN LATERAL (
--     SELECT f.*
--     FROM poi.competitor_facilities f
--     WHERE f.operator_brand IS DISTINCT FROM :brand_name
--     ORDER BY f.geom <-> s.geom
--     LIMIT 10
-- ) n;


/* ----------------------------------------------------------------------------
   Notes for anyone reusing this
   ----------------------------------------------------------------------------
   * EPSG:2163 (US National Atlas Equal Area) is equal-AREA, not equidistant,
     so planar distances carry a few percent of error across CONUS. That is
     acceptable for ranking; if you report the mileage to a client, prefer
     ST_Distance(s.geom::geography, f.geom::geography) or a local state-plane
     / UTM zone. EPSG:2163 is also deprecated in favour of EPSG:9311.
   * ST_Transform inside the join predicate is evaluated per row. Storing a
     pre-projected geometry column with its own GiST index is a large win.
   * IS DISTINCT FROM handles a NULL operator_brand without an extra OR.
   * The tier number travels with every row into the output. Downstream
     consumers can see how hard the query had to work to find each competitor
     - a tier 1 match and a tier 5 match are not the same quality of evidence.
   ---------------------------------------------------------------------------- */


/* ----------------------------------------------------------------------------
   Reading the results
   ---------------------------------------------------------------------------- */
-- Competitor set, ordered by site
-- SELECT *
-- FROM site_selection.candidate_site_competitors
-- ORDER BY site_id, competitor_rank;

-- How many sites landed in each tier - the health check for the tier design.
-- If most sites bottom out at tier 4/5, the tier 1 thresholds are too strict.
-- SELECT tier,
--        COUNT(*)                 AS matches,
--        COUNT(DISTINCT site_id)  AS sites
-- FROM site_selection.candidate_site_competitors
-- GROUP BY tier
-- ORDER BY tier;

-- Sites that never reached a tier 1 or tier 2 match - the thin markets.
-- SELECT site_id, site_address, MIN(tier) AS best_tier
-- FROM site_selection.candidate_site_competitors
-- GROUP BY site_id, site_address
-- HAVING MIN(tier) >= 3
-- ORDER BY best_tier DESC, site_id;
