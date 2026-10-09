---
hide:
  - toc
---

# 29. Production Configuration and Runbooks

**You will learn:** how to turn database knowledge into production limits, health signals, failover behavior, and short incident runbooks that help operators act safely under pressure.

Production readiness is not a property of one configuration file. It is the combination of bounded resources, observable behavior, tested recovery, and people knowing what to do when assumptions fail.

## Configuration by environment

Keep the same application artifact across environments and inject environment-specific values:

```properties
%prod.quarkus.datasource.jdbc.url=${DB_URL}
%prod.quarkus.datasource.username=${DB_USERNAME}
%prod.quarkus.datasource.password=${DB_PASSWORD}
%prod.quarkus.datasource.jdbc.min-size=${DB_POOL_MIN:2}
%prod.quarkus.datasource.jdbc.max-size=${DB_POOL_MAX:16}
%prod.quarkus.datasource.jdbc.acquisition-timeout=${DB_ACQUIRE_TIMEOUT:5S}
```

Configuration names can be committed; credentials cannot. Use the platform's secret mechanism and define a rotation process. A secret that cannot be rotated without an outage is an operational risk.

Validate required production values at startup. Silently falling back to a local database or default credential is worse than failing clearly.

## TLS and server identity

Encryption without identity verification can still connect to the wrong server. For a directly managed PostgreSQL connection, a production URL may require:

```text
jdbc:postgresql://db.example.com:5432/shop?sslmode=verify-full
```

`verify-full` verifies encryption, the certificate chain, and the hostname. Supply trusted certificate authorities through the runtime environment as required by your driver and platform.

Managed database providers may prescribe a different certificate setup. Follow their rotation guidance and test certificate renewal before expiry.

## Build a connection budget

Start with database capacity:

```text
max_connections
- administrative reserve
- migration/monitoring/jobs reserve
= application budget
```

Then divide by the **maximum simultaneous application instances**, including old and new replicas during deployment:

```text
per-instance max pool <= application budget / peak instance count
```

Example:

```text
200 total - 30 reserved = 170
20 instances during rollout
absolute ceiling = 8 connections per instance (with margin still needed)
```

Do not round upward and assume every other service will be quiet. Record ownership of the budget when multiple applications share a database.

If application instances number in the hundreds, consider PgBouncer. Transaction pooling reuses server connections aggressively, but session state, temporary tables, prepared-statement behavior, and advisory session locks require review. Pooling changes semantics, not only performance.

## Timeout hierarchy

Timeouts should fail from the inside outward:

```text
lock timeout < statement timeout < request timeout < upstream timeout
```

For example:

```text
lock timeout       2 s
statement timeout  5 s
request timeout    8 s
gateway timeout   10 s
```

This ordering gives PostgreSQL time to cancel and the application time to roll back and return a meaningful response before the caller gives up.

Not every endpoint needs the same statement limit. A controlled report may have a separate role or transaction-local timeout. Avoid disabling timeouts globally for one exceptional query.

## Health checks

**Liveness** asks: "Is this process fundamentally able to run?"  
**Readiness** asks: "Should this instance receive traffic now?"

Database unavailability usually makes a database-dependent service **not ready**. It should not necessarily make it **not live**. If every instance restarts because PostgreSQL is briefly unavailable, the restart storm adds connection pressure during recovery.

A useful readiness check is bounded and cheap. It should not execute a large business query. Health endpoints also need rate limits or platform-controlled polling so they do not become load.

Startup checks may verify required migrations, but application runtime should not own schema changes unless that deployment model was chosen deliberately in chapter 26.

## Metrics that explain saturation

Monitor the path from request to storage:

| Layer | Signals |
|---|---|
| HTTP | request rate, errors, latency percentiles, in-flight requests |
| pool | active, available, waiting, acquisition timeouts |
| transaction | duration, rollback count, retry count |
| SQL | total/mean/p95 latency, calls, rows, timeout count |
| PostgreSQL | active sessions, wait events, locks, CPU, I/O, cache, WAL |
| maintenance | dead tuples, autovacuum progress, transaction-id age |
| replication | byte/time lag, replay state |
| outbox | unpublished count, oldest age, attempts, failures |

An average hides a slow tail. Track percentiles and error counts. A pool at maximum size is not automatically bad; a growing wait queue and rising latency show saturation.

Enable `pg_stat_statements` and set a recognizable application name:

```text
jdbc:postgresql://db.example.com/shop?ApplicationName=orders-service
```

Use low-cardinality metric labels. Customer IDs, SQL text, request IDs, and event IDs create unbounded time series; keep those in trace/log context instead.

## Logs and tracing

For a failed database operation, useful structured fields include:

- service and instance;
- trace/request ID;
- operation name (not necessarily full SQL);
- SQLSTATE and constraint name;
- attempt number;
- elapsed time;
- whether the transaction rolled back.

Do not log credentials, full payment details, arbitrary JSON payloads, or all bound parameter values. Observability must not become a data leak.

Distributed tracing can show pool wait, SQL duration, and downstream calls, but trace sampling must still capture errors and unusually slow operations.

## Failover from the application's view

During database failover:

1. existing connections break or become read-only;
2. in-flight transactions have uncertain outcomes;
3. the pool discards bad connections and tries to establish new ones;
4. DNS, proxy, or provider endpoint moves to the new primary;
5. many application instances may reconnect simultaneously.

The application must expect transient connection errors. Retry only operations that are safe:

- reads may usually retry;
- serialization/deadlock failures retry the full transaction;
- writes with uncertain commit need idempotency before retry;
- non-idempotent external effects must not be repeated blindly.

Use bounded backoff with jitter for reconnection and operation retries. Without jitter, every replica can hit the recovering primary at once.

Test failover. Documentation that says "the provider handles it" does not establish application behavior, recovery time, or duplicate risk.

## Read replicas and stale data

Replicas can reduce reporting load but are asynchronously replayed unless configured otherwise. A write committed on the primary may not appear immediately on a replica.

Decide endpoint semantics:

- account balance after a transfer: probably primary/read-your-writes;
- product search: replica staleness may be acceptable;
- long report: replica may be ideal;
- transaction that reads then writes: use the primary.

Do not randomly route reads without defining what stale results mean to users.

## Runbook: connection pool exhaustion

**Symptoms:** acquisition timeouts, requests waiting, pool active at maximum.

**Inspect:**

1. Are connections active or leaked?
2. Are queries slow or blocked?
3. Are transactions idle?
4. Did traffic or instance count change?
5. Is PostgreSQL itself saturated?

**Act:**

- cancel/repair the specific runaway work when safe;
- shed load or reduce concurrency;
- fix leaked resources or long transaction scope;
- scale only after confirming database capacity.

**Do not:** immediately multiply pool size. That can convert a contained queue into database-wide overload.

## Runbook: blocked queries or migration

**Symptoms:** rising lock waits, DDL not completing, unrelated traffic queuing.

**Inspect:**

```sql
SELECT pid, pg_blocking_pids(pid), state, xact_start, wait_event, query
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0;
```

Identify the blocker, its transaction age, owner, and business purpose.

**Act:**

- let short legitimate work finish;
- cancel the migration if its lock queue threatens availability;
- terminate a blocker only with authorization and understanding of rollback impact;
- retry DDL with a short `lock_timeout` in a safer window.

**Do not:** kill sessions by guesswork or repeatedly rerun waiting DDL.

## Runbook: slow-query regression

**Symptoms:** latency percentile rises, database CPU/I/O changes, one query dominates total time.

**Inspect:**

1. compare `pg_stat_statements` calls, total time, and mean time;
2. capture `EXPLAIN (ANALYZE, BUFFERS)` safely on representative input;
3. compare estimated and actual rows;
4. check statistics, data distribution, recent migrations, and plan changes;
5. inspect lock and I/O waits.

**Act:** fix the demonstrated cause—query, index, statistics, excessive calls, or data shape—and measure again.

**Do not:** globally disable plan types or raise memory blindly.

## Runbook: outbox backlog

**Symptoms:** unpublished count or oldest-event age grows.

**Inspect:**

- broker availability and acknowledgement latency;
- publisher errors and retry attempts;
- expired versus active claims;
- poison event payloads;
- database claim-query latency.

**Act:**

- restore broker/publisher health;
- quarantine a confirmed poison event with an audit trail;
- increase publisher concurrency only within broker and database capacity;
- verify consumers tolerate the resulting duplicates.

**Do not:** mark events published without broker confirmation.

## Runbook: replica lag

**Symptoms:** stale reads, replay lag alerts, WAL accumulation.

**Inspect:** write burst, long replica queries, network throughput, replay state, slots, and disk.

**Act:** route correctness-sensitive reads to primary, cancel an optional long replica query if appropriate, reduce/throttle heavy writes, and repair replica capacity.

**Do not:** treat a lagging replica as current merely because its health endpoint responds.

## Backups and recovery ownership

Chapter 23 described logical backups and PITR. Production readiness additionally requires named ownership:

- who receives backup-failure alerts;
- how often restore tests run;
- where restore evidence is recorded;
- who can declare data loss;
- how applications are pointed at a restored database;
- how outbox/broker replay is reconciled after point-in-time recovery.

Restoring PostgreSQL to an earlier time may cause already-published events to reappear as unpublished or remove inbox records. Recovery planning must include external systems, not only database files.

## Deployment checklist

Before release:

- migrations tested from previous production version;
- old and new versions compatible with expanded schema;
- connection budget includes deployment overlap;
- timeouts and retry bounds defined;
- dashboards and alerts cover new operations;
- rollback or forward-fix decision documented;
- outbox payload compatibility checked;
- restore/failover implications understood.

After release:

- verify migration version and constraints;
- compare error rate and latency;
- watch pool waits, locks, retries, replica lag, and outbox age;
- verify old instances drained before contract migrations.

## Exercises

1. Calculate a pool budget for your database, including deployment overlap and administrative reserve.
2. Choose lock, statement, request, and gateway timeouts and explain their order.
3. Decide whether database failure affects readiness, liveness, or both in your service.
4. Build a dashboard containing one signal from every layer in the metrics table.
5. Walk through a failover immediately after an order commit response is lost. When may the client retry safely?
6. Write a five-step connection-exhaustion runbook for your environment.
7. Restore the database conceptually to ten minutes ago. List possible inconsistencies with Kafka consumers and outbox/inbox rows.

??? note "Solutions"

    1. Subtract every non-application reserve from `max_connections`, divide by maximum simultaneous instances, then leave margin. Include old and new replicas during rolling deployment.
    2. Inner database limits should fire before outer network limits, leaving time for cancellation, rollback, and response. Values depend on the endpoint's latency objective.
    3. Usually readiness fails because the instance cannot serve database work; liveness remains healthy to avoid restart storms. A process-internal deadlock or irrecoverable startup state is a liveness concern.
    4. Include request latency/errors, pool wait, transaction retries, top SQL, database waits, autovacuum/XID age, replica lag, and outbox oldest age. Link them by service and time, not high-cardinality customer labels.
    5. The commit outcome is uncertain. Retry a write only with an idempotency key that can return the original result or prevent duplication. Blind retry may create a second order.
    6. A sound runbook confirms the symptom, distinguishes leak/slow/block/traffic causes, identifies safe immediate load reduction, names escalation/termination authority, and verifies recovery.
    7. Events published after the restore point may no longer have corresponding outbox/business rows; inbox deduplication rows may disappear; consumers may retain effects from events the database forgot. Recovery needs reconciliation, replay boundaries, and business ownership.

Back to the [table of contents](../README.md) · [Cheat sheet](../appendix/cheatsheet.md)
