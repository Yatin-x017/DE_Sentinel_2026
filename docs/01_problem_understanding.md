# Phase 1: Problem Understanding & Stakeholder Requirements

**Team:** T0058 (Sentinel) · **Project:** OLX Used Goods Marketplace Database · **Date:** November 2026

---

## 1. Problem Statements & Stakeholder Analysis

| # | Business Problem | Affected Stakeholder(s) | Related Queries | Workload Classification | Target Latency (SLA) |
|---|---|---|---|---|---|
| **P1** | **Browse & Filter Latency:** Buyers experience severe lag when searching listings by multi-attribute filters (price range, brand, year, mileage) and geographic radius ("near me"). | Buyers / Shoppers | R01, R02, R03, R09 | **Customer-Facing (Real-Time)** | **< 5 ms** |
| **P2** | **Listing Management & Seller Portal:** Ad detail views, "My Ads" dashboard, publishing new ads, and marking items as sold exhibit sluggish response times. | Sellers | R04, R05, W01, W02 | **Customer-Facing (Real-Time)** | **< 5 ms** |
| **P3** | **Real-Time Communication Bottlenecks:** Message delivery, conversational inbox listings, and unread notification badge counters stall under heavy user concurrency. | Active Users (Buyers & Sellers) / Chat Ops | R06, R07, W03 | **Customer-Facing (Real-Time)** | **< 5 ms** |
| **P4** | **Trust, Safety & Moderation Backlog:** High-priority moderation queues, multi-report listings, spam posting spikes, and duplicate ad detection take too long to retrieve. | Trust & Safety / Moderation Team | R11, R12, R18, R22 | **Interactive Internal Tools / Analytics** | **< 250 ms** (Console/Queue) / **< 5 s** (Spam detection) |
| **P5** | **Monetisation Analytics Inaccuracy:** The unsold boost packages report consistently returns zero results, obscuring inventory adoption and ad promotion metrics. | Monetisation & Revenue Operations | R13, R17 | **Interactive Reporting / Analytics** | **< 250 ms** (Interactive) / Correctness Fix |
| **P6** | **Category Performance Timeouts:** Deep aggregations for pricing benchmarks, liquidity (average days to sell), offer conversion rates, and seller response latency timeout. | Category Managers / Merchandising | R08, R14, R15, R25 | **Reporting / Analytics (OLAP)** | **< 5,000 ms** |
| **P7** | **Platform Scalability & Batch Throughput:** Nightly ad expiration batch runs, expiry reminders, and trending growth reports degrade system performance as data scales 20×. | Growth & Platform Engineering | R10, R16, R19, R20, R21, R23, R24, W04, W05 | **Hybrid:** Real-Time (R23, W05), Batch (W04), Reporting (R19–R24) | **< 5 ms** (Auth/Offer), **< 1,000 ms** (Batch), **< 5 s** (Reports) |

---

## 2. Workload Classification & Performance Objectives

1. **Customer-Facing / Real-Time (OLTP):**
   - High frequency, interactive, user-facing queries (`R01`, `R02`, `R03`, `R04`, `R05`, `R06`, `R07`, `R09`, `R23`, `W01`, `W02`, `W03`, `W05`).
   - Must avoid sequential scans (`Seq Scan`) entirely and rely on targeted B-tree indexes, partial indexes, and trigram/GIN indexes to consistently achieve sub-5ms execution times.
2. **Interactive Internal Tools & Queues:**
   - Operational tools used by customer service and moderators (`R10`, `R11`, `R13`, `R16`, `R22`).
   - Target latency is strictly **under 250 ms** to ensure snappy console rendering and rapid intervention.
3. **Reporting & Analytics (OLAP):**
   - Complex joins, aggregations, window functions, and historical scans (`R08`, `R12`, `R14`, `R15`, `R17`, `R18`, `R19`, `R20`, `R21`, `R24`, `R25`).
   - Target latency is strictly **under 5,000 ms** without blocking concurrent transactional updates.
4. **Automated Batch Jobs:**
   - Scheduled maintenance jobs such as ad expiration sweep (`W04`).
   - Target execution time is strictly **under 1,000 ms** to prevent row locking and table bloat.

---

## 3. Assumptions & Architectural Boundaries

1. **Schema Namespace:** All marketplace entities and constraints reside inside the dedicated PostgreSQL schema `olx` (`SET search_path TO olx;`).
2. **Data Consistency & Integrity:** The seed dataset consists of 120,000 listings across 11 CSV entities. The rebuilt schema enforces declarative relational integrity (`FOREIGN KEY`), domain constraints (`CHECK`), candidate keys (`UNIQUE`), and non-nullable guarantees without dropping valid seed data.
3. **No External Caching or Engine Alterations:** All optimizations must be accomplished strictly within PostgreSQL 15+ engine capabilities (indexing strategies, query plan refactoring, covering indexes, partition pruning, and `VACUUM/ANALYZE` statistics tuning). Modifying hardware settings or disabling planner defaults (e.g., `enable_seqscan = off`) is strictly prohibited.
4. **Semantic Preservation:** All query optimizations in later phases must produce identical result sets and schemas compared to `queries/workload_30.sql`. Any discrepancy (such as the three-valued logic flaw in `R13`) must be rigorously documented and justified.
