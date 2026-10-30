# Diagnostic Commands Cheat Sheet

Run all commands from the project root in the VS Code terminal.

## 1. First 60 seconds (triage)
```bash
docker compose ps -a                                   # what is running / exited?
curl -s -w "\nHTTP %{http_code} in %{time_total}s\n" http://localhost:8080/health
./scripts/diagnose.sh triage                           # full snapshot -> evidence/
```

## 2. HTTP / REST (curl)
```bash
curl -i http://localhost:8080/products/1                       # -i shows status + headers
curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" URL    # status + latency only
curl -v http://localhost:8080/health                           # full connection debug
curl -X POST http://localhost:8080/orders -H 'Content-Type: application/json' \
     -d '{"customer_email":"user42@example.com","product_id":2,"quantity":1}'
curl -H 'X-Request-ID: my-trace-001' http://localhost:8080/products   # set your own trace id
```
| curl result | Meaning |
|---|---|
| `HTTP 500` | App caught an exception → read app logs |
| `HTTP 503` | Dependency (DB) unavailable |
| `(7) Failed to connect` | Nothing listening → container/process down |
| `(52) Empty reply from server` | Process died mid-request (OOM / SIGKILL) |
| `(28) Operation timed out` | Hang → locks, slow query, deadlock |

## 3. Logs (Linux text tools)
```bash
tail -f logs/api/api.log                                        # live
grep '"level": "ERROR"' logs/api/api.log | tail -20             # recent errors
grep <request_id> logs/api/api.log                              # trace ONE request
grep -c '"status": 500' logs/api/api.log                        # count 500s
grep -o '"status": [0-9]*' logs/api/api.log | sort | uniq -c    # status code histogram
grep '"slow": true' logs/api/api.log | grep -o '"path": "[^"]*"' | sort | uniq -c
grep -o '"error_type": "[^"]*"' logs/api/api.log | sort | uniq -c | sort -rn
grep '"ts": "2026-10-30T10:0' logs/api/api.log                  # time window
# pretty-print with Python (no jq needed)
tail -1 logs/api/api.log | python3 -m json.tool
docker compose logs --tail 50 api              # gunicorn master: worker crashes, boots
docker compose logs --since 10m mysql          # MySQL server log
```

## 4. Containers & processes (Linux)
```bash
docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}' rca-api
docker stats --no-stream                       # CPU / memory vs limit
docker compose exec api ps -eo pid,ppid,rss,etime,cmd    # master + workers, memory, uptime
docker compose exec api top -b -n 1 | head -15
docker compose exec api sh                     # shell inside the container
docker compose exec api curl -s localhost:5000/health    # test from INSIDE the container
docker compose exec api getent hosts mysql     # DNS resolution of the DB host
```
Exit codes: `0` clean stop · `1` app error · `137` SIGKILL (OOM or kill -9) · `143` SIGTERM.

## 5. MySQL
```bash
docker compose exec mysql mysql -uroot -prootpass shopdb     # interactive SQL shell
```
```sql
SHOW FULL PROCESSLIST;                                   -- who is connected, what is running
SELECT * FROM information_schema.innodb_trx\G            -- open transactions
SELECT * FROM sys.innodb_lock_waits\G                    -- who blocks whom (+ KILL statement)
KILL <id>;                                               -- kill a session
EXPLAIN SELECT ... ;                                     -- type ALL + key NULL = full scan
SHOW INDEX FROM orders;
SHOW GLOBAL STATUS LIKE 'Threads_connected';
SHOW GLOBAL STATUS LIKE 'Slow_queries';
SHOW VARIABLES LIKE 'innodb_lock_wait_timeout';
SELECT digest_text, count_star, ROUND(avg_timer_wait/1e9,1) AS avg_ms, sum_rows_examined
  FROM performance_schema.events_statements_summary_by_digest
  ORDER BY avg_timer_wait DESC LIMIT 5;                  -- top slowest query patterns
```
```bash
docker compose exec mysql tail -n 40 /var/lib/mysql/slow.log    # slow query log
```

## 6. Load
```bash
./scripts/load.sh search 40 10      # 40 requests, 10 parallel
./scripts/load.sh orders 20 5
```
