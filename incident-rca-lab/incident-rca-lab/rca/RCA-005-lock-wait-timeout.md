# RCA-005: Orders for product 1 fail after 15 s – blocked by an open transaction

| Field | Value |
|---|---|
| Incident ID | INC-005 |
| Severity | SEV2 (one product could not be ordered) |
| Status | Resolved |
| Duration | ~10 min |
| Services | mysql, order-api |

## 1. Summary
A manual SQL session ran `UPDATE products ... WHERE id = 1` inside a transaction and never committed. The order API locks the product row (`SELECT ... FOR UPDATE`) before decrementing stock, so every order for product 1 waited **15 s** (`innodb_lock_wait_timeout`) and then failed with **MySQL 1205 "Lock wait timeout exceeded" → HTTP 500**. Killing the blocking session restored service instantly.

## 2. Customer impact
- `POST /orders` with `product_id = 1`: 100% failure after a 15 s hang.
- Orders for other products: unaffected (InnoDB row-level lock, not table lock).
- Each hanging request held a gunicorn worker for 15 s → reduced capacity for everyone.

## 3. Timeline
| Time | Event |
|---|---|
| 11:20 | Manual session opens a transaction on product 1 (`./scripts/chaos.sh inject 5`) |
| 11:21 | Postman "Create order product 1" hangs, then 500 after 15.0 s |
| 11:22 | `api.log`: `mysql_errno: 1205`, `duration_ms: 15007` |
| 11:23 | Order for product 2 succeeds in 10 ms → isolated to one row |
| 11:24 | `sys.innodb_lock_waits` → blocking_pid 101 running `DO SLEEP` in an open trx |
| 11:26 | `KILL 101` (`./scripts/chaos.sh fix 5`) |
| 11:26 | Order for product 1 → 201 in 10 ms. Resolved |

## 4. Detection
Postman latency + status test failed. Logs show `mysql_errno: 1205` and very long `duration_ms`.

## 5. Diagnosis
```bash
# Symptom
curl -s -w "\nHTTP %{http_code} in %{time_total}s\n" -X POST http://localhost:8080/orders \
  -H 'Content-Type: application/json' -d '{"customer_email":"a@b.com","product_id":1,"quantity":1}'
# {"error":"database_error","mysql_errno":1205,...}   HTTP 500 in 15.0s

grep '"mysql_errno": 1205' logs/api/api.log

# Who is blocking whom? (run while a request is hanging)
docker compose exec mysql mysql -uroot -prootpass -e "
SELECT waiting_pid, waiting_query, blocking_pid, blocking_query, wait_age,
       sql_kill_blocking_connection FROM sys.innodb_lock_waits\G"
# blocking_pid: 101  blocking_query: DO SLEEP(...)  sql_kill_blocking_connection: KILL 101

# Long-running open transactions (works even when nobody is waiting)
docker compose exec mysql mysql -uroot -prootpass -e "
SELECT trx_mysql_thread_id, trx_state, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s, trx_rows_locked
FROM information_schema.innodb_trx ORDER BY trx_started;"

docker compose exec mysql mysql -uroot -prootpass -e "SHOW FULL PROCESSLIST;"
```

## 6. Root cause (5 Whys)
1. Why 500? → MySQL 1205 lock wait timeout on `SELECT ... FOR UPDATE` for product 1.
2. Why waiting? → Another session held an exclusive lock on that row.
3. Why held so long? → A manual transaction was opened and left uncommitted.
4. Why possible? → Humans have write access to production DB without session timeouts or review.

**Root cause:** A long-running uncommitted manual transaction held a row lock needed by the order flow.

## 7. Resolution
`KILL 101;` – the blocking transaction was rolled back, lock released, waiting requests proceeded.

## 8. Preventive actions
| # | Action | Type | Status |
|---|---|---|---|
| 1 | No manual writes on prod; changes via reviewed scripts that commit immediately | Prevent | Open |
| 2 | Set `wait_timeout` / `idle_in_transaction` style limits for human DB users | Prevent | Open |
| 3 | Alert on any transaction open > 60 s (`information_schema.innodb_trx`) | Detect | Open |
| 4 | Lower `innodb_lock_wait_timeout` for the app user (e.g. 5 s) to fail fast and free workers | Mitigate | Open |
| 5 | Return HTTP 503 + `Retry-After` for errno 1205 instead of a generic 500 | Mitigate | Open |

## 9. Lessons learned
- Not every DB error means "database is down": the DB was healthy, one row was locked.
- `sys.innodb_lock_waits` gives the exact `KILL` statement – fastest path to mitigation.
