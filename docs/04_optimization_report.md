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
- **Result:** Execution time plummeted from 1,196.2 ms (3-run avg) to **6.11 ms** (3-run avg).

**Before (`EXPLAIN ANALYZE` — Run 1 from `benchmarks/results/baseline/R19.txt`):**
```text
Sort  (cost=1256548.70..1256549.35 rows=261 width=36) (actual time=1162.211..1162.236 rows=279.00 loops=1)
  Sort Key: ((SubPlan 1)) DESC
  Sort Method: quicksort  Memory: 39kB
  Buffers: shared hit=261566
  ->  Gather  (cost=1000.00..1256538.22 rows=261 width=36) (actual time=0.199..1162.126 rows=279.00 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        Buffers: shared hit=261563
        ->  Parallel Seq Scan on listings l  (cost=0.00..5320.00 rows=109 width=20) (actual time=0.089..3.596 rows=93.00 loops=3)
              Filter: ((category_id = 2) AND (city_id = 1) AND ((status)::text = 'ACTIVE'::text))
              Rows Removed by Filter: 39907
              Buffers: shared hit=4445
        SubPlan 1
          ->  Aggregate  (cost=4.31..4.32 rows=1 width=8) (actual time=0.003..0.003 rows=1.00 loops=279)
                Buffers: shared hit=559
                ->  Index Only Scan using uq_thread_listing_buyer on chat_threads t  (cost=0.29..4.31 rows=1 width=0) (actual time=0.003..0.003 rows=0.57 loops=279)
                      Index Cond: (listing_id = l.listing_id)
                      Heap Fetches: 0
                      Index Searches: 279
                      Buffers: shared hit=559
        SubPlan 2
          ->  Aggregate  (cost=4785.68..4785.69 rows=1 width=8) (actual time=4.157..4.157 rows=1.00 loops=279)
                Buffers: shared hit=256559
                ->  Hash Join  (cost=8.32..4785.67 rows=4 width=8) (actual time=1.769..4.154 rows=2.09 loops=279)
                      Hash Cond: (m.thread_id = t_1.thread_id)
                      Buffers: shared hit=256559
                      ->  Seq Scan on chat_messages m  (cost=0.00..4227.29 rows=209529 width=12) (actual time=0.001..4.327 rows=207797.36 loops=121)
                            Buffers: shared hit=255842
                      ->  Hash  (cost=8.31..8.31 rows=1 width=4) (actual time=0.002..0.002 rows=0.57 loops=279)
                            Buckets: 1024  Batches: 1  Memory Usage: 9kB
                            Buffers: shared hit=717
                            ->  Index Scan using uq_thread_listing_buyer on chat_threads t_1  (cost=0.29..8.31 rows=1 width=4) (actual time=0.001..0.001 rows=0.57 loops=279)
                                  Index Cond: (listing_id = l.listing_id)
                                  Index Searches: 279
                                  Buffers: shared hit=717
Planning:
  Buffers: shared hit=285
Planning Time: 0.459 ms
Execution Time: 1162.295 ms
```

**After (`EXPLAIN ANALYZE` — Run 1 from `benchmarks/results/optimized/R19.txt`):**
```text
Sort  (cost=1950.90..1951.57 rows=269 width=37) (actual time=16.685..16.691 rows=279.00 loops=1)
  Sort Key: (COALESCE((count(DISTINCT t.thread_id)), '0'::bigint)) DESC
  Sort Method: quicksort  Memory: 39kB
  Buffers: shared hit=1238 read=262
  ->  Merge Left Join  (cost=6.73..1940.04 rows=269 width=37) (actual time=2.019..16.656 rows=279.00 loops=1)
        Merge Cond: (l.listing_id = t.listing_id)
        Buffers: shared hit=1235 read=262
        ->  Index Only Scan using idx_listings_r19 on listings l  (cost=0.29..480.73 rows=269 width=21) (actual time=0.306..0.328 rows=279.00 loops=1)
              Index Cond: ((category_id = 2) AND (city_id = 1))
              Heap Fetches: 88
              Index Searches: 1
              Buffers: shared hit=86 read=2
        ->  GroupAggregate  (cost=6.44..1452.77 rows=469 width=20) (actual time=1.710..16.306 rows=120.00 loops=1)
              Group Key: t.listing_id
              Buffers: shared hit=1149 read=260
              ->  Incremental Sort  (cost=6.44..1444.56 rows=469 width=16) (actual time=1.706..16.264 rows=583.00 loops=1)
                    Sort Key: t.listing_id, t.thread_id
                    Presorted Key: t.listing_id
                    Full-sort Groups: 17  Sort Method: quicksort  Average Memory: 26kB  Peak Memory: 26kB
                    Buffers: shared hit=1149 read=260
                    ->  Nested Loop Left Join  (cost=1.12..1430.46 rows=469 width=16) (actual time=0.777..16.206 rows=583.00 loops=1)
                          Buffers: shared hit=1149 read=260
                          ->  Nested Loop  (cost=0.70..1343.76 rows=134 width=8) (actual time=0.591..3.643 rows=159.00 loops=1)
                                Buffers: shared hit=820 read=107
                                ->  Index Only Scan using idx_listings_r19 on listings l_1  (cost=0.29..480.73 rows=269 width=4) (actual time=0.006..0.193 rows=279.00 loops=1)
                                      Index Cond: ((category_id = 2) AND (city_id = 1))
                                      Heap Fetches: 88
                                      Index Searches: 1
                                      Buffers: shared hit=87 read=1
                                ->  Index Only Scan using idx_chat_threads_listing on chat_threads t  (cost=0.41..3.20 rows=1 width=8) (actual time=0.012..0.012 rows=0.57 loops=279)
                                      Index Cond: (listing_id = l_1.listing_id)
                                      Heap Fetches: 0
                                      Index Searches: 279
                                      Buffers: shared hit=733 read=106
                          ->  Index Only Scan using idx_chat_messages_thread_sent on chat_messages m  (cost=0.42..0.61 rows=4 width=12) (actual time=0.077..0.079 rows=3.67 loops=159)
                                Index Cond: (thread_id = t.thread_id)
                                Heap Fetches: 0
                                Index Searches: 159
                                Buffers: shared hit=329 read=153
Planning:
  Buffers: shared hit=721
Planning Time: 1.197 ms
Execution Time: 16.731 ms
```

### 2. R06: Chat Inbox Overview (74.1 ms → 1.15 ms — 64× Speedup)
- **Problem:** The query filtered by `t.buyer_id = 1042 OR l.seller_id = 1042`. In PostgreSQL, an `OR` condition spanning two different tables prevents the optimizer from using single-column B-tree indexes, forcing sequential scans across `chat_threads` and `listings`.
- **Solution:** Rewrote the `OR` join into a `UNION` of two independent, index-backed subqueries (`buyer_id = 1042` and `seller_id = 1042`), followed by an Index-Only Scan on `idx_chat_messages_thread_sent`.
- **Result:** Latency dropped from 74.15 ms (3-run avg) to **1.15 ms** (3-run avg).

**Before (`EXPLAIN ANALYZE` — Run 1 from `benchmarks/results/baseline/R06.txt`):**
```text
Sort  (cost=27240.36..27240.37 rows=4 width=49) (actual time=69.095..69.164 rows=13.00 loops=1)
  Sort Key: m.sent_at DESC
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=33310
  ->  Nested Loop  (cost=7479.87..27240.32 rows=4 width=49) (actual time=13.259..69.140 rows=13.00 loops=1)
        Buffers: shared hit=33307
        ->  Gather  (cost=2728.74..8235.74 rows=4 width=20) (actual time=5.797..6.469 rows=13.00 loops=1)
              Workers Planned: 2
              Workers Launched: 2
              Buffers: shared hit=5591
              ->  Hash Join  (cost=1728.74..7235.34 rows=2 width=20) (actual time=8.418..14.492 rows=4.33 loops=3)
                    Hash Cond: (l.listing_id = t.listing_id)
                    Join Filter: ((t.buyer_id = 1042) OR (l.seller_id = 1042))
                    Rows Removed by Join Filter: 19947
                    Buffers: shared hit=5591
                    ->  Parallel Seq Scan on listings l  (cost=0.00..4945.00 rows=50000 width=24) (actual time=0.004..1.995 rows=40000.00 loops=3)
                          Buffers: shared hit=4445
                    ->  Hash  (cost=980.55..980.55 rows=59855 width=12) (actual time=5.380..5.380 rows=59855.00 loops=3)
                          Buckets: 65536  Batches: 1  Memory Usage: 3084kB
                          Buffers: shared hit=1146
                          ->  Seq Scan on chat_threads t  (cost=0.00..980.55 rows=59855 width=12) (actual time=0.019..2.451 rows=59855.00 loops=3)
                                Buffers: shared hit=1146
        ->  Limit  (cost=4751.13..4751.14 rows=1 width=29) (actual time=4.819..4.819 rows=1.00 loops=13)
              Buffers: shared hit=27716
              ->  Sort  (cost=4751.13..4751.14 rows=4 width=29) (actual time=4.818..4.818 rows=1.00 loops=13)
                    Sort Key: m.sent_at DESC
                    Sort Method: top-N heapsort  Memory: 25kB
                    Buffers: shared hit=27716
                    ->  Seq Scan on chat_messages m  (cost=0.00..4751.11 rows=4 width=29) (actual time=2.887..4.812 rows=3.46 loops=13)
                          Filter: (thread_id = t.thread_id)
                          Rows Removed by Filter: 209526
                          Buffers: shared hit=27716
Planning:
  Buffers: shared hit=298
Planning Time: 1.180 ms
Execution Time: 69.211 ms
```

**After (`EXPLAIN ANALYZE` — Run 1 from `benchmarks/results/optimized/R06.txt`):**
```text
Sort  (cost=62.49..62.50 rows=3 width=50) (actual time=3.102..3.103 rows=13.00 loops=1)
  Sort Key: m.sent_at DESC
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=94 read=29
  ->  Nested Loop  (cost=26.82..62.47 rows=3 width=50) (actual time=1.288..3.091 rows=13.00 loops=1)
        Buffers: shared hit=91 read=29
        ->  Nested Loop  (cost=26.40..55.12 rows=3 width=21) (actual time=1.079..1.120 rows=13.00 loops=1)
              Buffers: shared hit=71 read=9
              ->  Unique  (cost=26.11..30.19 rows=3 width=8) (actual time=1.071..1.076 rows=13.00 loops=1)
                    Buffers: shared hit=32 read=9
                    ->  Merge Append  (cost=26.11..30.18 rows=3 width=8) (actual time=1.071..1.074 rows=13.00 loops=1)
                          Sort Key: chat_threads.thread_id, chat_threads.listing_id
                          Buffers: shared hit=32 read=9
                          ->  Index Only Scan using idx_chat_threads_buyer on chat_threads  (cost=0.29..4.32 rows=2 width=8) (actual time=0.201..0.201 rows=3.00 loops=1)
                                Index Cond: (buyer_id = 1042)
                                Heap Fetches: 0
                                Index Searches: 1
                                Buffers: shared hit=1 read=2
                          ->  Sort  (cost=25.81..25.81 rows=1 width=8) (actual time=0.870..0.870 rows=10.00 loops=1)
                                Sort Key: t.thread_id, t.listing_id
                                Sort Method: quicksort  Memory: 25kB
                                Buffers: shared hit=31 read=7
                                ->  Nested Loop  (cost=0.83..25.80 rows=1 width=8) (actual time=0.042..0.865 rows=10.00 loops=1)
                                      Buffers: shared hit=31 read=7
                                      ->  Index Only Scan using idx_listings_seller_status on listings l_1  (cost=0.42..12.47 rows=3 width=4) (actual time=0.009..0.022 rows=9.00 loops=1)
                                            Index Cond: (seller_id = 1042)
                                            Heap Fetches: 6
                                            Index Searches: 1
                                            Buffers: shared hit=10
                                      ->  Index Only Scan using idx_chat_threads_listing on chat_threads t  (cost=0.41..4.43 rows=1 width=8) (actual time=0.093..0.093 rows=1.11 loops=9)
                                            Index Cond: (listing_id = l_1.listing_id)
                                            Heap Fetches: 0
                                            Index Searches: 9
                                            Buffers: shared hit=21 read=7
              ->  Index Scan using listings_pkey on listings l  (cost=0.29..8.31 rows=1 width=21) (actual time=0.003..0.003 rows=1.00 loops=13)
                    Index Cond: (listing_id = chat_threads.listing_id)
                    Index Searches: 13
                    Buffers: shared hit=39
        ->  Limit  (cost=0.42..2.44 rows=1 width=29) (actual time=0.151..0.151 rows=1.00 loops=13)
              Buffers: shared hit=20 read=20
              ->  Index Only Scan using idx_chat_messages_thread_sent on chat_messages m  (cost=0.42..8.49 rows=4 width=29) (actual time=0.151..0.151 rows=1.00 loops=13)
                    Index Cond: (thread_id = chat_threads.thread_id)
                    Heap Fetches: 0
                    Index Searches: 13
                    Buffers: shared hit=20 read=20
Planning:
  Buffers: shared hit=657 read=9
Planning Time: 2.224 ms
Execution Time: 3.143 ms
```

### 3. R03: Search "iPhone 13" Active Ads (49.6 ms → 1.02 ms — 48× Speedup)
- **Problem:** Substring match `title ILIKE '%iphone 13%'` contains a leading wildcard, rendering standard B-tree indexes useless. PostgreSQL had to sequentially read and evaluate all 120,000 listings.
- **Solution:** Created a Generalized Inverted Index (GIN) using the `pg_trgm` extension:
  ```sql
  CREATE INDEX idx_listings_title_trgm ON listings USING gin (title gin_trgm_ops) WHERE status = 'ACTIVE';
  ```
- **Result:** Replaced sequential heap scans with a Bitmap Index Scan, reducing latency from 49.55 ms (3-run avg) to **1.02 ms** (3-run avg).

**Before (`EXPLAIN ANALYZE` — Run 1 from `benchmarks/results/baseline/R03.txt`):**
```text
Limit  (cost=6257.11..6257.21 rows=40 width=36) (actual time=49.062..49.065 rows=40.00 loops=1)
  Buffers: shared hit=4448
  ->  Sort  (cost=6257.11..6258.06 rows=383 width=36) (actual time=49.062..49.063 rows=40.00 loops=1)
        Sort Key: price
        Sort Method: top-N heapsort  Memory: 29kB
        Buffers: shared hit=4448
        ->  Seq Scan on listings  (cost=0.00..6245.00 rows=383 width=36) (actual time=0.090..48.974 rows=375.00 loops=1)
              Filter: (((title)::text ~~* '%iphone 13%'::text) AND ((status)::text = 'ACTIVE'::text))
              Rows Removed by Filter: 119625
              Buffers: shared hit=4445
Planning:
  Buffers: shared hit=123
Planning Time: 0.287 ms
Execution Time: 49.076 ms
```

**After (`EXPLAIN ANALYZE` — Run 1 from `benchmarks/results/optimized/R03.txt`):**
```text
Limit  (cost=1135.81..1135.91 rows=40 width=37) (actual time=1.350..1.353 rows=40.00 loops=1)
  Buffers: shared hit=326
  ->  Sort  (cost=1135.81..1136.66 rows=342 width=37) (actual time=1.349..1.350 rows=40.00 loops=1)
        Sort Key: price
        Sort Method: top-N heapsort  Memory: 29kB
        Buffers: shared hit=326
        ->  Bitmap Heap Scan on listings  (cost=65.06..1125.00 rows=342 width=37) (actual time=0.297..1.232 rows=375.00 loops=1)
              Recheck Cond: (((title)::text ~~* '%iphone 13%'::text) AND ((status)::text = 'ACTIVE'::text))
              Heap Blocks: exact=307
              Buffers: shared hit=323
              ->  Bitmap Index Scan on idx_listings_title_trgm  (cost=0.00..64.97 rows=342 width=0) (actual time=0.238..0.239 rows=375.00 loops=1)
                    Index Cond: ((title)::text ~~* '%iphone 13%'::text)
                    Index Searches: 1
                    Buffers: shared hit=16
Planning:
  Buffers: shared hit=499
Planning Time: 2.082 ms
Execution Time: 1.487 ms
```

### 4. R05: "My Ads" Seller Portal (9.05 ms → 0.20 ms — 46× Speedup)
- **Problem:** Filter by `seller_id = 1042` required reading 120,000 rows to find the handful of ads posted by the seller.
- **Solution:** Created composite covering index `idx_listings_seller_status ON listings (seller_id, status, listing_id) INCLUDE (view_count)`.
- **Result:** Converted to an **Index Only Scan**, dropping execution time to **0.195 ms** (3-run avg).

**Before (`EXPLAIN ANALYZE` — Run 1 from `benchmarks/results/baseline/R05.txt`):**
```text
GroupAggregate  (cost=5945.02..5945.07 rows=2 width=22) (actual time=9.278..9.280 rows=3.00 loops=1)
  Group Key: status
  Buffers: shared hit=4448
  ->  Sort  (cost=5945.02..5945.03 rows=3 width=10) (actual time=9.271..9.272 rows=9.00 loops=1)
        Sort Key: status
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=4448
        ->  Seq Scan on listings  (cost=0.00..5945.00 rows=3 width=10) (actual time=0.014..9.239 rows=9.00 loops=1)
              Filter: (seller_id = 1042)
              Rows Removed by Filter: 119991
              Buffers: shared hit=4445
Planning:
  Buffers: shared hit=114
Planning Time: 0.157 ms
Execution Time: 9.305 ms
```

**After (`EXPLAIN ANALYZE` — Run 1 from `benchmarks/results/optimized/R05.txt`):**
```text
GroupAggregate  (cost=0.42..12.51 rows=2 width=22) (actual time=0.394..0.404 rows=3.00 loops=1)
  Group Key: status
  Buffers: shared hit=7 read=3
  ->  Index Only Scan using idx_listings_seller_status on listings  (cost=0.42..12.47 rows=3 width=10) (actual time=0.382..0.396 rows=9.00 loops=1)
        Index Cond: (seller_id = 1042)
        Heap Fetches: 6
        Index Searches: 1
        Buffers: shared hit=7 read=3
Planning:
  Buffers: shared hit=462
Planning Time: 0.583 ms
Execution Time: 0.429 ms
```

### 5. R02: Filter Diesel Cars from 2018 with Mileage Limit (6.37 ms → 0.17 ms — 37× Speedup)
- **Problem:** Extracted and cast JSONB properties (`attributes ->> 'fuel'`, `year::int`, `km_driven::int`) on every row sequentially.
- **Solution:** Created an expression index pre-evaluating the JSON extraction:
  ```sql
  CREATE INDEX idx_listings_r02 ON listings (
      category_id, city_id, (attributes ->> 'fuel'),
      ((attributes ->> 'year')::int), ((attributes ->> 'km_driven')::int), price
  ) WHERE status = 'ACTIVE';
  ```
- **Result:** Instant index lookup in **0.170 ms** (3-run avg).

**Before (`EXPLAIN ANALYZE` — Run 1 from `benchmarks/results/baseline/R02.txt`):**
```text
Sort  (cost=7570.11..7570.12 rows=1 width=101) (actual time=5.492..6.533 rows=5.00 loops=1)
  Sort Key: price
  Sort Method: quicksort  Memory: 26kB
  Buffers: shared hit=4448
  ->  Gather  (cost=1000.00..7570.10 rows=1 width=101) (actual time=0.973..6.510 rows=5.00 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        Buffers: shared hit=4445
        ->  Parallel Seq Scan on listings  (cost=0.00..6570.00 rows=1 width=101) (actual time=2.451..4.059 rows=1.67 loops=3)
              Filter: ((category_id = 2) AND (city_id = 6) AND ((status)::text = 'ACTIVE'::text) AND ((attributes ->> 'fuel'::text) = 'Diesel'::text) AND (((attributes ->> 'year'::text))::integer >= 2018) AND (((attributes ->> 'km_driven'::text))::integer <= 60000))
              Rows Removed by Filter: 39998
              Buffers: shared hit=4445
Planning:
  Buffers: shared hit=136
Planning Time: 0.226 ms
Execution Time: 6.561 ms
```

**After (`EXPLAIN ANALYZE` — Run 1 from `benchmarks/results/optimized/R02.txt`):**
```text
Sort  (cost=8.32..8.33 rows=1 width=103) (actual time=0.360..0.360 rows=5.00 loops=1)
  Sort Key: price
  Sort Method: quicksort  Memory: 26kB
  Buffers: shared hit=11 read=2
  ->  Index Scan using idx_listings_r02 on listings  (cost=0.29..8.31 rows=1 width=103) (actual time=0.334..0.345 rows=5.00 loops=1)
        Index Cond: ((category_id = 2) AND (city_id = 6) AND ((attributes ->> 'fuel'::text) = 'Diesel'::text) AND (((attributes ->> 'year'::text))::integer >= 2018) AND (((attributes ->> 'km_driven'::text))::integer <= 60000))
        Index Searches: 1
        Buffers: shared hit=8 read=2
Planning:
  Buffers: shared hit=508
Planning Time: 0.997 ms
Execution Time: 0.377 ms
```

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

## Result Equivalence Verification (Rewritten Queries)

In `sql/06_optimized_queries.sql`, five queries were rewritten (`R06`, `R14`, `R19`, `R20`, plus the bug-fix rewrite `R13`). To prove that `R06`, `R14`, `R19`, and `R20` return **100% identical result sets and sort orders** as the original queries in `queries/workload_30.sql`—and to document the exact change in `R13` from 0 rows to 2 rows—we executed bidirectional `EXCEPT ALL` set differences alongside row-count and ordered `md5(string_agg(...))` checksum comparisons against `olx_db`:

### Verification SQL Script
```sql
SET search_path TO olx;

WITH
r06_orig AS (
    SELECT t.thread_id, l.title, last_msg.body, last_msg.sent_at
    FROM chat_threads t
    JOIN listings l ON l.listing_id = t.listing_id
    CROSS JOIN LATERAL (SELECT m.body, m.sent_at FROM chat_messages m
                        WHERE m.thread_id = t.thread_id ORDER BY m.sent_at DESC LIMIT 1) last_msg
    WHERE t.buyer_id = 1042 OR l.seller_id = 1042
),
r06_opt AS (
    SELECT t.thread_id, l.title, last_msg.body, last_msg.sent_at
    FROM (
        SELECT thread_id, listing_id FROM chat_threads WHERE buyer_id = 1042
        UNION
        SELECT t.thread_id, t.listing_id FROM chat_threads t JOIN listings l ON l.listing_id = t.listing_id WHERE l.seller_id = 1042
    ) t
    JOIN listings l ON l.listing_id = t.listing_id
    CROSS JOIN LATERAL (SELECT m.body, m.sent_at FROM chat_messages m
                        WHERE m.thread_id = t.thread_id ORDER BY m.sent_at DESC LIMIT 1) last_msg
),
r14_orig AS (
    SELECT c.category_name, count(*) AS sold,
           round(avg(EXTRACT(EPOCH FROM (l.sold_at - l.posted_at)) / 86400), 1) AS avg_days_to_sell
    FROM listings l
    JOIN categories c ON c.category_id = l.category_id
    WHERE l.status = 'SOLD'
      AND EXTRACT(YEAR FROM l.sold_at) = 2026
    GROUP BY c.category_name
),
r14_opt AS (
    SELECT c.category_name, count(*) AS sold,
           round(avg(EXTRACT(EPOCH FROM (l.sold_at - l.posted_at)) / 86400), 1) AS avg_days_to_sell
    FROM listings l
    JOIN categories c ON c.category_id = l.category_id
    WHERE l.status = 'SOLD'
      AND l.sold_at >= '2026-01-01 00:00:00+05:30' AND l.sold_at < '2027-01-01 00:00:00+05:30'
    GROUP BY c.category_name
),
r19_orig AS (
    SELECT l.listing_id, l.title,
           (SELECT count(*) FROM chat_threads t WHERE t.listing_id = l.listing_id) AS chats,
           (SELECT max(m.sent_at) FROM chat_messages m JOIN chat_threads t ON t.thread_id = m.thread_id
             WHERE t.listing_id = l.listing_id) AS last_chat_at
    FROM listings l
    WHERE l.category_id = 2 AND l.city_id = 1 AND l.status = 'ACTIVE'
),
r19_opt AS (
    WITH car_threads AS (
        SELECT t.listing_id,
               count(DISTINCT t.thread_id) AS chats,
               max(m.sent_at) AS last_chat_at
        FROM chat_threads t
        JOIN listings l ON l.listing_id = t.listing_id
        LEFT JOIN chat_messages m ON m.thread_id = t.thread_id
        WHERE l.category_id = 2 AND l.city_id = 1 AND l.status = 'ACTIVE'
        GROUP BY t.listing_id
    )
    SELECT l.listing_id, l.title,
           coalesce(ct.chats, 0) AS chats,
           ct.last_chat_at
    FROM listings l
    LEFT JOIN car_threads ct ON ct.listing_id = l.listing_id
    WHERE l.category_id = 2 AND l.city_id = 1 AND l.status = 'ACTIVE'
),
r20_orig AS (
    SELECT day, ads, sum(ads) OVER (ORDER BY day) AS running_total
    FROM (
        SELECT posted_at::date AS day, count(*) AS ads
        FROM listings
        WHERE posted_at::date BETWEEN '2026-06-01' AND '2026-06-30'
        GROUP BY 1
    ) d
),
r20_opt AS (
    SELECT day, ads, sum(ads) OVER (ORDER BY day) AS running_total
    FROM (
        SELECT posted_at::date AS day, count(*) AS ads
        FROM listings
        WHERE posted_at >= '2026-06-01 00:00:00+05:30' AND posted_at < '2026-07-01 00:00:00+05:30'
        GROUP BY 1
    ) d
),
r13_orig AS (
    SELECT b.package_id, b.package_name, b.price
    FROM boost_packages b
    WHERE b.package_id NOT IN (SELECT l.boost_package_id FROM listings l)
),
r13_opt AS (
    SELECT b.package_id, b.package_name, b.price
    FROM boost_packages b
    WHERE NOT EXISTS (
        SELECT 1 FROM listings l WHERE l.boost_package_id = b.package_id
    )
)
SELECT 'R06' AS query_id,
       (SELECT count(*) FROM r06_orig) AS orig_rows,
       (SELECT count(*) FROM r06_opt) AS opt_rows,
       (SELECT count(*) FROM (SELECT * FROM r06_orig EXCEPT ALL SELECT * FROM r06_opt) x) AS orig_minus_opt,
       (SELECT count(*) FROM (SELECT * FROM r06_opt EXCEPT ALL SELECT * FROM r06_orig) x) AS opt_minus_orig,
       (SELECT md5(string_agg(thread_id::text || '|' || title || '|' || body || '|' || sent_at::text, E'\n' ORDER BY sent_at DESC, thread_id)) FROM r06_orig) AS orig_md5,
       (SELECT md5(string_agg(thread_id::text || '|' || title || '|' || body || '|' || sent_at::text, E'\n' ORDER BY sent_at DESC, thread_id)) FROM r06_opt) AS opt_md5
UNION ALL
SELECT 'R14',
       (SELECT count(*) FROM r14_orig),
       (SELECT count(*) FROM r14_opt),
       (SELECT count(*) FROM (SELECT * FROM r14_orig EXCEPT ALL SELECT * FROM r14_opt) x),
       (SELECT count(*) FROM (SELECT * FROM r14_opt EXCEPT ALL SELECT * FROM r14_orig) x),
       (SELECT md5(string_agg(category_name || '|' || sold::text || '|' || avg_days_to_sell::text, E'\n' ORDER BY avg_days_to_sell, category_name)) FROM r14_orig),
       (SELECT md5(string_agg(category_name || '|' || sold::text || '|' || avg_days_to_sell::text, E'\n' ORDER BY avg_days_to_sell, category_name)) FROM r14_opt)
UNION ALL
SELECT 'R19',
       (SELECT count(*) FROM r19_orig),
       (SELECT count(*) FROM r19_opt),
       (SELECT count(*) FROM (SELECT * FROM r19_orig EXCEPT ALL SELECT * FROM r19_opt) x),
       (SELECT count(*) FROM (SELECT * FROM r19_opt EXCEPT ALL SELECT * FROM r19_orig) x),
       (SELECT md5(string_agg(listing_id::text || '|' || title || '|' || chats::text || '|' || coalesce(last_chat_at::text, 'NULL'), E'\n' ORDER BY chats DESC, listing_id)) FROM r19_orig),
       (SELECT md5(string_agg(listing_id::text || '|' || title || '|' || chats::text || '|' || coalesce(last_chat_at::text, 'NULL'), E'\n' ORDER BY chats DESC, listing_id)) FROM r19_opt)
UNION ALL
SELECT 'R20',
       (SELECT count(*) FROM r20_orig),
       (SELECT count(*) FROM r20_opt),
       (SELECT count(*) FROM (SELECT * FROM r20_orig EXCEPT ALL SELECT * FROM r20_opt) x),
       (SELECT count(*) FROM (SELECT * FROM r20_opt EXCEPT ALL SELECT * FROM r20_orig) x),
       (SELECT md5(string_agg(day::text || '|' || ads::text || '|' || running_total::text, E'\n' ORDER BY day)) FROM r20_orig),
       (SELECT md5(string_agg(day::text || '|' || ads::text || '|' || running_total::text, E'\n' ORDER BY day)) FROM r20_opt)
UNION ALL
SELECT 'R13 (Bug Fix)',
       (SELECT count(*) FROM r13_orig),
       (SELECT count(*) FROM r13_opt),
       (SELECT count(*) FROM (SELECT * FROM r13_orig EXCEPT ALL SELECT * FROM r13_opt) x),
       (SELECT count(*) FROM (SELECT * FROM r13_opt EXCEPT ALL SELECT * FROM r13_orig) x),
       coalesce((SELECT md5(string_agg(package_id::text || '|' || package_name || '|' || price::text, E'\n' ORDER BY package_id)) FROM r13_orig), 'NULL (0 rows)'),
       (SELECT md5(string_agg(package_id::text || '|' || package_name || '|' || price::text, E'\n' ORDER BY package_id)) FROM r13_opt);
```

### Exact Verification Output (`olx_db`)

| Query ID | Original Rows | Optimized Rows | `Orig EXCEPT ALL Opt` | `Opt EXCEPT ALL Orig` | Original MD5 Checksum | Optimized MD5 Checksum | Verdict |
|---|---:|---:|---:|---:|---|---|---|
| **R06** | 13 | 13 | 0 | 0 | `3e70ce10e492afe635b95441d56f511e` | `3e70ce10e492afe635b95441d56f511e` | ✅ **Identical** |
| **R14** | 9 | 9 | 0 | 0 | `aa9c4219242e6099f0e2caa810bcd9ca` | `aa9c4219242e6099f0e2caa810bcd9ca` | ✅ **Identical** |
| **R19** | 279 | 279 | 0 | 0 | `86e274b8c1c5053f46786b0b814a2356` | `86e274b8c1c5053f46786b0b814a2356` | ✅ **Identical** |
| **R20** | 30 | 30 | 0 | 0 | `29f84108c087303e411632de97450765` | `29f84108c087303e411632de97450765` | ✅ **Identical** |
| **R13 (Bug Fix)** | 0 | 2 | 0 | 2 | `NULL (0 rows)` | `442dc37af625001660e57333b28c3a9d` | 🎯 **Fixed NULL Defect** |

> **Note on `R13`:** `R13` intentionally changed from **0 rows** to **2 rows** (`package_id = 5` and `package_id = 6`) because the original `NOT IN` query suffered from the SQL three-valued logic (`NULL`) defect explained in Section 3. All other rewritten queries (`R06`, `R14`, `R19`, `R20`) have **0 row differences** in both directions and matching MD5 checksums.

---

## 4. Write Overhead Analysis

Adding secondary indexes trades write latency for read throughput.
- **W01 (INSERT listing):** Increased from `0.691 ms` to `2.377 ms` (+244.0%). Inserting a new listing requires writing to the heap page and inserting entries into the secondary index B-trees/GIN structures on `listings`. A latency of `2.377 ms` remains well within our **< 5 ms SLA** for customer-facing writes.
- **W02 (UPDATE oldest ad):** Improved from `9.754 ms` to `0.449 ms` (21.7× faster) because locating `min(listing_id)` was accelerated by `idx_listings_seller_status`, which far outweighed single-row index maintenance.
- **W03 (INSERT chat message):** Improved from `0.501 ms` to `0.354 ms` (29.3% faster) because `idx_chat_threads_buyer` accelerated the `max(thread_id)` subquery.
- **W04 (Nightly job — expire active ads):** Slowed down from **`46.709 ms`** (baseline 3-run avg) to **`78.689 ms`** (optimized 3-run avg), an increase of **`+31.980 ms` (+68.5%)**.
  - **PostgreSQL Engine Mechanism (Why `W04` Slowed Down):** While `idx_listings_expires_active` accelerated finding the 2,256 expired rows (`13.09 ms` Seq Scan → `2.34 ms` Index Scan), `W04` executes `UPDATE listings SET status = 'EXPIRED' WHERE status = 'ACTIVE' AND expires_at < '2026-07-01 00:00:00+05:30'`. In our baseline schema (with only `listings_pkey`), `status` was not indexed at all, allowing PostgreSQL to perform **Heap-Only Tuple (HOT) updates** whenever free space existed on the same 8 kB heap page without touching any index. After adding our Phase 4 indexes, `status` is directly indexed in `idx_listings_seller_status`, included in `idx_listings_posted_at_desc`, and referenced in the `WHERE status = 'ACTIVE'` predicate of **7 partial indexes** (`idx_listings_r01`, `idx_listings_r02`, `idx_listings_title_trgm`, `idx_listings_geo`, `idx_listings_expires_active`, `idx_listings_r19`). Modifying a column referenced in any index key or partial-index predicate **completely prevents HOT updates** for all 2,256 updated rows and forces PostgreSQL to insert new index tuples across the non-partial indexes touching `status` (increasing buffer hits from `21,828` to `64,220` in Run 1).
  - **Acceptability:** Despite the +68.5% write overhead, `78.689 ms` for a once-a-night bulk sweep of 2,256 rows is **12.7× faster than the `< 1,000 ms` Batch Job SLA target** and is a worthwhile trade-off for the massive read speedups across `R01`–`R24`.
- **W05 (UPDATE offers):** Accelerated from `1.281 ms` to `0.276 ms` (4.6× faster) due to `idx_offers_listing_status`.

---

## 5. Index Storage & Table Size Breakdown

### 5.1 Per-Index Size Breakdown (All 23 Secondary Indexes in `sql/05_indexes.sql`)

Measured directly from `olx_db` using `pg_relation_size` and `pg_size_pretty` on `pg_indexes`:

| # | Index Name | Parent Table | Which Queries It Serves | Index Size (Pretty) | Index Size (Bytes) | Parent Table Size | Index-to-Table Ratio |
|---:|---|---|---|---|---:|---:|---:|
| 1 | `idx_listings_posted_at_desc` | `listings` | R22 (Moderation pagination) | 7856 kB (7.67 MB) | 8,044,544 | 35 MB (36,241,408 B) | 22.20% |
| 2 | `idx_listings_r08` | `listings` | R08 (Price guide median by model/2026) | 6960 kB (6.80 MB) | 7,127,040 | 35 MB (36,241,408 B) | 19.67% |
| 3 | `idx_listings_duplicate_check` | `listings` | R18 (Duplicate ads detection) | 5736 kB (5.60 MB) | 5,873,664 | 35 MB (36,241,408 B) | 16.21% |
| 4 | `idx_listings_seller_status` | `listings` | R05, R06, W02 ("My Ads" & seller lookups) | 4776 kB (4.66 MB) | 4,890,624 | 35 MB (36,241,408 B) | 13.49% |
| 5 | `idx_listings_seller_posted` | `listings` | R12 (Spam detection by seller/day) | 3720 kB (3.63 MB) | 3,809,280 | 35 MB (36,241,408 B) | 10.51% |
| 6 | `idx_listings_r17` | `listings` | R17 (Boosted vs normal views) | 3720 kB (3.63 MB) | 3,809,280 | 35 MB (36,241,408 B) | 10.51% |
| 7 | `idx_listings_posted_at` | `listings` | R20 (June 2026 daily growth) | 2656 kB (2.59 MB) | 2,719,744 | 35 MB (36,241,408 B) | 7.50% |
| 8 | `idx_listings_sold_category` | `listings` | R14 (Avg days to sell in 2026) | 1752 kB (1.71 MB) | 1,794,048 | 35 MB (36,241,408 B) | 4.95% |
| 9 | `idx_listings_r01` | `listings` | R01 (Active cars in city by price) | 1496 kB (1.46 MB) | 1,531,904 | 35 MB (36,241,408 B) | 4.23% |
| 10 | `idx_listings_geo` | `listings` | R09 ("Near me" bounding box) | 680 kB (0.66 MB) | 696,320 | 35 MB (36,241,408 B) | 1.92% |
| 11 | `idx_listings_title_trgm` | `listings` | R03 (`ILIKE '%iphone 13%'` GIN trigram) | 664 kB (0.65 MB) | 679,936 | 35 MB (36,241,408 B) | 1.88% |
| 12 | `idx_listings_r19` | `listings` | R19 (Active car listings in Bengaluru) | 504 kB (0.49 MB) | 516,096 | 35 MB (36,241,408 B) | 1.42% |
| 13 | `idx_listings_expires_active` | `listings` | R10, R16, R24, W04 (Active expiry & status) | 504 kB (0.49 MB) | 516,096 | 35 MB (36,241,408 B) | 1.42% |
| 14 | `idx_listings_r02` | `listings` | R02 (JSONB car fuel/year/km filters) | 440 kB (0.43 MB) | 450,560 | 35 MB (36,241,408 B) | 1.24% |
| 15 | `idx_listings_boost_package` | `listings` | R13 (Unbought boost packages anti-join) | 80 kB (0.08 MB) | 81,920 | 35 MB (36,241,408 B) | 0.23% |
| 16 | `idx_chat_messages_thread_sent` | `chat_messages` | R06, R19, R25 (Latest message per thread) | 13 MB (13,712 kB) | 14,041,088 | 17 MB (17,465,344 B) | 80.39% |
| 17 | `idx_chat_messages_unread` | `chat_messages` | R07 (Unread chat badge count) | 16 kB (0.02 MB) | 16,384 | 17 MB (17,465,344 B) | 0.09% |
| 18 | `idx_chat_threads_listing` | `chat_threads` | R06, R19, R25 (Threads by listing) | 2392 kB (2.34 MB) | 2,449,408 | 3056 kB (3,129,344 B) | 78.27% |
| 19 | `idx_chat_threads_buyer` | `chat_threads` | R06, R07, W03 (Threads by buyer) | 1856 kB (1.81 MB) | 1,900,544 | 3056 kB (3,129,344 B) | 60.73% |
| 20 | `idx_favourites_saved_at` | `favourites` | R16 (Trending favourites in date window) | 2168 kB (2.12 MB) | 2,220,032 | 3328 kB (3,407,872 B) | 65.14% |
| 21 | `idx_offers_listing_status` | `offers` | R15, W05 (Offers by listing, status, price) | 808 kB (0.79 MB) | 827,392 | 1536 kB (1,572,864 B) | 52.60% |
| 22 | `idx_seller_ratings_seller` | `seller_ratings` | R04, R21 (Seller rating aggregations) | 264 kB (0.26 MB) | 270,336 | 1088 kB (1,114,112 B) | 24.26% |
| 23 | `idx_reports_open` | `reports` | R11 (Moderation queue open reports) | 48 kB (0.05 MB) | 49,152 | 640 kB (655,360 B) | 7.50% |
| | **Total (23 Secondary Indexes)** | **All Tables** | **R01–R25, W01–W05** | **59.1 MB (60,528 kB)** | **61,980,672** | **64.7 MB (66,301,952 B)** | **93.48%** |

### 5.2 Per-Table Summary Breakdown

| Table Name | Heap Table Size | Primary / Unique Constraint Indexes | Phase 4 Secondary Indexes (23) | Total Storage |
|---|---:|---:|---:|---:|
| `listings` | 35 MB (36,241,408 B) | 2.6 MB (`listings_pkey`) | 40.6 MB (15 indexes) | **78.2 MB** |
| `chat_messages` | 17 MB (17,465,344 B) | 4.5 MB (`chat_messages_pkey`) | 13.4 MB (2 indexes) | **34.9 MB** |
| `users` | 4.3 MB (4,489,216 B) | 4.5 MB (`users_pkey`, `phone`, `email`) | — | **8.8 MB** |
| `favourites` | 3.3 MB (3,407,872 B) | 1.5 MB (`favourites_pkey`) | 2.1 MB (1 index) | **6.9 MB** |
| `chat_threads` | 3.0 MB (3,129,344 B) | 2.6 MB (`chat_threads_pkey`, `uq_thread_listing_buyer`) | 4.1 MB (2 indexes) | **9.7 MB** |
| `offers` | 1.5 MB (1,572,864 B) | 440 kB (`offers_pkey`) | 808 kB (1 index) | **2.7 MB** |
| `seller_ratings` | 1.1 MB (1,114,112 B) | 504 kB (`seller_ratings_pkey`, `uq_listing_rater`) | 264 kB (1 index) | **1.8 MB** |
| `reports` | 640 kB (655,360 B) | 192 kB (`reports_pkey`) | 48 kB (1 index) | **880 kB** |
| `categories` | 8 kB | 16 kB (`categories_pkey`) | — | **24 kB** |
| `cities` | 8 kB | 32 kB (`cities_pkey`, `cities_city_name_key`) | — | **40 kB** |
| `boost_packages`| 8 kB | 32 kB (`boost_packages_pkey`, `boost_packages_package_name_key`) | — | **40 kB** |
| **Total Database** | **64.7 MB** | **16.8 MB** | **59.1 MB** | **140.6 MB** |

Our 23 custom secondary indexes consume **59.1 MB** (61,980,672 bytes) across the entire schema, whereas partial indexing kept specialized indexes like `idx_chat_messages_unread` (16 kB), `idx_reports_open` (48 kB), and `idx_listings_boost_package` (80 kB) tiny. In exchange, aggregate 30-query workload runtime dropped by **82.5% (5.7× faster)**.

---

## 6. Queries Resilient to Speedup & Justification

- **R12 (Spam Detection), R18 (Duplicate Ads), R25 (Seller Responsiveness):** These queries perform deep multi-table aggregations or hash joins across the vast majority of records in `listings` (120,000 rows) and `chat_messages` (209,000 rows). When a query must aggregate more than 30–40% of the entire table, PostgreSQL's cost-based optimizer deliberately selects a Sequential Scan over index scans because sequential page I/O is faster than random index block lookups. These queries belong to the **Reporting / Analytics SLA (< 5,000 ms)** and comfortably beat their target (~38–62 ms).
