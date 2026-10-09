---
hide:
  - toc
---

# 28. Testing Database Applications

**You will learn:** how to test Quarkus database code against real PostgreSQL, how to separate unit and integration tests, how to reproduce concurrency and failure behavior, and how to verify migrations rather than only the latest schema.

## What a database test must prove

A repository test is not merely checking Java control flow. It may need to prove:

- PostgreSQL accepts the SQL syntax;
- parameters have the intended types;
- constraints enforce the rule;
- rows map correctly, including `NULL`;
- the transaction commits or rolls back as expected;
- concurrent operations preserve an invariant;
- migrations upgrade real old data;
- timeout, deadlock, and retry paths behave correctly.

A mock cannot prove those properties. Mocks remain useful for isolated service decisions, but database behavior requires PostgreSQL.

## A practical test pyramid

| Test kind | Purpose | Database? |
|---|---|---|
| unit | pure calculations, validation, retry-decision logic | no |
| repository integration | SQL, mapping, constraints | real PostgreSQL |
| service integration | transactions and multiple repositories | real PostgreSQL |
| concurrency | locks, conflicts, retries | real PostgreSQL with separate connections |
| migration | install and upgrade paths | real PostgreSQL |
| system/load | HTTP, pool, database, broker, realistic volume | full environment |

Not every test must start the world. Use the smallest level that can prove the property.

## Quarkus Dev Services

With the PostgreSQL JDBC extension and container support available, Quarkus Dev Services can start an isolated PostgreSQL instance for development and tests when no explicit JDBC URL is configured.

Test configuration can omit the production location:

```properties
# application.properties
quarkus.datasource.db-kind=postgresql

# production profile
%prod.quarkus.datasource.jdbc.url=${DB_URL}
%prod.quarkus.datasource.username=${DB_USERNAME}
%prod.quarkus.datasource.password=${DB_PASSWORD}
```

Flyway should create the test schema using the same migrations as production. Hand-written test DDL that differs from migrations makes tests pass against a schema production never has.

Dev Services optimizes developer setup, not test semantics. Each test still needs deliberate data isolation.

## Deterministic test data

Prefer small rows named for the scenario:

```sql
INSERT INTO products (id, category_id, name, price, stock)
OVERRIDING SYSTEM VALUE
VALUES (9001, 1, 'limited-stock-product', 10.00, 2);
```

Explicit test identifiers make failures readable. If explicit identity values affect later generated IDs, reset or isolate the database appropriately.

Avoid assertions such as "the third seeded customer happens to be German." Seed exactly the facts the test needs and assert business output, not incidental row order.

Every query using `LIMIT` in a deterministic test should have a deterministic `ORDER BY`, including a unique tie-breaker.

## Isolation strategies

Common choices:

1. **Transaction rollback per test:** fast, but code on another connection cannot see uncommitted setup.
2. **Truncate known tables:** realistic commits, but table order and foreign keys require care.
3. **Fresh schema/database per test class:** strong isolation, more startup cost.
4. **Fresh container per suite:** good suite isolation, usually too expensive per individual test.

Quarkus `@TestTransaction` runs the test in a transaction and rolls it back afterward. It is useful for ordinary repository tests, but it is the wrong tool when testing:

- asynchronous consumers;
- another thread or connection;
- commit callbacks;
- outbox publishers;
- behavior that occurs only after commit.

Those tests need committed setup and explicit cleanup or isolated schemas.

## Repository integration test

Test both the ordinary and boundary cases:

```java
@QuarkusTest
class CustomerRepositoryTest {
    @Inject CustomerRepository repository;

    @Test
    @TestTransaction
    void preservesMissingPhone() throws Exception {
        // Insert a customer with phone = NULL using a fixture helper.

        Customer customer = repository.findByEmail("no-phone@example.test")
            .orElseThrow();

        assertNull(customer.phone());
    }
}
```

Useful cases include:

- found and not found;
- nullable and non-null values;
- minimum/maximum legal values;
- duplicate unique value;
- missing foreign key;
- multiple rows when exactly one is expected;
- date/time values around zone and daylight-saving boundaries.

Do not catch the expected database exception so broadly that any failure makes the test pass. Assert SQLSTATE or the expected constraint name.

## Transaction test

To prove atomicity, create a failure after an earlier successful statement:

```java
@Test
void failedOrderRollsBackStockReservation() {
    // Arrange committed stock.
    // Invoke placeOrder with one valid line and one invalid line.
    // Assert the service throws.
    // In a new transaction, assert no order exists and stock is unchanged.
}
```

The final assertion must use a new transaction or connection. Otherwise the test may accidentally inspect the failed transaction's state or framework cache.

## Concurrency needs separate connections

One transaction cannot race with itself. A meaningful concurrency test needs:

- two independently borrowed connections or service invocations;
- a barrier controlling the interleaving;
- bounded waits so a broken test does not hang;
- final invariant checks.

Conceptual lost-update test:

```text
transaction A reads version 4
transaction B reads version 4
release both writers
exactly one UPDATE ... WHERE version = 4 succeeds
the other reports conflict
final version is 5
```

In Java, `CountDownLatch`, `CyclicBarrier`, or structured executor coordination can establish the point at which both transactions have read. Do not use arbitrary `sleep()` as the primary ordering mechanism; it creates slow, flaky tests.

Always apply timeouts to futures and database statements. On failure, collect thread stacks and `pg_stat_activity`/blocking information where the test environment permits.

## Testing retries

Separate two concerns:

1. a unit test proves which SQLSTATEs are retryable and that attempts are bounded;
2. an integration test provokes a real serialization failure or deadlock and proves the whole transaction reruns.

Instrument the operation with an attempt counter visible to the test. Assert:

- one attempt commits;
- the losing attempt rolls back;
- a fresh transaction retries;
- the invariant holds once;
- non-retryable errors are not retried;
- the maximum attempt count is honored.

Do not assert which concurrent transaction loses; PostgreSQL is allowed to choose.

## Migration tests

Use two paths.

### Clean installation

Start an empty database, apply every migration, then verify important constraints and a small application smoke test.

### Upgrade

1. construct the previous released schema by stopping Flyway at that version or restoring a fixture;
2. insert representative old and edge-case data;
3. apply the new migrations;
4. verify transformed data, constraints, indexes, and application compatibility.

An upgrade test catches failures hidden by an empty database: old `NULL`s, duplicates, invalid enum-like values, long backfills, and assumptions about existing indexes.

Migration tests should also verify that versioned files were not modified unexpectedly through Flyway validation.

## Testing the outbox

At minimum, prove:

- order and outbox row commit together;
- both roll back on failure;
- two publishers claim different rows;
- an expired claim can be reclaimed;
- a crash after publish can cause a duplicate;
- the inbox makes that duplicate harmless;
- a poison event becomes visible instead of retrying silently forever.

You do not need a real broker to prove the database claim query, but you need a broker integration test to prove serialization, headers, partition keys, acknowledgements, and consumer configuration.

## Timeout and cancellation tests

Create controlled waits:

- `pg_sleep` for statement timeout;
- one transaction holding a row lock while another waits for lock timeout;
- pool size one while a second request waits for acquisition timeout.

Assert the layer that should fail and its error mapping. Also assert cleanup:

- no connection remains `idle in transaction`;
- the failed transaction is rolled back;
- the pool returns to its normal active count;
- the application does not report success.

## Load and plan tests

Functional correctness on 20 rows does not predict behavior on 20 million. Before production:

- generate production-like volume and skew;
- run representative read and write mixes;
- watch pool waits, database CPU/I/O, locks, WAL, and latency percentiles;
- capture important query plans;
- test with realistic concurrency, not only one fast client.

Avoid brittle tests asserting an exact plan node for every query. Planner choices legitimately change with statistics, data, and PostgreSQL versions. Assert measurable requirements—such as a latency budget or bounded rows read—then inspect plans when they regress.

## Exercises

1. Classify five tests from your service as unit, repository, transaction, concurrency, migration, or system tests.
2. Explain why a test transaction that rolls back is unsuitable for an asynchronous outbox publisher.
3. Design a deterministic test for `NULL` phone mapping and one for a unique email violation.
4. Write the event ordering for an optimistic-lock race without using sleeps.
5. Design an upgrade fixture containing data most likely to break a new `NOT NULL` constraint.
6. Provoke a lock timeout and list the cleanup assertions.
7. Define a production-like load dataset: volume, skew, hot keys, and concurrent request mix.

??? note "Solutions"

    1. Classify by the behavior being proved, not by class name. SQL mapping needs a repository integration test; all-or-nothing behavior needs a service transaction test; lock behavior needs concurrency.
    2. The publisher uses another transaction/connection and cannot see uncommitted outbox rows. If the test rolls back, no committed event ever becomes publishable.
    3. Insert an explicit customer with `phone NULL` and assert Java `null`. For uniqueness, insert one email, attempt another, and assert SQLSTATE `23505` plus the intended constraint.
    4. Use two transactions and a barrier after both read version 4. Release both updates, await bounded futures, assert one success and one conflict.
    5. Include `NULL`, empty, duplicate, maximum-length, and historically valid-but-now-invalid values. The migration must clean or reject them deliberately.
    6. Hold a row lock in A; update it in B with a short `lock_timeout`. Assert the expected SQLSTATE/error mapping, B rollback, no idle transaction, and pool recovery.
    7. A useful design states row counts, country/status distribution, a few hot customers/products, read/write percentages, transaction sizes, and target concurrency. Uniform random data often hides hot-key contention.

Next: [29. Production Configuration and Runbooks](29-production-runbooks.md)
