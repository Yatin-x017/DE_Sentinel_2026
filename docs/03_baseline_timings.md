# Phase 3: Baseline Query Timings (Unindexed Schema)

**Team:** T0058 (Sentinel) · **Project:** OLX Used Goods Marketplace Database
**Hardware:** Apple MacBook Pro (Apple M4, 16 GB RAM) · **PostgreSQL:** 17.11

Each query was measured over 3 runs using `EXPLAIN (ANALYZE, BUFFERS)` via `./benchmarks/run_benchmark.sh olx_db baseline`.
All write operations (`W01`–`W05`) were executed inside transactional `BEGIN; ... ROLLBACK;` blocks to ensure dataset immutability across benchmark iterations.

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01: Browse: active cars in Bengaluru priced ₹3–6 lakh, newest first | READ | 14.228 | 9.369 | 7.040 | 10.212 |
| R02: Car filters: diesel cars from 2018 or later with at most 60,000 km, in Pune | READ | 6.561 | 5.835 | 6.700 | 6.365 |
| R03: Search: active "iPhone 13" ads anywhere, cheapest first | READ | 49.076 | 49.484 | 50.098 | 49.553 |
| R04: Ad page: listing 100871 with its seller and the seller's average rating | READ | 0.451 | 0.378 | 0.491 | 0.440 |
| R05: "My Ads": user 1042's listings grouped by status | READ | 9.305 | 9.166 | 8.665 | 9.045 |
| R06: Chat inbox: every conversation of user 1042 (as buyer or seller) with its latest message | READ | 69.211 | 76.058 | 77.175 | 74.148 |
| R07: Chat badge: unread messages sent to user 1042 | READ | 5.602 | 5.917 | 6.412 | 5.977 |
| R08: Price guide: median asking price of iPhone 13 ads by condition (2026) | READ | 6.495 | 5.778 | 6.130 | 6.134 |
| R09: "Near me": active furniture within ~2 km of central Bengaluru (12.9716, 77.5946) | READ | 6.185 | 6.531 | 7.242 | 6.653 |
| R10: Reminder job: active ads that expire in the first 3 days of July 2026 | READ | 6.216 | 5.507 | 6.030 | 5.918 |
| R11: Moderation queue: ads with 3 or more open reports | READ | 2.793 | 1.949 | 1.870 | 2.204 |
| R12: Spam detection: users who posted 5 or more ads on the same day | READ | 35.905 | 37.495 | 35.846 | 36.415 |
| R13: Monetisation: boost packages that no ad has ever bought | READ | 14.748 | 15.319 | 15.191 | 15.086 |
| R14: Category insights: average days to sell per category for ads sold in 2026 | READ | 9.193 | 9.821 | 9.814 | 9.609 |
| R15: Marketplace health: share of offers accepted, per category | READ | 12.184 | 12.900 | 13.179 | 12.754 |
| R16: Trending: active ads saved to favourites most in the last 7 days of June 2026 | READ | 12.301 | 12.844 | 12.927 | 12.691 |
| R17: Monetisation: average views of boosted vs normal ads per category | READ | 12.626 | 12.587 | 12.620 | 12.611 |
| R18: Quality: the same seller posting the same title at the same price more than once | READ | 40.856 | 38.925 | 39.431 | 39.737 |
| R19: City report: chats and latest chat time for every active car ad in Bengaluru | READ | 1162.295 | 1195.333 | 1230.984 | 1196.204 |
| R20: Growth: new ads per day and running total, June 2026 | READ | 7.974 | 7.980 | 7.469 | 7.808 |
| R21: Trust: best-rated sellers (at least 5 ratings) | READ | 11.191 | 9.496 | 8.995 | 9.894 |
| R22: Moderation console: all ads, newest first, page 2,001 (25 per page) | READ | 32.657 | 35.641 | 59.677 | 42.658 |
| R23: Login with mobile number | READ | 0.032 | 0.022 | 0.023 | 0.026 |
| R24: Home page: active ads per top-level category (sub-categories rolled up) | READ | 13.303 | 12.483 | 12.397 | 12.728 |
| R25: Seller responsiveness: average minutes from a buyer's first message to the seller's first reply, per category (2026) | READ | 64.359 | 62.872 | 62.086 | 63.106 |
| W01: Post an ad: user 1042 sells a study table in Bengaluru | WRITE | 0.713 | 0.642 | 0.718 | 0.691 |
| W02: Mark as sold: user 1042's oldest active ad | WRITE | 9.726 | 9.887 | 9.649 | 9.754 |
| W03: Chat: user 1042 sends a message in their most recent conversation as a buyer | WRITE | 0.549 | 0.478 | 0.476 | 0.501 |
| W04: Nightly job: expire every active ad whose expiry date has passed (run at 00:00 on 1 July 2026) | WRITE | 102.042 | 19.013 | 19.073 | 46.709 |
| W05: Seller accepts the highest pending offer on listing 118642 and rejects the others | WRITE | 1.386 | 1.239 | 1.218 | 1.281 |
| **Total (sum of all 30)** | | | | | **1706.912** |

---

## Query Execution Plan Analysis & Bottlenecks

| Query | Scan Node(s) Observed in Plan | Performance Diagnosis & Root Cause |
|---|---|---|
| **R01** | `Seq Scan on listings` | Scans all 120,000 heap rows to filter by `category_id = 2`, `city_id = 1`, `status = 'ACTIVE'`, and price range, followed by an in-memory Sort on `posted_at DESC`. |
| **R02** | `Seq Scan on listings` | Performs full sequential scan while parsing and extracting JSONB attributes (`attributes ->> 'fuel'`, `year`, `km_driven`) across every row. |
| **R03** | `Seq Scan on listings` | Full sequential scan executing CPU-intensive string pattern matching (`title ILIKE '%iphone 13%'`) without a trigram GIN index. |
| **R04** | `Index Scan on listings_pkey` \| `Index Scan on users_pkey` \| `Seq Scan on seller_ratings` | Fast primary key point lookups for ad and seller; minor sequential scan on `seller_ratings` to aggregate average stars. |
| **R05** | `Seq Scan on listings` | Scans 120,000 listings sequentially to extract and group the small subset of ads belonging to `seller_id = 1042`. |
| **R06** | `Seq Scan on listings` \| `Seq Scan on chat_threads` \| `Seq Scan on chat_messages` | Full scans across three tables; lateral subquery repeatedly performs sequential scans on messages to fetch latest message. |
| **R07** | `Seq Scan on chat_messages` \| `Index Scan on chat_threads_pkey` \| `Index Scan on listings_pkey` | Sequential scan across 209k messages to filter `NOT is_read` and sender, followed by nested loop index scans. |
| **R08** | `Seq Scan on listings` | Sequential scan extracting JSONB model attribute and date filter before computing continuous percentile aggregate. |
| **R09** | `Seq Scan on listings` | Scans all 120,000 rows calculating trigonometric Haversine spherical distance formulas on unindexed latitude/longitude floats. |
| **R10** | `Seq Scan on listings` | Sequential scan across heap tuples filtering active ads against a 3-day expiry date window. |
| **R11** | `Seq Scan on reports` \| `Index Scan on listings_pkey` | Sequential scan on 7,999 reports to compute group count `>= 3`, joined to listings via primary key index. |
| **R12** | `Seq Scan on listings` | Full table aggregation over `seller_id` and cast date `posted_at::date` using HashAggregate and sort. |
| **R13** | `Seq Scan on boost_packages` \| `Seq Scan on listings` | Sequential scan executing `NOT IN (SELECT boost_package_id FROM listings)`. Returns **0 rows** incorrectly because nullable column causes three-valued logic (`UNKNOWN`). |
| **R14** | `Seq Scan on listings` \| `Seq Scan on categories` | Sequential scan filtering `status = 'SOLD'` and year 2026, computing epoch time delta per category. |
| **R15** | `Seq Scan on listings` \| `Seq Scan on offers` \| `Seq Scan on categories` | Three-way hash join and aggregation across offers, listings, and categories to compute accepted offer percentages. |
| **R16** | `Seq Scan on listings` \| `Seq Scan on favourites` | Sequential scan on 70,000 favourites filtering by `saved_at` timestamp, joined with active listings. |
| **R17** | `Seq Scan on listings` \| `Seq Scan on categories` | Sequential scan evaluating `boost_package_id IS NOT NULL` condition across 120,000 ads grouped by category. |
| **R18** | `Seq Scan on listings` | Full heap scan hashing `(seller_id, title, price)` tuples to identify duplicate ad postings. |
| **R19** | `Seq Scan on listings` \| `Index Only Scan on uq_thread_listing_buyer` \| `Seq Scan on chat_messages` | **Critical Bottleneck (1,196 ms):** Two correlated scalar subqueries executed for every single active car listing in Bengaluru, inducing thousands of scans on `chat_messages`. |
| **R20** | `Seq Scan on listings` | Sequential scan filtering June 2026 dates, followed by daily aggregation and window function cumulative sum. |
| **R21** | `Seq Scan on seller_ratings` \| `Seq Scan on users` | Hash join and group aggregation over ratings table joined with users to identify high-rated sellers. |
| **R22** | `Seq Scan on listings` | High-offset pagination (`OFFSET 50000 LIMIT 25`) forces the query engine to sequentially scan, sort, and discard 50,000 rows before returning 25 rows. |
| **R23** | `Index Scan using users_phone_key on users` | **Fastest Query (0.026 ms):** Direct B-tree unique index scan on `users(phone)`. |
| **R24** | `Seq Scan on listings` \| `Seq Scan on categories` | Sequential scan filtering active listings and joining with self-referencing categories hierarchy. |
| **R25** | `Seq Scan on chat_messages` \| `Seq Scan on chat_threads` \| `Seq Scan on listings` \| `Seq Scan on categories` | Deep aggregation over 209,000 messages calculating first response delta between buyer and seller per category. |
| **W01** | `(no scan)` | Direct single-tuple `INSERT` into listings heap and updating primary key / foreign key B-trees. |
| **W02** | `Seq Scan on listings` \| `Index Scan on listings_pkey` | Scalar subquery performs sequential scan to locate `min(listing_id)` for seller before executing index point update. |
| **W03** | `Index Scan using chat_threads_pkey` | Index lookup to identify max thread for user, followed by single-tuple `INSERT` into `chat_messages`. |
| **W04** | `Seq Scan on listings` | Sequential scan examining 120,000 listings to identify and update expired status, generating tuple writes and WAL logs. |
| **W05** | `Seq Scan on offers` | Subquery scans offers sequentially to find maximum pending price, then updates target row and rejects competitors. |
