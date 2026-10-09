---
hide:
  - toc
---

# Direct SQL against PostgreSQL

A hands-on book that goes from "what is a table" to concurrency, query plans, partitioning and operations. No tooling needed beyond a PostgreSQL server and `psql` (or any SQL client).

Every chapter has:

- **You will learn:** the goal;
- Explanations with runnable examples against one shared sample database (a small web shop);
- **Exercises**, with collapsible **solutions** at the end (try first!).

This is a PostgreSQL book, not a database-neutral SQL reference. Standard SQL concepts are identified where useful, but features such as `DISTINCT ON`, `RETURNING`, `JSONB`, `LATERAL`, `ON CONFLICT`, and many administrative views are PostgreSQL-specific.

## How to use this book

- **Beginner:** read Part I in order, do every exercise.
- **Know basic SQL:** skim Part I (chapters 7 and 8 are worth a look), then work through Part II.
- **Experienced developer:** jump to Part III, or pick chapters by need; each is self-contained apart from the sample schema.
- **Quarkus/PostgreSQL developer:** learn the SQL foundations first, then read chapters 22-29 in order and perform the failure exercises with separate connections.
- Type the examples; don't paste blindly. Break things on purpose; use `BEGIN; ... ROLLBACK;` freely.
- Chapters 12, 16 and 17 need **two psql windows** open at the same time.

For each chapter, use this loop:

1. Predict what an example will do before running it.
2. Run it and explain every output column in your own words.
3. Change one condition and predict the new result.
4. Do the exercises before opening the solutions.

Examples that change schema or data may affect later examples. Unless a chapter explicitly asks you to keep a change, use a transaction and `ROLLBACK`, or reset the sample database between chapters.

## Contents

### Part I: Foundations
1. [Getting Started](chapters/01-getting-started.md): setup, psql, the sample database
2. [Relational Basics](chapters/02-relational-basics.md): tables, keys, relationships, normalization
3. [Querying with SELECT](chapters/03-select.md): filtering, sorting, paging, evaluation order
4. [Aggregation and Grouping](chapters/04-aggregation.md): `GROUP BY`, `HAVING`, `FILTER`
5. [Joins](chapters/05-joins.md): all join types, anti-joins, `LATERAL`
6. [Changing Data](chapters/06-modifying-data.md): `INSERT`, `UPDATE`, `DELETE`, `RETURNING`
7. [Data Types and NULL](chapters/07-types-and-null.md): choosing types, three-valued logic
8. [Constraints and DDL](chapters/08-ddl-constraints.md): creating schema, enforcing rules

### Part II: Intermediate
9. [Subqueries and CTEs](chapters/09-subqueries-ctes.md): including recursive and data-modifying CTEs
10. [Window Functions](chapters/10-window-functions.md): ranking, running totals, top-N per group
11. [Set Operations, Upsert and MERGE](chapters/11-sets-upsert-merge.md): `ON CONFLICT`, `COPY`
12. [Transactions and Isolation](chapters/12-transactions.md): ACID, anomalies, isolation levels lab
13. [Indexes](chapters/13-indexes.md): B-tree, GIN, partial, covering; keyset pagination
14. [Reading Query Plans](chapters/14-explain.md): `EXPLAIN (ANALYZE, BUFFERS)`, statistics
15. [JSONB, Arrays, Dates and Text Search](chapters/15-jsonb-arrays-dates-text.md)

### Part III: Advanced
16. [MVCC and Vacuum](chapters/16-mvcc-vacuum.md): how rows are stored, bloat, autovacuum
17. [Locking and Concurrency Patterns](chapters/17-locking.md): `SKIP LOCKED` queues, deadlocks, advisory locks
18. [Views, Functions and Triggers](chapters/18-views-functions-triggers.md)
19. [Partitioning](chapters/19-partitioning.md)
20. [Security](chapters/20-security.md): roles, row-level security, SQL injection
21. [Performance Tuning Workshop](chapters/21-tuning-workshop.md): method and anti-patterns
22. [Using SQL from an Application](chapters/22-from-applications.md): language-neutral advice, Quarkus/Java example
23. [Operations](chapters/23-operations.md): migrations, backups, monitoring

### Part IV: Production with Quarkus
24. [Quarkus Datasources and JDBC](chapters/24-quarkus-datasources.md): Agroal, connection ownership, type mapping, timeouts, streaming
25. [Transactions, Retries and Idempotency](chapters/25-quarkus-transactions.md): boundaries, optimistic locking, safe retries, duplicate requests
26. [Flyway and Zero-Downtime Migrations](chapters/26-flyway-migrations.md): migration workflow, rolling releases, backfills, verification
27. [Outbox Messaging and External Side Effects](chapters/27-outbox-messaging.md): reliable event publication, duplicate delivery, inbox consumers
28. [Testing Database Applications](chapters/28-database-testing.md): Dev Services, integration and concurrency tests, migration and failure testing
29. [Production Configuration and Runbooks](chapters/29-production-runbooks.md): capacity, TLS, health, metrics, failover, incident response

### Appendix
- [Cheat sheet](appendix/cheatsheet.md)