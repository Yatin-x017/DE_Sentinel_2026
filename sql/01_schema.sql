-- =====================================================================
-- OLX Used Goods Marketplace Database: Phase 2 Relational Schema
-- Database: PostgreSQL 15+
-- Schema: olx
-- Note: Contains only declarative constraints (PK, FK, UNIQUE, NOT NULL, CHECK).
--       No tuning indexes added at this stage per Phase 2 guidelines.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS olx;
SET search_path TO olx;

-- 1. Cities Reference Table
DROP TABLE IF EXISTS seller_ratings CASCADE;
DROP TABLE IF EXISTS reports CASCADE;
DROP TABLE IF EXISTS favourites CASCADE;
DROP TABLE IF EXISTS offers CASCADE;
DROP TABLE IF EXISTS chat_messages CASCADE;
DROP TABLE IF EXISTS chat_threads CASCADE;
DROP TABLE IF EXISTS listings CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS boost_packages CASCADE;
DROP TABLE IF EXISTS categories CASCADE;
DROP TABLE IF EXISTS cities CASCADE;

CREATE TABLE cities (
    city_id INT PRIMARY KEY,
    city_name VARCHAR(100) NOT NULL UNIQUE,
    state VARCHAR(100) NOT NULL
);

-- 2. Categories Table (Hierarchical Self-Referential)
CREATE TABLE categories (
    category_id INT PRIMARY KEY,
    category_name VARCHAR(100) NOT NULL,
    parent_id INT REFERENCES categories(category_id) ON DELETE RESTRICT
);

-- 3. Boost Packages Reference Table
CREATE TABLE boost_packages (
    package_id INT PRIMARY KEY,
    package_name VARCHAR(100) NOT NULL UNIQUE,
    price NUMERIC(10, 2) NOT NULL CHECK (price >= 0),
    duration_days INT NOT NULL CHECK (duration_days > 0)
);

-- 4. Users Table
CREATE TABLE users (
    user_id INT PRIMARY KEY,
    full_name VARCHAR(150) NOT NULL,
    phone VARCHAR(20) NOT NULL UNIQUE,
    email VARCHAR(255) UNIQUE,
    city_id INT NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    phone_verified BOOLEAN NOT NULL DEFAULT false,
    is_banned BOOLEAN NOT NULL DEFAULT false,
    joined_at TIMESTAMPTZ NOT NULL
);

-- 5. Listings Table
CREATE TABLE listings (
    listing_id INT PRIMARY KEY,
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
    CONSTRAINT chk_sold_time CHECK (
        (status = 'SOLD' AND sold_at IS NOT NULL) OR (status <> 'SOLD')
    ),
    CONSTRAINT chk_attributes_json_object CHECK (jsonb_typeof(attributes) = 'object')
);

-- 6. Chat Threads Table
CREATE TABLE chat_threads (
    thread_id INT PRIMARY KEY,
    listing_id INT NOT NULL REFERENCES listings(listing_id) ON DELETE CASCADE,
    buyer_id INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT uq_thread_listing_buyer UNIQUE (listing_id, buyer_id)
);

-- 7. Chat Messages Table
CREATE TABLE chat_messages (
    message_id INT PRIMARY KEY,
    thread_id INT NOT NULL REFERENCES chat_threads(thread_id) ON DELETE CASCADE,
    sender_id INT NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    body TEXT NOT NULL,
    sent_at TIMESTAMPTZ NOT NULL,
    is_read BOOLEAN NOT NULL DEFAULT false
);

-- 8. Offers Table
CREATE TABLE offers (
    offer_id INT PRIMARY KEY,
    listing_id INT NOT NULL REFERENCES listings(listing_id) ON DELETE CASCADE,
    buyer_id INT NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    offer_price NUMERIC(12, 2) NOT NULL CHECK (offer_price > 0),
    status VARCHAR(20) NOT NULL CHECK (status IN ('ACCEPTED', 'COUNTERED', 'PENDING', 'REJECTED', 'WITHDRAWN')),
    created_at TIMESTAMPTZ NOT NULL,
    responded_at TIMESTAMPTZ CHECK (responded_at IS NULL OR responded_at >= created_at),
    CONSTRAINT chk_offer_pending_responded CHECK (
        (status = 'PENDING' AND responded_at IS NULL) OR (status <> 'PENDING' AND responded_at IS NOT NULL)
    )
);

-- 9. Favourites Table
CREATE TABLE favourites (
    user_id INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    listing_id INT NOT NULL REFERENCES listings(listing_id) ON DELETE CASCADE,
    saved_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, listing_id)
);

-- 10. Reports Table
CREATE TABLE reports (
    report_id INT PRIMARY KEY,
    listing_id INT NOT NULL REFERENCES listings(listing_id) ON DELETE CASCADE,
    reporter_id INT NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    reason VARCHAR(30) NOT NULL CHECK (reason IN ('ALREADY_SOLD', 'FRAUD', 'OFFENSIVE', 'SPAM', 'WRONG_CATEGORY')),
    created_at TIMESTAMPTZ NOT NULL,
    status VARCHAR(20) NOT NULL CHECK (status IN ('ACTIONED', 'DISMISSED', 'OPEN'))
);

-- 11. Seller Ratings Table
CREATE TABLE seller_ratings (
    rating_id INT PRIMARY KEY,
    seller_id INT NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    rater_id INT NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    listing_id INT NOT NULL REFERENCES listings(listing_id) ON DELETE CASCADE,
    stars INT NOT NULL CHECK (stars BETWEEN 1 AND 5),
    comment TEXT,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_no_self_rating CHECK (seller_id <> rater_id),
    CONSTRAINT uq_listing_rater UNIQUE (listing_id, rater_id)
);
