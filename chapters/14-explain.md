---
hide:
  - toc
---

# 14. Reading Query Plans

**You will learn:** how the planner thinks, how to read `EXPLAIN (ANALYZE, BUFFERS)`, and the signs of a bad plan.

## EXPLAIN

```sql
EXPLAIN SELECT * FROM orders WHERE customer_id = 123;                 -- the plan only (estimates)
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 123;         -- actually runs it, adds real timings
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;                                -- plus I/O: the most useful form
```

**`EXPLAIN ANALYZE` executes the statement.** For `UPDATE`/`DELETE`, wrap it:

```sql
BEGIN; EXPLAIN ANALYZE DELETE FROM orders WHERE status = 'cancelled'; ROLLBACK;
```

## Anatomy

```
Index Scan using orders_customer_id_idx on orders  (cost=0.29..8.31 rows=1 width=40) (actual time=0.02..0.03 rows=19 loops=1)
  Index Cond: (customer_id = 123)
  Buffers: shared hit=5
Planning Time: 0.1 ms
Execution Time: 0.05 ms
```

- Plans are **trees**; read from the innermost/most-indented node outward. Child nodes feed their parent.
- `cost=startup..total`: arbitrary units; relative, not milliseconds.
- `rows`: **estimated** rows; `actual ... rows`: what really happened. **A big mismatch is the #1 clue** (stale or insufficient statistics, correlated columns).
- `loops`: how many times the node ran; multiply actual time and rows by it.
- `Buffers: shared hit=` pages found in cache; `read=` pages fetched from disk.

## Scan nodes

| Node | Meaning |
|---|---|
| `Seq Scan` | read the whole table (fine for small tables or large fractions) |
| `Index Scan` | walk the index, fetch each row from the table |
| `Index Only Scan` | answer from the index alone |
| `Bitmap Index Scan` + `Bitmap Heap Scan` | collect matching row locations, then read pages in physical order; for moderate selectivity or combining indexes |

## Join nodes

| Node | How | Best when |
|---|---|---|
| `Nested Loop` | for each outer row, look up in inner | outer is small and inner is indexed |
| `Hash Join` | build a hash table from one side, probe with the other | larger unsorted inputs, equality joins |
| `Merge Join` | both inputs sorted, walk in parallel | already sorted inputs (indexes) or huge inputs |

None is "the best"; the planner estimates which is cheapest.

## Other nodes

`Sort` (look for `Sort Method: external merge Disk:`, which means it spilled; `work_mem` too small), `HashAggregate` / `GroupAggregate`, `Limit`, `Materialize`, `CTE Scan`, `Gather` (parallel query), `WindowAgg`.

## Statistics and the planner

PostgreSQL keeps statistics per column (distinct count, most common values, histogram) in `pg_stats`, refreshed by `ANALYZE` (autovacuum does it automatically).

```sql
SELECT attname, n_distinct, most_common_vals FROM pg_stats WHERE tablename = 'orders';
ANALYZE orders;
ALTER TABLE orders ALTER COLUMN status SET STATISTICS 1000;   -- finer stats for a skewed column
CREATE STATISTICS orders_cs (dependencies) ON customer_id, status FROM orders;  -- correlated columns
```

## A worked example

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.country, count(*), sum(oi.quantity * oi.unit_price)
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN order_items oi ON oi.order_id = o.id
WHERE o.created_at >= now() - interval '30 days'
GROUP BY c.country;
```

Read it like this:

1. Start at the node where time and row processing accumulate; node timings are inclusive of child nodes, so do not simply add them together. Remember `loops`.
2. Check estimated vs actual rows at each node.
3. Is a large table sequentially scanned to retrieve few rows? → missing/unusable index.
4. Is something sorted/hashed on disk? → `work_mem`, or fewer rows earlier.
5. Is a nested loop repeated 100,000 times? → missing index on the inner side, or a bad row estimate.

Try: run it, then `CREATE INDEX ON orders (created_at); CREATE INDEX ON order_items (order_id);` and run it again.

## Planner settings (for experiments only)

```sql
SET enable_seqscan = off;      -- discourage seq scans in this session: "would the index have been better?"
SET work_mem = '64MB';
RESET ALL;
```

Never "fix" production by disabling plan types globally; fix statistics, indexes, or the query.

## Handy tools

- `auto_explain` extension: logs plans of slow queries automatically.
- `pg_stat_statements` extension: top queries by total time. Start tuning here, not by guessing (chapter 21).
- Plan visualizers (e.g. explain.dalibo.com) help with big plans; paste `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`.

## Exercises

1. Run `EXPLAIN` (without ANALYZE) on `SELECT * FROM products WHERE id = 5`. Which node type? Why?
2. Run `EXPLAIN ANALYZE` for `SELECT * FROM orders WHERE status = 'shipped'` vs `status = 'new'`. Do they use the same strategy? Why do estimates differ (look at `pg_stats`)?
3. Make a query with `ORDER BY random() LIMIT 5` and read where the time goes.
4. Force a Hash Join vs a Nested Loop (`SET enable_hashjoin = off`) on a join of orders and customers; compare the times, then reset.
5. A plan estimates `rows=1` but gets `rows=18000` and picks a nested loop. List three things you could try.
6. Reduce `work_mem` to `64kB`, run a large `ORDER BY` on `order_items` and spot the disk sort in the plan.

??? note "Solutions"

    ```sql
    -- 1  Index Scan using products_pkey: unique primary key lookup.
    -- 2  'shipped' is ~50% of rows (seq scan is cheapest); 'new' is ~17%. With an index on status the planner may use a bitmap scan for 'new'.
    --    pg_stats.most_common_vals / most_common_freqs show the frequencies it bases estimates on.
    -- 5  ANALYZE the table; raise the column's statistics target / CREATE STATISTICS for correlated columns; rewrite the query
    --    (e.g. avoid expression on columns, split with a CTE); add an index so the alternative is cheap.
    -- 6  SET work_mem='64kB'; EXPLAIN (ANALYZE) SELECT * FROM order_items ORDER BY unit_price;  -> "Sort Method: external merge  Disk: ..."
    ```

Next: [15. JSONB, Arrays, Dates and Text Search](15-jsonb-arrays-dates-text.md)
