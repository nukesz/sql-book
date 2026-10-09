---
hide:
  - toc
---

# 22. Using SQL from an Application (Quarkus/Java example)

**You will learn:** the language-independent concerns of direct SQL from application code, with a short Java/Quarkus illustration. Everything in this chapter applies to any language; the Java snippets are just one concrete shape.

## Principles that hold in every language

1. **Parameters, always** (chapter 20). Never concatenate input into SQL.
2. **Connection pool:** opening a PostgreSQL connection is expensive (a process per connection). Use a pool sized small (often `cores × 2` to a few dozen). More connections ≠ more throughput. Use PgBouncer if many app instances.
3. **Transaction boundaries are an application design decision.** One business operation = one transaction; keep it short; no remote calls inside.
4. **Retry** on serialization failure (`40001`) and deadlock (`40P01`), re-running the *entire* transaction.
5. **Map types deliberately:** `numeric` → `BigDecimal` (never `double`), `timestamptz` → `Instant`/`OffsetDateTime`, `uuid` → `UUID`, `jsonb` → string/JSON type.
6. **Fetch what you need,** in as few round trips as sensible: avoid N+1 (chapter 21); use `RETURNING` instead of a second query.
7. **Statement timeouts:** `SET statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout` protect the database from application mistakes.
8. **Schema changes are code:** use a migration tool and version them (chapter 23).
9. Large result sets: stream with a cursor/fetch size rather than loading everything into memory.

## Plain JDBC with Quarkus (Agroal pool)

`application.properties`:

```properties
quarkus.datasource.db-kind=postgresql
quarkus.datasource.username=learner
quarkus.datasource.password=learner
quarkus.datasource.jdbc.url=jdbc:postgresql://localhost:5432/shop
quarkus.datasource.jdbc.max-size=16
```

The repository password is intentionally simple for local learning. In a real application, inject credentials from a secret store or environment variable rather than committing them.

Dependencies: `quarkus-jdbc-postgresql`, `quarkus-agroal`, and `quarkus-rest` + `quarkus-rest-jackson` if exposing JSON.

```java
@ApplicationScoped
public class OrderRepository {

    @Inject AgroalDataSource ds;

    public record OrderSummary(long id, String status, BigDecimal total) {}

    public List<OrderSummary> recentForCustomer(long customerId, int limit) throws SQLException {
        String sql = """
            SELECT o.id, o.status, sum(oi.quantity * oi.unit_price) AS total
            FROM orders o JOIN order_items oi ON oi.order_id = o.id
            WHERE o.customer_id = ?
            GROUP BY o.id
            ORDER BY o.created_at DESC
            LIMIT ?
            """;
        try (Connection c = ds.getConnection();
             PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setLong(1, customerId);
            ps.setInt(2, limit);
            try (ResultSet rs = ps.executeQuery()) {
                var out = new ArrayList<OrderSummary>();
                while (rs.next()) {
                    out.add(new OrderSummary(rs.getLong("id"), rs.getString("status"), rs.getBigDecimal("total")));
                }
                return out;
            }
        }
    }
}
```

### A transaction with retry

```java
// (Alternatively annotate with @Transactional and let Quarkus manage the transaction.)
public void reserveStock(long productId, int qty) throws SQLException {
    for (int attempt = 1; ; attempt++) {
        try (Connection c = ds.getConnection()) {
            c.setAutoCommit(false);
            c.setTransactionIsolation(Connection.TRANSACTION_SERIALIZABLE);
            try (PreparedStatement ps = c.prepareStatement(
                    "UPDATE products SET stock = stock - ? WHERE id = ? AND stock >= ?")) {
                ps.setInt(1, qty); ps.setLong(2, productId); ps.setInt(3, qty);
                if (ps.executeUpdate() == 0) throw new IllegalStateException("not enough stock");
            }
            c.commit();
            return;
        } catch (SQLException e) {
            // 40001 serialization_failure, 40P01 deadlock_detected
            if (attempt < 3 && ("40001".equals(e.getSQLState()) || "40P01".equals(e.getSQLState()))) continue;
            throw e;
        }
    }
}
```

## Where does SQL live in code?

| Style | Trade-off |
|---|---|
| Inline strings / text blocks in repositories | simple, visible; review them like code |
| `.sql` resource files | syntax highlighting, easy to paste into psql |
| Query libraries (jOOQ, JDBI, SQLx, ...) | type-safe SQL, still *your* SQL |
| ORM (Hibernate/Panache) for simple CRUD **plus** native SQL for reports/bulk | pragmatic mix: use the right tool per query |

A good hybrid: ORM for entity CRUD, direct SQL for anything involving aggregates, window functions, bulk updates, locking, upserts, or JSON shaping. Hibernate supports `createNativeQuery`; Panache offers `getEntityManager()`.

## Testing database code

- Test against **real PostgreSQL**, not H2: SQL dialects, locking, and plans differ. Quarkus Dev Services starts a PostgreSQL container automatically for tests/dev mode (omit the URL in dev), or use Testcontainers.
- Seed small deterministic data; load schema through the same migrations used in production.
- Test concurrency behaviour explicitly (two threads, one row) for the locking-sensitive paths.

## Observability

- Set `application_name` in the connection (`ApplicationName=my-service` in the JDBC URL) so `pg_stat_activity` and logs tell you who is running what.
- Use `pg_stat_statements` (chapter 21) and slow-query logging.
- Log the SQL state and constraint name on failures; map constraint violations (e.g. `23505` unique_violation) to meaningful application errors.

| SQLSTATE | Meaning |
|---|---|
| `23505` | unique violation |
| `23503` | foreign key violation |
| `23502` | not-null violation |
| `23514` | check violation |
| `40001` | serialization failure (retry) |
| `40P01` | deadlock (retry) |
| `57014` | query canceled (e.g. statement timeout) |

## Exercises

1. Port one report from chapter 5 or 10 into a repository method returning a record list. Keep the SQL identical to what you tested in psql.
2. Write a method that inserts an order with several items in **one transaction**, using `RETURNING id` to get the order id (no second query), and a batch for the items.
3. Make an endpoint return an order as one nested JSON document using a single query (`jsonb_build_object` + `jsonb_agg`), not N+1.
4. Add a retry wrapper for `40001`/`40P01`. Provoke a deadlock with two threads to test it.
5. Set `statement_timeout` for the app role: `ALTER ROLE app SET statement_timeout = '5s';` Run `SELECT pg_sleep(10)` through it and see the error.
6. Map the unique violation on `customers.email` to an HTTP 409 response.

??? note "Solution guidance"

    1. Keep SQL in the repository method and bind every external value. Map each selected column explicitly; do not replace the tested query with per-row lookups.
    2. Disable autocommit, insert the order with `RETURNING id`, batch the item inserts on the same connection, then commit. Roll back on every failure. Validate that product ids and quantities are present before committing.
    3. Aggregate items in a correlated `LATERAL` subquery or pre-aggregated subquery so the outer query still returns one row per order. Use `coalesce(..., '[]'::jsonb)` for an order with no items.
    4. Put the **entire transaction callback** inside a bounded retry loop. Acquire a fresh transaction for each attempt; add short randomized backoff; retry only known transient SQLSTATEs.
    5. A timed-out statement reports SQLSTATE `57014`. The transaction is aborted, so roll it back before returning the connection to the pool.
    6. Catch `SQLException`, inspect SQLSTATE `23505` and preferably the constraint name, roll back, and translate only the expected email constraint to HTTP 409. Do not map every database error to "duplicate email."

Next: [23. Operations: Migrations, Backups, Monitoring](23-operations.md)
