-- =====================================================================
-- OLX Used Goods Marketplace Database: Phase 5 Partitioning DDL
-- Database: PostgreSQL 15+
-- Schema: olx
-- Demonstrates declarative RANGE partitioning on listings(posted_at).
-- =====================================================================

SET search_path TO olx;

-- ---------------------------------------------------------------------
-- 1. Partitioned Table Architecture
-- Note on Primary Key Rule: In PostgreSQL declarative partitioning,
-- any PRIMARY KEY or UNIQUE constraint on a partitioned table MUST
-- include the partition key column (posted_at).
-- ---------------------------------------------------------------------

DROP TABLE IF EXISTS listings_partitioned CASCADE;

CREATE TABLE listings_partitioned (
    listing_id INT NOT NULL,
    seller_id INT NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    category_id INT NOT NULL REFERENCES categories(category_id) ON DELETE RESTRICT,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    price NUMERIC(12, 2) NOT NULL CHECK (price >= 0),
    is_negotiable BOOLEAN NOT NULL DEFAULT true,
    item_condition VARCHAR(20) NOT NULL CHECK (item_condition IN ('NEW', 'LIKE_NEW', 'GOOD', 'FAIR')),
    attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
    city_id INT NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    locality VARCHAR(100) NOT NULL,
    latitude NUMERIC(9, 6) NOT NULL CHECK (latitude BETWEEN -90.0 AND 90.0),
    longitude NUMERIC(9, 6) NOT NULL CHECK (longitude BETWEEN -180.0 AND 180.0),
    image_count INT NOT NULL DEFAULT 0 CHECK (image_count >= 0 AND image_count <= 20),
    view_count INT NOT NULL DEFAULT 0 CHECK (view_count >= 0),
    boost_package_id INT REFERENCES boost_packages(package_id) ON DELETE SET NULL,
    status VARCHAR(20) NOT NULL CHECK (status IN ('ACTIVE', 'EXPIRED', 'REMOVED', 'SOLD', 'PENDING')),
    posted_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL CHECK (expires_at >= posted_at),
    sold_at TIMESTAMPTZ CHECK (sold_at IS NULL OR sold_at >= posted_at),
    PRIMARY KEY (listing_id, posted_at),
    CONSTRAINT chk_part_sold_time CHECK (
        (status = 'SOLD' AND sold_at IS NOT NULL) OR (status <> 'SOLD')
    )
) PARTITION BY RANGE (posted_at);

-- ---------------------------------------------------------------------
-- 2. Range Partitions (Semi-Annual Quarters)
-- ---------------------------------------------------------------------

-- 2025 Partitions
CREATE TABLE listings_y2025_h1 PARTITION OF listings_partitioned
    FOR VALUES FROM ('2025-01-01 00:00:00+05:30') TO ('2025-07-01 00:00:00+05:30');

CREATE TABLE listings_y2025_h2 PARTITION OF listings_partitioned
    FOR VALUES FROM ('2025-07-01 00:00:00+05:30') TO ('2026-01-01 00:00:00+05:30');

-- 2026 Partitions
CREATE TABLE listings_y2026_h1 PARTITION OF listings_partitioned
    FOR VALUES FROM ('2026-01-01 00:00:00+05:30') TO ('2026-07-01 00:00:00+05:30');

CREATE TABLE listings_y2026_h2 PARTITION OF listings_partitioned
    FOR VALUES FROM ('2026-07-01 00:00:00+05:30') TO ('2027-01-01 00:00:00+05:30');

-- Default Partition for future overflow
CREATE TABLE listings_default PARTITION OF listings_partitioned DEFAULT;

-- ---------------------------------------------------------------------
-- 3. Global Index Declarations on Partitioned Root
-- (PostgreSQL automatically cascades indexes to existing and future partitions)
-- ---------------------------------------------------------------------

CREATE INDEX idx_part_listings_category_city ON listings_partitioned (category_id, city_id, price)
WHERE status = 'ACTIVE';

CREATE INDEX idx_part_listings_seller_status ON listings_partitioned (seller_id, status);

CREATE INDEX idx_part_listings_posted_at ON listings_partitioned (posted_at DESC);

-- Populate partitioned table from seed data
INSERT INTO listings_partitioned SELECT * FROM listings;

ANALYZE listings_partitioned;

-- ---------------------------------------------------------------------
-- 4. Demonstration of Partition Pruning
-- Query targeting June 2026 growth statistics scans ONLY listings_y2026_h1.
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM listings_partitioned
WHERE posted_at >= '2026-06-01 00:00:00+05:30' AND posted_at < '2026-07-01 00:00:00+05:30';
