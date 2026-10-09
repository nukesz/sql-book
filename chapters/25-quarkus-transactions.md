---
hide:
  - toc
---

# 25. Transactions, Retries and Idempotency

**You will learn:** where transaction boundaries belong in a Quarkus service, why retries need a fresh transaction, how optimistic locking detects concurrent edits, and how idempotency prevents duplicate business operations.

## One business operation, one transaction

Suppose placing an order must:

1. create the order;
2. reserve stock;
3. insert its lines.

If step 3 fails, steps 1 and 2 must not remain committed. The **service method** knows that these statements form one business operation, so it is the natural transaction boundary:

```java
@ApplicationScoped
public class OrderService {
    @Inject OrderRepository orders;
    @Inject ProductRepository products;

    @Transactional
    public long placeOrder(CreateOrder command) {
        long orderId = orders.insert(command.customerId());

        for (RequestedItem item : command.items()) {
            boolean reserved = products.reserve(item.productId(), item.quantity());
            if (!reserved) {
                throw new OutOfStockException(item.productId());
            }
            orders.insertItem(orderId, item);
        }

        return orderId;
    }
}
```

`@Transactional` begins a transaction before the method and commits after successful return. If an unchecked exception escapes, Quarkus marks the transaction for rollback. If checked exceptions should also roll it back, declare that policy explicitly:

```java
@Transactional(rollbackOn = Exception.class)
```

Do not catch an exception, log it, and return success. That creates a success-shaped failure and may allow a partial operation to commit.

## Keep the boundary visible

Good transaction boundaries are:

- around a complete business invariant;
- short;
- independent of user input pauses;
- free of remote HTTP calls, email sending, and broker publication.

A database transaction can atomically control PostgreSQL changes. It cannot atomically control a payment API or Kafka broker. Holding database locks while waiting for the network also increases latency and deadlock risk. Chapter 27 introduces the outbox pattern for this boundary.

Avoid scattering `@Transactional` across repositories. Nested annotations and propagation rules then make it difficult to know which operation owns commit. A useful default is:

- resource: no transaction;
- service: transaction boundary;
- repository: assumes the caller's transaction and performs SQL.

## If you use Hibernate or Panache

Hibernate adds a **persistence context**: loaded entities are tracked, and changed entities may be written automatically when the context flushes. `persist()` therefore does not necessarily mean "the `INSERT` has already reached PostgreSQL." SQL may run before a later query, on an explicit `flush()`, or during transaction commit.

Consequences:

- a constraint violation may appear at flush/commit rather than on the line calling `persist`;
- lazy relationships should not be read after the transaction/persistence context closes;
- returning mutable managed entities from the service can cause accidental later writes;
- tests that need to assert a database error at a particular point may need an explicit flush.

Panache makes common operations concise, but it does not remove transaction, locking, or SQL semantics. Use generated SQL logging selectively in development and inspect the actual queries for N+1 access and unexpected updates.

## Atomic SQL before explicit locking

Stock reservation is a conditional state transition:

```sql
UPDATE products
SET stock = stock - ?
WHERE id = ?
  AND stock >= ?;
```

If the affected-row count is one, stock was reserved. If it is zero, either the product does not exist or stock is insufficient; query separately only if the distinction matters.

This single statement is race-safe because PostgreSQL locks and rechecks the row condition. A read-then-write sequence is not:

```java
int stock = products.readStock(id);
if (stock >= quantity) {
    products.writeStock(id, stock - quantity); // another transaction may have changed it
}
```

Use `SELECT ... FOR UPDATE` only when the decision cannot be expressed as one conditional statement.

## Optimistic locking

For user edits, holding a row lock while someone fills in a form is impossible. Instead, detect whether the row changed since it was read:

```sql
ALTER TABLE products
ADD COLUMN version bigint NOT NULL DEFAULT 0;
```

Read `version` with the product, then include it in the update:

```sql
UPDATE products
SET name = ?,
    price = ?,
    version = version + 1
WHERE id = ?
  AND version = ?;
```

Zero updated rows means the product was deleted or another writer changed it first. Return a conflict to the caller instead of silently overwriting newer data. This is **optimistic** because writers do not block each other while editing; they detect the conflict at write time.

## Retry means repeat the whole transaction

PostgreSQL can abort a transaction with:

- `40001`: serialization failure;
- `40P01`: deadlock detected.

After either error, the transaction cannot continue. Retrying only the failed statement is wrong because previous reads and writes belonged to the old transaction. Roll back and run the complete business operation in a new transaction.

Conceptually:

```java
for (int attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
        return runWholeOperationInNewTransaction(command);
    } catch (SQLException failure) {
        if (!isRetryable(failure) || attempt == maxAttempts) {
            throw failure;
        }
        sleepWithJitter(attempt);
    }
}
```

Important properties:

- **bounded:** never retry forever;
- **fresh transaction:** every attempt obtains a new snapshot and transaction;
- **backoff with jitter:** concurrent losers do not retry in lockstep;
- **observable:** count retries and final failures;
- **selective:** constraint violations and bad input are not transient.

With declarative transactions, put the retry loop **outside** the transactional method, often in a separate CDI bean, so each invocation receives a fresh interceptor-managed transaction. Programmatic Quarkus transactions are another option when the boundary needs to be explicit.

## Why retries can duplicate work

The application may lose the connection immediately after PostgreSQL commits. It sees an exception but cannot know whether the commit happened. If it repeats "create order," two orders may be created.

The same problem occurs when a client times out and sends the HTTP request again. Transaction retries solve database conflicts; they do not by themselves make a business command safe to repeat.

## Idempotency keys

An operation is **idempotent** when repeating the same request has the same business effect as doing it once. Let the client send a unique key for each intended order:

```sql
CREATE TABLE idempotency_keys (
    key          text PRIMARY KEY,
    request_hash text NOT NULL,
    order_id     bigint REFERENCES orders (id),
    response     jsonb,
    created_at   timestamptz NOT NULL DEFAULT now()
);
```

Inside the same transaction as order creation:

1. try to insert the key;
2. if it already exists, compare `request_hash`;
3. return the stored result for the same request;
4. reject reuse of the key for different input;
5. create the order and store the result.

```sql
INSERT INTO idempotency_keys (key, request_hash)
VALUES (?, ?)
ON CONFLICT DO NOTHING
RETURNING key;
```

The primary key serializes concurrent uses of the same key. `request_hash` matters: without it, a client could accidentally reuse one key for a different cart and receive the first order's response.

Hash a canonical business representation, not arbitrary raw JSON bytes whose whitespace or object-key order can differ while meaning the same thing. Alternatively store and compare the normalized fields needed to establish that both requests have the same intent.

Do not permanently store a "started" row in one transaction and create the order in another without a recovery design. A crash between them can leave a key that blocks useful retries forever. Keeping the key and business change in one transaction avoids that gap.

## Idempotency has a retention policy

Keys consume storage. Keep them at least as long as clients or infrastructure can reasonably retry, then remove them according to a documented policy. Payment and externally visible operations may need much longer retention than ordinary API requests.

Deleting a key makes the old request executable again. Retention is therefore a business decision, not merely table cleanup.

## Error translation

Translate expected database outcomes at the service boundary:

| Outcome | Possible API response |
|---|---|
| invalid input / `CHECK` violation | 400 or 422 |
| missing referenced row | 404 or 409, depending on the contract |
| optimistic-lock conflict | 409 |
| duplicate idempotency key, same request | stored original response |
| duplicate idempotency key, different request | 409 |
| bounded retries exhausted | 503, with internal cause logged |

Use SQLSTATE and constraint names, not error-message text, because messages can change and may be localized.

## Exercises

1. Mark the transaction boundary for "create order, reserve three products, insert lines." Why is a transaction around each repository call insufficient?
2. Implement stock reservation with one conditional `UPDATE`. What does an affected-row count of zero mean?
3. Add optimistic locking to a product update. Simulate two editors that read version 4.
4. Draw three retry attempts. Show where each transaction begins and ends.
5. A commit succeeds but its network response is lost. Explain why a retry loop without an idempotency key can duplicate an order.
6. Design an idempotency response for two requests using the same key but different JSON bodies.
7. Decide how long the shop should retain order idempotency keys and explain the consequence of deleting one.

??? note "Solutions"

    1. The service transaction encloses every statement. Per-repository transactions could commit the order before stock or lines fail, violating atomicity.
    2. Use `UPDATE ... WHERE stock >= ?`. Zero means "no qualifying row"; return out-of-stock unless the API requires a separate not-found check.
    3. The first `UPDATE ... WHERE version = 4` increments to 5. The second affects zero rows and must report a conflict or reload and deliberately merge.
    4. Each failed attempt rolls back completely. Backoff occurs after rollback. The next attempt begins a new transaction and repeats all reads and writes.
    5. The application cannot distinguish "commit failed" from "commit succeeded but acknowledgement was lost." A repeated insert is a new valid insert unless a stable key identifies the original intent.
    6. Store a deterministic hash of the canonical request. Same key plus same hash returns the stored result; same key plus different hash is a conflict and creates nothing.
    7. A reasonable answer must exceed the maximum client/proxy retry window and satisfy audit requirements. Once deleted, replay can create a second order.

Next: [26. Flyway and Zero-Downtime Migrations](26-flyway-migrations.md)
