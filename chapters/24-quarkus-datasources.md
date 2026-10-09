---
hide:
  - toc
---

# 24. Quarkus Datasources and JDBC

**You will learn:** how a Quarkus application obtains and uses PostgreSQL connections, how Agroal pooling changes connection ownership, how SQL types map to Java, and why timeouts and result-set size are correctness concerns rather than optional tuning.

This chapter uses imperative JDBC. Quarkus also has reactive PostgreSQL clients, but imperative and reactive code have different transaction and execution models. Learn one model clearly before mixing them.

## From an HTTP request to PostgreSQL

A typical request follows this path:

```
request -> resource -> service -> repository -> Agroal pool -> JDBC connection -> PostgreSQL
```

- The **resource** translates HTTP input and output.
- The **service** owns the business operation and usually the transaction boundary.
- The **repository** contains SQL and row mapping.
- **Agroal** keeps a bounded set of reusable database connections.
- The PostgreSQL JDBC driver sends statements and values over a connection.

These responsibilities are not rigid framework rules, but separating them makes transaction boundaries, tests, and failures easier to see. SQL hidden across resource classes and entity callbacks is much harder to reason about.

## Dependencies and configuration

For direct JDBC, use the Quarkus PostgreSQL JDBC extension. Agroal provides the pool.

```xml
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-jdbc-postgresql</artifactId>
</dependency>
```

Development configuration can use environment-variable expressions with local defaults:

```properties
quarkus.datasource.db-kind=postgresql
quarkus.datasource.jdbc.url=${DB_URL:jdbc:postgresql://localhost:5432/shop}
quarkus.datasource.username=${DB_USERNAME:learner}
quarkus.datasource.password=${DB_PASSWORD:learner}
quarkus.datasource.jdbc.min-size=2
quarkus.datasource.jdbc.max-size=16
quarkus.datasource.jdbc.acquisition-timeout=5S
```

`${DB_URL:...}` means "use `DB_URL` when present; otherwise use this local default." Defaults are convenient for a learning environment. Production credentials belong in a secret store or deployment environment, not in source control.

`max-size` is a limit, not a throughput target. When all 16 connections are busy, another request waits up to the acquisition timeout. That waiting is deliberate backpressure: creating unlimited connections would move the overload into PostgreSQL and usually make every request slower.

## Pool sizing

PostgreSQL has a finite connection budget. If a database allows 200 connections, some must remain for administrators, migrations, monitoring, and background jobs. Ten application instances with pools of 50 could request 500 connections and cannot fit.

A starting budget is:

```
pool per instance <= (database limit - reserved connections) / maximum app instances
```

Use a lower value until measurements show that database concurrency, rather than slow queries or application work, is the bottleneck. A waiting pool is often healthier than hundreds of queries competing for CPU and disk.

Watch both sides:

- application: active, available, and waiting pool connections;
- database: total sessions, active sessions, wait events, and query latency.

## Borrow, use, close

Inject the pooled datasource:

```java
@ApplicationScoped
public class CustomerRepository {
    @Inject
    AgroalDataSource dataSource;

    public Optional<Customer> findByEmail(String email) throws SQLException {
        String sql = """
            SELECT id, email, name, country, phone, created_at
            FROM customers
            WHERE email = ?
            """;

        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, email);

            try (ResultSet rows = statement.executeQuery()) {
                if (!rows.next()) {
                    return Optional.empty();
                }
                return Optional.of(mapCustomer(rows));
            }
        }
    }
}
```

`close()` on a pooled connection normally **returns it to the pool**; it does not close the server connection. The `try` blocks still matter because they return scarce resources on success and failure. A leaked connection eventually exhausts the pool.

Do not store a `Connection`, `PreparedStatement`, or `ResultSet` in a field. They represent short-lived, stateful work and are not safe to share between requests or threads.

## Parameters are part of correctness

`?` is a value placeholder. `setString(1, email)` sends the value separately from SQL syntax, preventing it from becoming executable SQL.

Parameters also communicate types. Use the setter matching the database type where practical:

```java
statement.setLong(1, customerId);
statement.setBigDecimal(2, price);
statement.setObject(3, orderId);              // UUID
statement.setObject(4, occurredAt);           // OffsetDateTime
statement.setNull(5, Types.VARCHAR);
```

Parameters cannot stand for table names, column names, or `ASC`/`DESC`. Map such choices to a fixed whitelist in Java rather than concatenating arbitrary input.

## Mapping PostgreSQL values

| PostgreSQL | Java choice | Important detail |
|---|---|---|
| `bigint` | `long` / `Long` | use `Long` when SQL `NULL` is possible |
| `numeric` | `BigDecimal` | do not use `double` for money |
| `boolean` | `boolean` / `Boolean` | wrapper preserves `NULL` |
| `text` | `String` | decide whether empty and missing mean different things |
| `date` | `LocalDate` | has no time or zone |
| `timestamptz` | `OffsetDateTime`, then often `Instant` | represents an absolute instant |
| `uuid` | `UUID` | supported by modern PostgreSQL JDBC |
| `jsonb` | JSON library type or validated `String` | keep serialization at a clear boundary |
| arrays | Java array or `java.sql.Array` | relational child tables are often easier for complex elements |

Primitive JDBC getters can hide `NULL`:

```java
long value = rows.getLong("optional_number");  // returns 0 for SQL NULL too
if (rows.wasNull()) {
    // the database value was NULL
}
```

Prefer a nullable object when zero is a legitimate value:

```java
Long value = rows.getObject("optional_number", Long.class);
```

A mapper should make every conversion visible:

```java
private Customer mapCustomer(ResultSet rows) throws SQLException {
    OffsetDateTime created = rows.getObject("created_at", OffsetDateTime.class);
    return new Customer(
        rows.getLong("id"),
        rows.getString("email"),
        rows.getString("name"),
        rows.getString("country"),
        rows.getString("phone"),
        created.toInstant()
    );
}
```

## Session state and pooled connections

A physical connection is reused by unrelated requests. Session-wide changes can therefore leak:

```sql
SET TIME ZONE 'Asia/Tokyo';
SET app.customer_id = '42';
```

Prefer transaction-local settings:

```sql
BEGIN;
SET LOCAL TIME ZONE 'UTC';
SET LOCAL app.customer_id = '42';
-- queries
COMMIT;
```

`SET LOCAL` ends with the transaction. This is especially important for row-level security context. The application must also roll back failed transactions before returning connections; transaction frameworks normally handle this, but manual JDBC code must do it explicitly.

## Timeouts have different jobs

| Timeout | Protects against |
|---|---|
| pool acquisition timeout | waiting forever for an application connection |
| connection timeout | waiting forever while opening a network connection |
| `statement_timeout` | a query running too long |
| `lock_timeout` | waiting too long for a database lock |
| `idle_in_transaction_session_timeout` | an abandoned open transaction |
| HTTP/request timeout | a client waiting too long for the whole operation |

A request timeout does not automatically prove that PostgreSQL stopped the query. Coordinate application cancellation and database timeouts so abandoned work does not continue consuming resources.

Set stable defaults on the application role, then use `SET LOCAL` for operations that genuinely need a different limit:

```sql
ALTER ROLE app SET statement_timeout = '5s';
ALTER ROLE app SET lock_timeout = '2s';
ALTER ROLE app SET idle_in_transaction_session_timeout = '15s';
```

## Large result sets and streaming

Loading a million rows into an `ArrayList` can exhaust application memory. PostgreSQL JDBC can fetch incrementally, but cursor-style fetching requires autocommit to be disabled:

```java
try (Connection connection = dataSource.getConnection()) {
    connection.setAutoCommit(false);

    try (PreparedStatement statement = connection.prepareStatement(sql)) {
        statement.setFetchSize(500);

        try (ResultSet rows = statement.executeQuery()) {
            while (rows.next()) {
                consume(mapRow(rows));
            }
        }
    } finally {
        connection.rollback(); // read-only work; also closes the transaction promptly
    }
}
```

`fetchSize` is a batch hint, not a row limit. The transaction stays open while rows are consumed, so process them promptly. For user-facing APIs, pagination is usually better than holding a streaming transaction open.

## What belongs in a repository?

A repository method should make these points easy to inspect:

- the SQL text;
- every bound parameter;
- the expected number of rows;
- the row-to-Java mapping;
- how no-row and too-many-row cases are handled;
- which exception leaves the method.

Avoid a generic "execute any SQL and return a map" helper. It removes type information and hides assumptions exactly where correctness matters.

## Exercises

1. Draw the path from an HTTP request to PostgreSQL in your application. Mark where a connection is borrowed and returned.
2. If PostgreSQL permits 120 connections, 20 are reserved, and the service can scale to 10 instances, what is the absolute per-instance pool ceiling? Why should the configured pool probably be smaller?
3. Write a repository method that loads a nullable `phone` and a `timestamptz` without losing the distinction between `NULL`, empty text, and an actual value.
4. Explain why `SET app.customer_id = '42'` is dangerous with a pool and why `SET LOCAL` is safer.
5. Add statement, lock, pool acquisition, and HTTP timeouts to a diagram. Which one fires when a query is blocked on a row lock?
6. Stream a report with a fetch size. Explain why the method must not perform slow remote calls while iterating.

??? note "Solutions"

    1. The pool boundary is between repository/service code and JDBC. Borrow as late as practical and return immediately after the database operation or transaction.
    2. The mathematical ceiling is 10. A smaller starting value leaves room for uneven scaling, deployment overlap, jobs, and estimation error. Measure pool waits and database saturation before increasing it.
    3. Use `getString` for `phone` (`null` remains distinguishable from `""`) and `getObject("created_at", OffsetDateTime.class)` followed by `toInstant()`.
    4. Session state survives connection reuse. `SET LOCAL` is scoped to the current transaction and is removed at commit/rollback.
    5. `lock_timeout` specifically limits the lock wait. A shorter statement or request timeout could fire first, so timeout ordering should be intentional.
    6. Streaming holds a connection and transaction. A remote call can be slow or fail, leaving a snapshot open and one pool slot unavailable. Transform or export promptly, or decouple remote delivery from the read.

Next: [25. Transactions, Retries and Idempotency](25-quarkus-transactions.md)
