# RCA-003: Order search latency 25× worse – index dropped by migration

| Field | Value |
|---|---|
| Incident ID | INC-003 |
| Severity | SEV2 (degraded, not down) |
| Status | Resolved |
| Duration | ~15 min |
| Services | order-api, mysql |

## 1. Summary
A schema migration dropped the composite index `idx_orders_customer_created` on `orders(customer_email, created_at)`. `GET /orders/search` switched from an index lookup to a **full table scan of 500,000 rows**. Under concurrent load, median latency went from **54 ms to 1.3 s** (p50). Recreating the index restored performance.

## 2. Customer impact
- `/orders/search`: all requests succeeded (HTTP 200) but were slow; p50 1.31 s, max 1.42 s at 10 concurrent users (SLO: 200 ms).
- Other endpoints slowed down as well, because the 2 gunicorn workers were busy waiting on slow queries (queueing).

## 3. Timeline
| Time | Event |
|---|---|
| 10:40 | Migration dropped the index (`./scripts/chaos.sh inject 3`) |
| 10:41 | Postman test "Response time < 200 ms" fails; `api.log` shows `"slow": true` WARNING lines |
| 10:43 | Load test: p50 1.312 s |
| 10:45 | MySQL slow query log: `Rows_examined: 500023` for the search query |
| 10:47 | `EXPLAIN` → `type: ALL, key: NULL` (full scan). `SHOW INDEX` → index missing |
| 10:50 | Index recreated (`./scripts/chaos.sh fix 3`) |
| 10:52 | Load test: p50 0.054 s. EXPLAIN uses index. Resolved |

## 4. Detection
API logs flag any request over `SLOW_REQUEST_MS=200` with `"slow": true`; Postman latency assertion failed. No automatic alert existed.

## 5. Diagnosis
```bash
# 1. Measure from the client
curl -s -o /dev/null -w "HTTP %{http_code} total=%{time_total}s\n" \
  "http://localhost:8080/orders/search?email=user42@example.com"
./scripts/load.sh search 40 10
# Latency (s): min=0.313  p50=1.312  p95=1.400  max=1.420

# 2. Which endpoint is slow? (from structured logs)
grep '"slow": true' logs/api/api.log | grep -o '"path": "[^"]*"' | sort | uniq -c

# 3. Which SQL is slow?
docker compose exec mysql tail -n 30 /var/lib/mysql/slow.log
# Query_time: 0.139  Rows_sent: 11  Rows_examined: 500023   <-- 11 rows needed, 500k read

# 4. Why is it slow?
docker compose exec mysql mysql -uroot -prootpass shopdb -e "
EXPLAIN SELECT o.id FROM orders o JOIN products p ON p.id=o.product_id
WHERE o.customer_email='user42@example.com' ORDER BY o.created_at DESC LIMIT 50\G"
# type: ALL   key: NULL   rows: 496808   Extra: Using where; Using filesort

docker compose exec mysql mysql -uroot -prootpass shopdb -e "SHOW INDEX FROM orders;"
# only PRIMARY and idx_orders_product -> idx_orders_customer_created is gone
```

## 6. Root cause (5 Whys)
1. Why slow? → Query read 500k rows to return 11.
2. Why? → No index on `customer_email`; optimizer chose a full table scan + filesort.
3. Why no index? → A migration dropped `idx_orders_customer_created`.
4. Why wasn't it caught? → Migration was not reviewed against query patterns; no performance test with production-sized data.

**Root cause:** A schema migration removed the index that the search query depended on, causing full table scans.

## 7. Resolution
```sql
CREATE INDEX idx_orders_customer_created ON orders (customer_email, created_at);
-- EXPLAIN now: type: ref, key: idx_orders_customer_created, rows: 11
```
Composite index chosen on purpose: it serves both the `WHERE customer_email = ?` filter and the `ORDER BY created_at DESC` (no filesort).

## 8. Preventive actions
| # | Action | Type | Status |
|---|---|---|---|
| 1 | Migration review checklist: any `DROP INDEX` requires EXPLAIN of affected queries | Prevent | Open |
| 2 | Run EXPLAIN checks for critical queries in CI against a seeded DB | Prevent | Open |
| 3 | Alert on p95 latency > 200 ms per endpoint for 5 min | Detect | Open |
| 4 | Ship MySQL slow query log to the log platform; alert on new slow fingerprints | Detect | Open |
| 5 | Keep a load test (`load.sh`) in the release checklist | Detect | Open |

## 9. Lessons learned
- Slow ≠ down: no errors, so error-rate alerts would never fire. Latency must be monitored separately.
- `Rows_examined` vs `Rows_sent` in the slow log is the fastest indicator of a missing index.
