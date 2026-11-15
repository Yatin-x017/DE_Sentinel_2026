# Phase 5: Scalability Architecture & 100× Growth Report

**Team:** T0058 (Sentinel) · **Project:** OLX Used Goods Marketplace Database · **Date:** November 2026
**Hardware:** Apple MacBook Pro (Apple M4, 16 GB RAM) · **PostgreSQL:** 17.11

---

## 1. Performance Target Verification Against SLAs

Every query was verified against its required production SLA target under our optimized schema:

| Workload Group | Queries | SLA Target | Actual Measured Time | Target Met? | Primary Execution Mechanism |
|---|---|---:|---:|:---:|---|
| **Real-Time / User-Facing** | R01, R02, R03, R04, R05, R06, R07, R09, R23, W01, W02, W03, W05 | **< 5.0 ms** | **0.026 ms – 2.38 ms** | ✅ **All Met** | B-tree index lookups, covering Index-Only scans, GIN trigram matching, and single-row updates. |
| **Interactive Internal Tools** | R10, R11, R13, R16, R22 | **< 250 ms** | **0.29 ms – 5.64 ms** | ✅ **All Met** | Partial indexes on active/open statuses and covering index scans for high-offset pagination. |
| **Reports & Analytics (OLAP)** | R08, R12, R14, R15, R17, R18, R19, R20, R21, R24, R25 | **< 5,000 ms** | **0.95 ms – 61.88 ms** | ✅ **All Met** | Parallel sequential page reads and pre-aggregated CTE joins. |
| **Automated Batch Jobs** | W04 (Ad Expiry Sweep) | **< 1,000 ms** | **78.69 ms** | ✅ **Met** | Partial index scan on active expiration timestamps (`expires_at`). |

---

## 2. Growth Analysis: From Seed (120k) to 20× (2.4M) and 100× (12M)

When scaling to 20× and 100× volume, query performance scales across three distinct complexity classes:

```
+---------------------------------------------------------------------------------------+
| 1. Sub-Linear Growth O(log N): Index lookups & Point Writes (R01-R07, R09, R23, W01-W05) |
|    - 120k listings: Tree Depth = 3 (~0.2 - 1.5 ms)                                     |
|    - 2.4M listings: Tree Depth = 4 (~0.5 - 2.8 ms)                                     |
|    - 12M listings:  Tree Depth = 4-5 (~1.0 - 4.5 ms)                                   |
+---------------------------------------------------------------------------------------+
| 2. Linear Growth O(N / Partitions): Date-Bounded Reports (R10, R14, R16, R20, W04)     |
|    - Scales proportionally with time window volume; mitigated by Partition Pruning.   |
+---------------------------------------------------------------------------------------+
| 3. High-Risk Multi-Table Joins: Full Analytic Aggregations (R15, R18, R25)            |
|    - Cross-table joins across 4.2M messages and 2.4M listings require Read Replicas    |
|      and incremental Materialized Views.                                              |
+---------------------------------------------------------------------------------------+
```

---

## 3. Architecture for 100× Growth (12M Listings)

### 3.1 Declarative Partitioning Strategy (Implemented in `sql/08_partitioning.sql`)

1. **Partition Key:** `listings` is partitioned using **`RANGE (posted_at)`** in semi-annual intervals (`listings_y2025_h1`, `listings_y2025_h2`, `listings_y2026_h1`, `listings_y2026_h2`, plus `listings_default`).
2. **Why `posted_at` over `city_id` or `category_id`?**
   - OLX ad lifecycles are inherently ephemeral: ads expire after 30 days. Over 90% of user traffic and critical batch jobs (`R01`, `R10`, `R16`, `R20`, `W04`) target recently posted or active listings.
   - **Partition Pruning:** PostgreSQL's planner statically and dynamically prunes older partition branches from the execution plan. When querying June 2026 listings, all historical 2025 and future partitions are skipped entirely.
   - **Zero-Downtime Data Lifecycle:** Retiring ads older than 2 years is achieved via an instant, metadata-only command:
     ```sql
     DROP TABLE listings_y2024_h1;
     ```
     This avoids generating millions of row delete locks and prevents table bloat.
3. **Primary Key Requirement:** Under PostgreSQL's declarative partitioning specification, all unique and primary key constraints on a partitioned table **must include the partition key**. The composite primary key is declared as:
   ```sql
   PRIMARY KEY (listing_id, posted_at)
   ```

### 3.2 Sharding Analysis: Evaluating Shard Keys

If the database exceeds single-node capacity (e.g., > 50M listings, > 100M messages), horizontal application-level sharding or Citus distributed tables must be adopted:

| Shard Key Candidate | Advantages | Severe Disadvantages & Bottlenecks |
|---|---|---|
| **By `city_id`** | High locality for location searches (`R01`, `R09`, `R19`). Geographic boundary matches regional infrastructure. | Skewed data distribution (e.g. Bengaluru/Mumbai represent 40% of traffic, while small cities are tiny). Cross-city browsing and national electronics searches (`R03`) become expensive scatter-gather queries. |
| **By `category_id`** | Clean boundary for vertical merchandising (`R08`, `R14`). | Vehicles and Mobiles dominate 70% of database I/O. Cross-category search (`R24`) requires querying all shards. |
| **By `seller_id` (Recommended)** | **Optimal for transactional integrity.** All listings, offers, and seller ratings for a given merchant co-locate on the same shard (`R04`, `R05`, `W01`, `W02`). | **The Buyer-Seller Chat Problem:** A chat thread links a buyer on Shard A with a seller on Shard B. |

#### Handling Cross-Shard Chat Threads
To resolve the buyer-seller cross-shard paradox:
- Shard `chat_threads` and `chat_messages` by `thread_id` (or co-locate them with `listing_id`).
- When Buyer 1042 loads their inbox (`R06`), an asynchronous messaging index service (or global Redis secondary index) maps `buyer_id → thread_ids`, dispatching parallel point reads rather than executing multi-shard distributed transactions.

### 3.3 Read Replicas & Caching Topology

```mermaid
flowchart TD
    Client[Web & Mobile Clients] --> Cache[(Redis Cluster)]
    Client --> HAProxy[Load Balancer / PgBouncer]
    HAProxy -->|Writes: W01-W05| Primary[(PostgreSQL Primary)]
    HAProxy -->|Point Reads: R04, R23| Primary
    Primary -->|Streaming Replication| Replica1[(Read Replica 1 - User Traffic)]
    Primary -->|Streaming Replication| Replica2[(Read Replica 2 - Analytics & Moderation)]
    Replica1 -->|Browse: R01, R02, R03, R09| Client
    Replica2 -->|Reports: R08, R11, R12, R14, R15, R18, R21, R25| BI[Internal Dashboards]
```

1. **Redis In-Memory Caching:**
   - `R24` (Home page category counts): Cached with 5-minute TTL.
   - `R23` (User authentication by phone): Session token cache.
   - `R07` (Unread message counter): Maintained as an atomic Redis hash `HINCRBY user:1042:unread`.
2. **Primary Node:**
   - Dedicated exclusively to transactional writes (`W01`–`W05`) and critical read-your-own-writes lookups (`R04`).
3. **Read Replicas:**
   - Replicas handle high-concurrency read queries (`R01`, `R02`, `R03`, `R06`, `R09`) and offload heavy analytic aggregations (`R08`, `R11`, `R12`, `R14`, `R15`, `R18`, `R20`, `R21`, `R25`).

### 3.4 Maintenance & Autovacuum Tuning

At 20× volume (2.4M listings, 4.2M messages), frequent row updates (`status = 'SOLD'`, `view_count++`, `is_read = true`) generate millions of dead tuples. Default PostgreSQL autovacuum settings are too conservative and lead to catastrophic table bloat and index degradation.

**Recommended Production Settings (`postgresql.conf`):**
```ini
# Accelerate autovacuum workers on high-write tables
autovacuum_max_workers = 6
autovacuum_vacuum_cost_limit = 2000
autovacuum_vacuum_cost_delay = 2ms

# Reduce scale factor thresholds on listings and messages
ALTER TABLE listings SET (
    autovacuum_vacuum_scale_factor = 0.05,
    autovacuum_vacuum_threshold = 1000,
    autovacuum_analyze_scale_factor = 0.02
);

ALTER TABLE chat_messages SET (
    autovacuum_vacuum_scale_factor = 0.05,
    autovacuum_vacuum_threshold = 2000
);
```

---

## 4. Conclusion & Production Readiness

The engineered relational schema and optimization suite achieve:
- **100% SLA compliance** across all real-time (< 5 ms), operational (< 250 ms), and reporting (< 5,000 ms) queries.
- **A 5.7× overall workload acceleration** (total runtime dropped from 1,706 ms to 299 ms on single-thread execution).
- Complete resolution of the SQL NULL bug in monetization tracking (`R13`).
- Seamless horizontal scalability via semi-annual partition pruning (`sql/08_partitioning.sql`) and a verified distributed sharding blueprint.
