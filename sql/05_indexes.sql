-- =====================================================================
-- OLX Used Goods Marketplace Database: Phase 4 Indexes
-- Database: PostgreSQL 15+
-- Schema: olx
-- Every index is annotated with its target queries and design justification.
-- =====================================================================

SET search_path TO olx;

-- Ensure pg_trgm extension for accelerated substring search (R03)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ---------------------------------------------------------------------
-- 1. Listings Table Indexes
-- ---------------------------------------------------------------------

-- Serves R01: Browse active cars in city by price range, newest first
-- Equality columns first (category_id, city_id), range next (price), posted_at last.
-- NOTE: because price is a range column, this index cannot provide the posted_at DESC ordering;
-- the plan is a Bitmap Heap Scan + Sort. listing_id is not in the index, so it is not index-only.
-- INCLUDE (title, attributes) widens entries (JSONB); keep an eye on index-row size limits.
CREATE INDEX IF NOT EXISTS idx_listings_r01 ON listings (category_id, city_id, price, posted_at DESC)
INCLUDE (title, attributes)
WHERE status = 'ACTIVE';

-- Serves R02: Car filters on JSONB expressions (fuel, year, km_driven)
-- Expression index pre-evaluates JSON extractions to avoid on-the-fly casting of 120k rows.
CREATE INDEX IF NOT EXISTS idx_listings_r02 ON listings (
    category_id,
    city_id,
    (attributes ->> 'fuel'),
    ((attributes ->> 'year')::int),
    ((attributes ->> 'km_driven')::int),
    price
)
WHERE status = 'ACTIVE';

-- Serves R03: Case-insensitive search on title (title ILIKE '%iphone 13%')
-- GIN Trigram index accelerates non-prefix wildcard text matching by breaking titles into 3-character shingles.
CREATE INDEX IF NOT EXISTS idx_listings_title_trgm ON listings USING gin (title gin_trgm_ops)
WHERE status = 'ACTIVE';

-- Serves R05, W02: "My Ads" dashboard grouped by status and oldest active ad lookup
-- Composite index on seller_id and status; includes view_count for covering index aggregation.
CREATE INDEX IF NOT EXISTS idx_listings_seller_status ON listings (seller_id, status, listing_id)
INCLUDE (view_count);

-- Serves R08: Price guide for specific category and model
-- Composite index on category, JSONB model extraction, and posted_at date range.
CREATE INDEX IF NOT EXISTS idx_listings_r08 ON listings (
    category_id,
    (attributes ->> 'model'),
    posted_at,
    item_condition,
    price
);

-- Serves R09: "Near me" bounding box geographic filtering
-- Composite index on category and spatial coordinates (latitude, longitude).
CREATE INDEX IF NOT EXISTS idx_listings_geo ON listings (category_id, latitude, longitude)
INCLUDE (title, price)
WHERE status = 'ACTIVE';

-- Serves R10, W04: Expiration reminder queries and nightly expiration batch updates
-- Partial B-tree index on active listings by expires_at.
CREATE INDEX IF NOT EXISTS idx_listings_expires_active ON listings (expires_at)
INCLUDE (seller_id, title)
WHERE status = 'ACTIVE';

-- Intended for R12, but NOT used by the planner (grouping is on posted_at::date over the whole table).
-- Candidate for removal.
CREATE INDEX IF NOT EXISTS idx_listings_seller_posted ON listings (seller_id, posted_at);

-- Serves R13: Boost package adoption check
-- Partial index indexing only boosted ads to support rapid anti-join / NOT EXISTS lookups.
CREATE INDEX IF NOT EXISTS idx_listings_boost_package ON listings (boost_package_id)
WHERE boost_package_id IS NOT NULL;

-- Serves R14: Category insights for sold ads
-- Partial index indexing sold ads by category and sold_at timestamp.
CREATE INDEX IF NOT EXISTS idx_listings_sold_category ON listings (category_id, sold_at, posted_at)
WHERE status = 'SOLD';

-- Intended for R17, but NOT used (query aggregates all rows; Seq Scan wins). Candidate for removal.
-- Serves R17: Monetisation views comparison (boosted vs unboosted)
-- Covering index grouping by category and boost boolean.
CREATE INDEX IF NOT EXISTS idx_listings_r17 ON listings (category_id, (boost_package_id IS NOT NULL))
INCLUDE (view_count);

-- Intended for R18, but NOT used (full-table GROUP BY). Candidate for removal.
-- Serves R18: Quality audit finding duplicate ads from the same seller
-- Composite index over the grouping attributes (seller_id, title, price).
CREATE INDEX IF NOT EXISTS idx_listings_duplicate_check ON listings (seller_id, title, price);

-- Serves R19: Active car listings in city for city reports
-- Partial index on ACTIVE listings (WHERE status = 'ACTIVE'); the R19 predicates category_id = 2, city_id = 1 are index key columns.
CREATE INDEX IF NOT EXISTS idx_listings_r19 ON listings (category_id, city_id, listing_id)
INCLUDE (title)
WHERE status = 'ACTIVE';

-- Serves R20: Growth reporting by posted date
-- B-tree on posted_at accelerates chronological scans and date-range index lookups.
CREATE INDEX IF NOT EXISTS idx_listings_posted_at ON listings (posted_at);

-- Serves R22: Moderation console pagination (OFFSET 50000)
-- Covering index over posted_at DESC including all required projection columns.
CREATE INDEX IF NOT EXISTS idx_listings_posted_at_desc ON listings (posted_at DESC)
INCLUDE (listing_id, seller_id, category_id, title, status);


-- ---------------------------------------------------------------------
-- 2. Chat Threads & Messages Indexes
-- ---------------------------------------------------------------------

-- Serves R06, R07, W03: Chat conversations by buyer
CREATE INDEX IF NOT EXISTS idx_chat_threads_buyer ON chat_threads (buyer_id, thread_id, listing_id);

-- Serves R19, R25: Chat threads by listing
CREATE INDEX IF NOT EXISTS idx_chat_threads_listing ON chat_threads (listing_id, thread_id, buyer_id, created_at);

-- Serves R06, R19, R25: Chat messages by thread and sent timestamp
CREATE INDEX IF NOT EXISTS idx_chat_messages_thread_sent ON chat_messages (thread_id, sent_at DESC)
INCLUDE (sender_id, body, is_read);

-- Serves R07: Unread chat messages badge counter
-- Partial index covering unread messages only.
CREATE INDEX IF NOT EXISTS idx_chat_messages_unread ON chat_messages (thread_id, sender_id)
WHERE NOT is_read;


-- ---------------------------------------------------------------------
-- 3. Auxiliary Tables Indexes (Offers, Reports, Favourites, Ratings)
-- ---------------------------------------------------------------------

-- Serves R15, W05: Offers filtering and ranking by listing and status
CREATE INDEX IF NOT EXISTS idx_offers_listing_status ON offers (listing_id, status, offer_price DESC);

-- Serves R16: Trending favourites saved in recent date windows
CREATE INDEX IF NOT EXISTS idx_favourites_saved_at ON favourites (saved_at, listing_id);

-- Serves R11: Moderation reports queue
CREATE INDEX IF NOT EXISTS idx_reports_open ON reports (listing_id, reason)
WHERE status = 'OPEN';

-- Used by R04 (index-only); NOT used by R21 (full aggregation, Seq Scan).
-- Serves R04, R21: Seller ratings aggregation
CREATE INDEX IF NOT EXISTS idx_seller_ratings_seller ON seller_ratings (seller_id, stars);

-- Fresh statistics for optimizer
ANALYZE;
