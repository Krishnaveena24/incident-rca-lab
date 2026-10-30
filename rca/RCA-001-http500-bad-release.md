# RCA-001: Order creation returns HTTP 500 after release v1.1.0

| Field | Value |
|---|---|
| Incident ID | INC-001 |
| Severity | SEV1 (checkout fully broken) |
| Status | Resolved |
| Duration | ~10 min (replace with your own timestamps) |
| Services | order-api |

## 1. Summary
After deploying order-api **v1.1.0**, 100% of `POST /orders` requests returned HTTP 500. The application raised `KeyError: 'unit_price'` while calculating the order total. Rolling back to v1.0.0 restored service. No partial data was written because the transaction was never committed.

## 2. Customer impact
- `POST /orders`: 100% failure (HTTP 500) for the whole incident window.
- `GET /products`, `GET /orders/search`, `GET /health`: unaffected.
- No orders were lost or double-charged; stock was not decremented (verified with SQL).

## 3. Timeline
| Time | Event |
|---|---|
| 10:00 | v1.1.0 deployed (`./scripts/chaos.sh inject 1`) |
| 10:01 | Postman "Create order" test fails: `Status is 201` → got 500 |
| 10:02 | `/health` checked: returns 200 `status: ok`, `version: 1.1.0` |
| 10:03 | request_id from the 500 response grepped in `api.log` → `KeyError: 'unit_price'` |
| 10:05 | Correlated with the deployment: only version 1.1.0 errors. Decision: roll back |
| 10:06 | Rolled back to v1.0.0 (`./scripts/chaos.sh fix 1`) |
| 10:07 | Postman Baseline folder: all tests pass. Incident resolved |

## 4. Detection
Detected by the Postman smoke test, **not** by the health check. `/health` only runs `SELECT 1`, so it stayed green while checkout was broken.

## 5. Diagnosis
```bash
# 1. Reproduce and capture the request id
curl -i -X POST http://localhost:8080/orders -H 'Content-Type: application/json' \
  -d '{"customer_email":"user42@example.com","product_id":2,"quantity":1}'
# HTTP/1.1 500 INTERNAL SERVER ERROR
# X-Request-ID: c14f86a38822
# {"error":"internal_server_error","request_id":"c14f86a38822"}

# 2. Trace that exact request in the logs
grep c14f86a38822 logs/api/api.log
# "msg": "unhandled exception", "error_type": "KeyError", "error": "'unit_price'", "version": "1.1.0"
# File "/app/app.py", line 197, in create_order
#     total = product["unit_price"] * qty

# 3. Error rate by version (was it the release?)
grep '"status": 500' logs/api/api.log | grep -o '"version": "[^"]*"' | sort | uniq -c
#   3 "version": "1.1.0"

# 4. Confirm no partial writes
docker compose exec mysql mysql -uroot -prootpass shopdb -e "SELECT id, stock FROM products WHERE id=2;"
```

## 6. Root cause (5 Whys)
1. Why did orders fail? → `create_order` raised `KeyError: 'unit_price'`.
2. Why? → v1.1.0 reads `product["unit_price"]`, but the SQL query returns the column `price`.
3. Why was it shipped? → The "pricing refactor" renamed the field in code but not in the query/schema.
4. Why wasn't it caught? → No automated test calls `POST /orders` before deploy.
5. Why wasn't it noticed by monitoring? → Health check is shallow (DB ping only) and there is no 5xx alert.

**Root cause:** A code change referenced a non-existent column key, and the release pipeline had no API test covering order creation.

## 7. Resolution
- **Mitigation:** rollback to v1.0.0 → `BUG_MODE=false APP_VERSION=1.0.0 docker compose up -d --no-deps api`
- **Permanent fix:** use `product["price"]` (or alias the column `price AS unit_price` in SQL) + add a test.

## 8. Preventive actions
| # | Action | Type | Status |
|---|---|---|---|
| 1 | Run the Postman collection with Newman in CI; block the release if any test fails | Prevent | Open |
| 2 | Add unit test for `create_order` total calculation | Prevent | Open |
| 3 | Alert when 5xx rate > 2% over 5 minutes (log-based) | Detect | Open |
| 4 | Add a deep health check / synthetic order probe in staging | Detect | Open |
| 5 | Canary deployment: release to 10% first, auto-rollback on errors | Mitigate | Open |
| 6 | Log `version` on every line (already done) to correlate errors with releases | Detect | Done |

## 9. Lessons learned
- **Went well:** request_id in response + JSON logs led straight to the line of code in ~2 minutes; rollback was one command.
- **Went badly:** health check said "ok" during a full checkout outage.
- **Lucky:** the exception happened before any DB write, so no data cleanup was needed.
