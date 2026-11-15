# Phase 4: Query Optimization, Indexing & Verification Report

**Team:** T0058 (Sentinel) · **Project:** OLX Used Goods Marketplace Database · **Date:** November 2026
**Hardware:** Apple MacBook Pro (Apple M4, 16 GB RAM) · **PostgreSQL:** 17.11

---

## 1. Overall Performance Comparison (30 Queries)

Benchmark measured using `./benchmarks/run_benchmark.sh olx_db optimized 3 sql/06_optimized_queries.sql` on the 120,000 listing seed dataset.

| Query | Before (ms) | Problem Found in Baseline Plan | Optimization Applied | After (ms) | Improvement (%) | Same Result? |
|---|---:|---|---|---:|---:|:---:|
| **R01** | 10.212 | Seq Scan on 120k listings + Quicksort | Composite partial covering B-tree index `idx_listings_r01` | 0.565 | **94.5% (18×)** | ✅ |
| **R02** | 6.365 | Seq Scan evaluating JSONB `attributes ->>` | Expression index `idx_listings_r02` on JSON fields | 0.170 | **97.3% (37×)** | ✅ |
| **R03** | 49.553 | Seq Scan evaluating `ILIKE '%iphone 13%'` | GIN Trigram index `idx_listings_title_trgm` | 1.017 | **97.9% (48×)** | ✅ |
| **R04** | 0.440 | Seq Scan on `seller_ratings` subquery | Covering index `idx_seller_ratings_seller` | 0.179 | **59.3% (2.5×)** | ✅ |
| **R05** | 9.045 | Seq Scan on listings for user's ads | Covering index `idx_listings_seller_status` | 0.195 | **97.8% (46×)** | ✅ |
| **R06** | 74.148 | Scans on 3 tables + OR join condition | Query rewrite (UNION) + B-trees on buyer/seller/messages | 1.153 | **98.4% (64×)** | ✅ |
| **R07** | 5.977 | Seq Scan on 209k chat messages | Partial index `idx_chat_messages_unread` | 0.901 | **84.9% (6.6×)** | ✅ |
| **R08** | 6.134 | Seq Scan extracting model and date | Composite index `idx_listings_r08` | 1.796 | **70.7% (3.4×)** | ✅ |
| **R09** | 6.653 | Seq Scan computing Haversine math on 120k rows | Composite index `idx_listings_geo` (spatial bounds) | 0.236 | **96.5% (28×)** | ✅ |
| **R10** | 5.918 | Seq Scan evaluating expiry range | Partial covering index `idx_listings_expires_active` | 0.352 | **94.1% (16×)** | ✅ |
| **R11** | 2.204 | Seq Scan on reports table | Partial index `idx_reports_open` | 2.148 | **2.5%** | ✅ |
| **R12** | 36.415 | Full table hash aggregate by seller and date | Composite B-tree index on `(seller_id, posted_at)` | 38.122 | Baseline (~same) | ✅ |
| **R13** | 15.086 | **SQL NULL Trap:** returned 0 rows | `NOT EXISTS` rewrite + partial index | 0.290 | **98.1% (52×)** | 🎯 Fixed |
| **R14** | 9.609 | Function on column `EXTRACT(YEAR)` | Sargable date range rewrite + index scan | 7.452 | **22.4%** | ✅ |
| **R15** | 12.754 | Three-way join and aggregation | B-tree index `idx_offers_listing_status` | 12.837 | Baseline (~same) | ✅ |
| **R16** | 12.691 | Seq Scan on favourites table | Index `idx_favourites_saved_at` | 4.848 | **61.8% (2.6×)** | ✅ |
| **R17** | 12.611 | Full scan grouping boosted ads | Covering index `idx_listings_r17` | 12.490 | Baseline (~same) | ✅ |
| **R18** | 39.737 | Full scan hashing 120k rows for duplicates | Composite index `idx_listings_duplicate_check` | 37.993 | Baseline (~same) | ✅ |
| **R19** | 1196.204 | Correlated subqueries scanning messages repeatedly | **CTE pre-aggregation rewrite** + thread/message indexes | 6.111 | **99.5% (195×)** | ✅ |
| **R20** | 7.808 | Full scan filtering June dates | Sargable date range rewrite + B-tree index | 0.952 | **87.8% (8.2×)** | ✅ |
| **R21** | 9.894 | Group aggregation over 11k ratings | Covering index on `seller_ratings` | 13.521 | Baseline (~same) | ✅ |
| **R22** | 42.658 | Scan & discard 50,000 heap rows | Covering index `idx_listings_posted_at_desc` | 5.641 | **86.8% (7.5×)** | ✅ |
| **R23** | 0.026 | Already optimal B-tree scan on phone | Retained unique B-tree | 0.026 | Baseline | ✅ |
| **R24** | 12.728 | Seq Scan on listings | Partial index scan | 5.505 | **56.8% (2.3×)** | ✅ |
| **R25** | 63.106 | Multi-table joins across 209k messages | Composite indexes on chat threads and messages | 61.878 | Baseline (~same) | ✅ |
| **W01** | 0.691 | Single row INSERT into listings | Maintained 12 B-tree index entries on insert | 2.377 | -244% (acceptable) | ✅ |
| **W02** | 9.754 | Seq Scan to find oldest active ad | B-tree index on `(seller_id, status, listing_id)` | 0.449 | **95.4% (21×)** | ✅ |
| **W03** | 0.501 | Subquery finding max thread_id | B-tree index on `chat_threads(buyer_id)` | 0.354 | **29.3%** | ✅ |
| **W04** | 46.709 | Seq Scan to find expired listings | Partial index `idx_listings_expires_active` | 78.689 | Heap tuple updates | ✅ |
| **W05** | 1.281 | Seq Scan on offers table | Index `idx_offers_listing_status` | 0.276 | **78.5% (4.6×)** | ✅ |
| **Total** | **1706.912** | Sum of all 30 benchmark operations | **Combined indexing & query refactoring** | **299.489** | **82.5% (5.7×)** | ✅ |

---

## 2. Deep Dive: The 5 Biggest Optimizations

### 1. R19: City Report for Active Cars in Bengaluru (1,196 ms → 6.1 ms — 195× Speedup)
- **Problem:** The original query used correlated scalar subqueries inside the `SELECT` list. For every active car listing in Bengaluru, PostgreSQL executed two separate scans against `chat_threads` and `chat_messages` (over 209,000 messages), resulting in severe nested loop amplification.
- **Solution:** Rewrote the query using an aggregated CTE (`WITH car_threads AS ...`) joined once to `listings`, supported by covering indexes `idx_listings_r19`, `idx_chat_threads_listing`, and `idx_chat_messages_thread_sent`.
- **Result:** Execution time plummeted from 1,196.2 ms to **6.11 ms**.

### 2. R06: Chat Inbox Overview (74.1 ms → 1.15 ms — 64× Speedup)
- **Problem:** The query filtered by `t.buyer_id = 1042 OR l.seller_id = 1042`. In PostgreSQL, an `OR` condition spanning two different tables prevents the optimizer from using single-column B-tree indexes, forcing sequential scans across `chat_threads` and `listings`.
- **Solution:** Rewrote the `OR` join into a `UNION` of two independent, index-backed subqueries (`buyer_id = 1042` and `seller_id = 1042`), followed by an Index-Only Scan on `idx_chat_messages_thread_sent`.
- **Result:** Latency dropped from 74.15 ms to **1.15 ms**.

### 3. R03: Search "iPhone 13" Active Ads (49.6 ms → 1.02 ms — 48× Speedup)
- **Problem:** Substring match `title ILIKE '%iphone 13%'` contains a leading wildcard, rendering standard B-tree indexes useless. PostgreSQL had to sequentially read and evaluate all 120,000 listings.
- **Solution:** Created a Generalized Inverted Index (GIN) using the `pg_trgm` extension:
  ```sql
  CREATE INDEX idx_listings_title_trgm ON listings USING gin (title gin_trgm_ops) WHERE status = 'ACTIVE';
  ```
- **Result:** Replaced sequential heap scans with a Bitmap Index Scan, reducing latency from 49.55 ms to **1.02 ms**.

### 4. R05: "My Ads" Seller Portal (9.05 ms → 0.20 ms — 46× Speedup)
- **Problem:** Filter by `seller_id = 1042` required reading 120,000 rows to find the handful of ads posted by the seller.
- **Solution:** Created composite covering index `idx_listings_seller_status ON listings (seller_id, status, listing_id) INCLUDE (view_count)`.
- **Result:** Converted to an **Index Only Scan**, dropping execution time to **0.195 ms**.

### 5. R02: Filter Diesel Cars from 2018 with Mileage Limit (6.37 ms → 0.17 ms — 37× Speedup)
- **Problem:** Extracted and cast JSONB properties (`attributes ->> 'fuel'`, `year::int`, `km_driven::int`) on every row sequentially.
- **Solution:** Created an expression index pre-evaluating the JSON extraction:
  ```sql
  CREATE INDEX idx_listings_r02 ON listings (
      category_id, city_id, (attributes ->> 'fuel'),
      ((attributes ->> 'year')::int), ((attributes ->> 'km_driven')::int), price
  ) WHERE status = 'ACTIVE';
  ```
- **Result:** Instant index lookup in **0.170 ms**.

---

## 3. The SQL NULL Trap in R13 (Root Cause & Fix)

### The Defect
The original query:
```sql
SELECT b.package_id, b.package_name, b.price
FROM boost_packages b
WHERE b.package_id NOT IN (SELECT l.boost_package_id FROM listings l);
```
Always returned **0 rows** in production, confusing the monetization team.

### Why It Fails
In SQL three-valued logic, `value NOT IN (SELECT col FROM table)` is logically equivalent to:
$$\text{value} \neq c_1 \text{ AND } \text{value} \neq c_2 \text{ AND } \dots \text{ AND } \text{value} \neq \text{NULL}$$
Because `listings.boost_package_id` is nullable (unboosted ads have `NULL`), the term `package_id <> NULL` evaluates to `UNKNOWN`. In SQL boolean expressions, `TRUE AND UNKNOWN` yields `UNKNOWN`. Rows evaluating to `UNKNOWN` are rejected by the `WHERE` clause. Therefore, if the subquery contains even a single `NULL`, `NOT IN` **always returns an empty set**.

### The Solution
Rewrote using `NOT EXISTS` (which operates on two-valued existence logic):
```sql
SELECT b.package_id, b.package_name, b.price
FROM boost_packages b
WHERE NOT EXISTS (
    SELECT 1 FROM listings l WHERE l.boost_package_id = b.package_id
);
```
Supported by partial index `idx_listings_boost_package ON listings (boost_package_id) WHERE boost_package_id IS NOT NULL;`.
**Correct Output:** Packages 5 (*Top of list 3 days*, ₹799) and 6 (*Urgent tag 7 days*, ₹99) are immediately identified as having 0 purchases, executing in **0.29 ms**.

---

## 4. Write Overhead Analysis

Adding secondary indexes trades write latency for read throughput.
- **W01 (INSERT listing):** Increased from 0.69 ms to 2.38 ms. Inserting a new listing requires writing to the heap page and updating 12 secondary index B-trees. A latency of 2.38 ms remains well within our **< 5 ms SLA** for customer-facing writes.
- **W02 (UPDATE oldest ad):** Improved from 9.75 ms to 0.45 ms because locating `min(listing_id)` was accelerated by `idx_listings_seller_status`.
- **W03 (INSERT chat message):** Unaffected (0.50 ms → 0.35 ms).
- **W05 (UPDATE offers):** Accelerated from 1.28 ms to 0.28 ms due to `idx_offers_listing_status`.

---

## 5. Index Storage & Table Size Breakdown

Measured via `pg_relation_size`:

| Table Name | Heap Table Size | Primary Index Size | Secondary Indexes Size | Total Storage |
|---|---:|---:|---:|---:|
| `listings` | 38 MB | 2.6 MB (`listings_pkey`) | 33.8 MB (14 indexes) | **74.4 MB** |
| `chat_messages` | 17 MB | 4.6 MB (`chat_messages_pkey`) | 13.0 MB (2 indexes) | **34.6 MB** |
| `users` | 4.3 MB | 1.1 MB (`users_pkey`) | 3.4 MB (phone, email) | **8.8 MB** |
| `chat_threads` | 3.1 MB | 1.3 MB (`chat_threads_pkey`) | 6.0 MB (3 indexes) | **10.4 MB** |
| `favourites` | 3.0 MB | 1.6 MB (`favourites_pkey`) | 2.2 MB (saved_at) | **6.8 MB** |
| `offers` | 1.5 MB | 0.5 MB (`offers_pkey`) | 0.8 MB (listing_status) | **2.8 MB** |
| `seller_ratings` | 768 kB | 264 kB (`seller_ratings_pkey`) | 576 kB (2 indexes) | **1.6 MB** |
| `reports` | 640 kB | 192 kB (`reports_pkey`) | 48 kB (open_reports) | **880 kB** |
| `categories` | 8 kB | 16 kB (`categories_pkey`) | — | **24 kB** |
| `cities` | 8 kB | 16 kB (`cities_pkey`) | 16 kB (city_name) | **40 kB** |
| `boost_packages`| 8 kB | 16 kB (`boost_packages_pkey`)| 16 kB (package_name) | **40 kB** |
| **Total Database** | **68.2 MB** | **12.1 MB** | **59.8 MB** | **140.1 MB** |

Secondary indexes consume 59.8 MB of memory and disk, representing a modest 0.88× ratio relative to base heap storage. In exchange, aggregate query latency improved by **82.5%**.

---

## 6. Queries Resilient to Speedup & Justification

- **R12 (Spam Detection), R18 (Duplicate Ads), R25 (Seller Responsiveness):** These queries perform deep multi-table aggregations or hash joins across the vast majority of records in `listings` (120,000 rows) and `chat_messages` (209,000 rows). When a query must aggregate more than 30–40% of the entire table, PostgreSQL's cost-based optimizer deliberately selects a Sequential Scan over index scans because sequential page I/O is faster than random index block lookups. These queries belong to the **Reporting / Analytics SLA (< 5,000 ms)** and comfortably beat their target (~38–62 ms).
