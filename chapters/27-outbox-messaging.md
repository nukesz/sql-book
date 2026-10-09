---
hide:
  - toc
---

# 27. Outbox Messaging and External Side Effects

**You will learn:** why a database transaction cannot atomically publish to a broker, how the transactional outbox closes the lost-message gap, why duplicate delivery remains possible, and how an inbox makes consumers idempotent.

## The dual-write problem

After creating an order, an application may publish `OrderCreated` to Kafka:

```java
long orderId = createOrderInPostgres(command);
publisher.publish(new OrderCreated(orderId));
```

Two failure orders are dangerous:

- database commits, then publishing fails: the order exists but no event is sent;
- event publishes, then database commit fails: consumers act on an order that does not exist.

Reversing the two calls only reverses the failure. PostgreSQL and the broker do not share one ordinary local transaction.

## Store the intent in PostgreSQL

The **transactional outbox** stores the business change and the intent to publish in the same database transaction:

```sql
CREATE TABLE outbox_events (
    id             uuid PRIMARY KEY,
    aggregate_type text NOT NULL,
    aggregate_id   text NOT NULL,
    event_type     text NOT NULL,
    payload        jsonb NOT NULL,
    occurred_at    timestamptz NOT NULL DEFAULT now(),
    claimed_until  timestamptz,
    claimed_by     text,
    published_at   timestamptz,
    attempts       int NOT NULL DEFAULT 0
);

CREATE INDEX outbox_ready_idx
ON outbox_events (occurred_at)
WHERE published_at IS NULL;
```

The service transaction inserts both:

```sql
BEGIN;

INSERT INTO orders (customer_id, status)
VALUES (?, 'new')
RETURNING id;

INSERT INTO outbox_events
    (id, aggregate_type, aggregate_id, event_type, payload)
VALUES
    (?, 'order', ?, 'OrderCreated', ?::jsonb);

COMMIT;
```

If the transaction rolls back, neither row exists. If it commits, the event remains durably available even when the broker is down.

The outbox is not the broker message itself. It is a durable statement: "this committed business operation needs this event published."

## Event identity and payload

Generate the event UUID once and preserve it through every retry. Consumers use it to recognize duplicate delivery.

Include enough context for a consumer to understand the event without querying mutable state immediately:

```json
{
  "schemaVersion": 1,
  "orderId": 12345,
  "customerId": 42,
  "occurredAt": "2026-10-08T09:00:00Z"
}
```

`schemaVersion` supports payload evolution. Events are historical facts; changing today's order row should not change what an old event meant.

Avoid putting secrets or unnecessary personal data in events. Broker retention and access may differ from the source database.

## Claim work in a short transaction

Multiple publisher instances must not intentionally process the same row at once. Claim a batch atomically:

```sql
WITH ready AS (
    SELECT id
    FROM outbox_events
    WHERE published_at IS NULL
      AND (claimed_until IS NULL OR claimed_until < now())
    ORDER BY occurred_at, id
    LIMIT 100
    FOR UPDATE SKIP LOCKED
)
UPDATE outbox_events e
SET claimed_until = now() + interval '30 seconds',
    claimed_by = ?,
    attempts = attempts + 1
FROM ready
WHERE e.id = ready.id
RETURNING e.*;
```

Commit immediately after claiming. The publisher then sends messages **outside** the database transaction and marks successful rows:

```sql
UPDATE outbox_events
SET published_at = now(),
    claimed_until = NULL,
    claimed_by = NULL
WHERE id = ?
  AND claimed_by = ?;
```

Why not hold the row lock while publishing? A broker call can be slow. Keeping a transaction open would hold locks, consume a connection, retain an MVCC snapshot, and couple database health to broker latency.

The lease (`claimed_until`) allows recovery when a publisher crashes. After it expires, another worker can claim the row.

## At-least-once delivery

Consider this sequence:

1. publisher sends the message successfully;
2. publisher crashes before setting `published_at`;
3. the lease expires;
4. another publisher sends it again.

The outbox prevents a committed event from being silently lost, but it cannot eliminate this duplicate window without a distributed protocol. The practical contract is **at least once**: an event is delivered one or more times.

"Exactly once" claims often mean deduplication within a limited boundary. Ask exactly once **where**, **for how long**, and **under which failures**.

## Consumer inbox

A consumer records processed event IDs in the same transaction as its own database changes:

```sql
CREATE TABLE inbox_events (
    consumer_name text NOT NULL,
    event_id      uuid NOT NULL,
    processed_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (consumer_name, event_id)
);
```

Processing flow:

```sql
BEGIN;

INSERT INTO inbox_events (consumer_name, event_id)
VALUES ('shipping', ?)
ON CONFLICT DO NOTHING
RETURNING event_id;

-- Continue only if INSERT returned a row.
-- Apply shipping-side database changes.

COMMIT;
```

If the inbox insert conflicts, this consumer already committed the event and can acknowledge the duplicate without repeating the effect.

The inbox and business change must share one transaction. Recording the inbox first in a separate transaction could lose the business action; recording it afterward could duplicate the action.

## Ordering

Global ordering is expensive and usually unnecessary. What often matters is order **per aggregate**, for example `OrderCreated` before `OrderCancelled` for the same order.

Possible strategies:

- publish each aggregate to the same broker partition using `aggregate_id` as the key;
- include a monotonically increasing aggregate version;
- have consumers reject, delay, or reconcile out-of-order versions.

Database `occurred_at` values alone are not a complete ordering guarantee: timestamps can tie, and separate transactions can commit in a different order from when they started.

## Failures, retries, and poison events

Track attempts and expose age of the oldest unpublished event. Repeated failure needs an explicit policy:

- transient broker error: release/expire the lease and retry with backoff;
- invalid payload caused by a bug: stop retrying forever, alert, and move to a reviewed dead-letter state;
- partial batch success: mark only confirmed events as published.

Do not silently mark a failed event as published. That turns an operational problem into permanent data loss.

## Polling versus change data capture

The polling publisher described here is simple and controlled by the application. Change data capture tools such as Debezium can read committed outbox rows from PostgreSQL WAL and publish them.

CDC reduces polling and custom worker logic, but adds connector operations, replication slots, schema configuration, and monitoring. The core contract remains the same: business data and outbox row commit together, and consumers tolerate duplicates.

## Quarkus structure

A useful separation is:

- transactional service: writes business rows and outbox rows;
- scheduled or continuously running publisher: claims and publishes;
- broker consumer: validates payload and invokes an inbox-protected service;
- metrics: unpublished count, oldest age, attempts, publish latency, and failures.

Do not publish directly from a transaction callback as the only mechanism. Process crashes and uncertain commit outcomes still create gaps.

## Retention

Published outbox and inbox rows grow forever unless managed. Retain them long enough for:

- broker retry and replay windows;
- consumer deduplication guarantees;
- audit and incident investigation.

Delete in batches or partition by time. Removing inbox records shortens the period in which duplicates are recognized, so document that guarantee.

## Exercises

1. Draw the two failure windows in "commit, then publish" and "publish, then commit."
2. Add an outbox insert to order creation. Which columns identify the event and its aggregate?
3. Explain every clause in the claim query, including `SKIP LOCKED` and the lease.
4. Show the crash point that causes duplicate delivery after a successful publish.
5. Design an inbox-protected shipping consumer. Which statements share a transaction?
6. An order is created and immediately cancelled. Design a per-order ordering strategy.
7. Choose outbox and inbox retention periods and describe what guarantee ends when each row is deleted.

??? note "Solutions"

    1. Commit-first can lose the event; publish-first can expose an event for rolled-back data. There is no safe ordering of two independent writes.
    2. `id` is stable event identity. `aggregate_type` and `aggregate_id` identify the business stream. `event_type`, versioned payload, and occurrence time describe the fact.
    3. The query selects only unpublished and unclaimed/expired rows, orders them deterministically, limits work, skips rows held by other workers, then records a recoverable lease and attempt atomically.
    4. The broker acknowledges publication and the process dies before the database update of `published_at`. The next worker cannot know it was already sent.
    5. Insert the inbox key and apply shipping changes in one transaction. A conflict means the prior transaction already committed, so the duplicate performs no business change.
    6. Use `order_id` as the broker partition key and include order version 1 and 2. Consumers track the last applied version and do not apply version 2 before version 1 without a reconciliation policy.
    7. Published outbox retention controls audit/replay evidence; inbox retention controls deduplication duration. Deleting an inbox row permits an old event to be applied again.

Next: [28. Testing Database Applications](28-database-testing.md)
