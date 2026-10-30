# RCA-002: API returns 503 – MySQL container stopped

| Field | Value |
|---|---|
| Incident ID | INC-002 |
| Severity | SEV1 (all data endpoints down) |
| Status | Resolved |
| Duration | ~6 min |
| Services | mysql, order-api |

## 1. Summary
The MySQL container stopped. Every endpoint that touches the database returned **HTTP 503** with MySQL error **2003 (Connection refused)**. Starting MySQL restored service automatically; the API needed no restart because it opens a new connection per request.

## 2. Customer impact
- `/products`, `/orders`, `/orders/search`, `/health`: 100% HTTP 503.
- API process itself stayed up (it answered quickly with a clean JSON error – no hangs, thanks to `connect_timeout=3`).

## 3. Timeline
| Time | Event |
|---|---|
| 10:20 | MySQL stopped (`./scripts/chaos.sh inject 2`) |
| 10:20 | `/health` → 503 `db: down`, error 2003 |
| 10:21 | `docker compose ps -a` → `rca-mysql` status **Exited** |
| 10:22 | `docker inspect` exit code and `docker compose logs mysql` reviewed: clean shutdown, not a crash |
| 10:24 | MySQL started (`./scripts/chaos.sh fix 2`), healthcheck → healthy |
| 10:25 | `/health` → 200. Postman Baseline passes |

## 4. Detection
`/health` returned 503 immediately – this health check *does* cover DB connectivity. In production this would page via an uptime monitor.

## 5. Diagnosis
```bash
curl -s -w "\nHTTP %{http_code}\n" http://localhost:8080/health
# {"db":"down","error":"(2003, \"Can't connect to MySQL server on 'mysql' ([Errno -2] Name or service not known)\")"...}
# Note: in Docker a STOPPED container is removed from Docker DNS, so you see "Name or service not known".
# A running container with MySQL crashed inside would show "[Errno 111] Connection refused". Both = errno 2003.
# HTTP 503

docker compose ps -a                         # rca-mysql  Exited (0)
docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' rca-mysql
docker compose logs --tail 30 mysql          # "Shutdown complete" = graceful stop, not crash
grep '"mysql_errno": 2003' logs/api/api.log | wc -l     # how many requests failed
# From inside the API container: is the port reachable?
docker compose exec api sh -c 'curl -s -m 2 telnet://mysql:3306 || echo "port 3306 unreachable"'
```

## 6. Root cause (5 Whys)
1. Why 503? → API could not connect to MySQL (errno 2003).
2. Why? → MySQL container was stopped.
3. Why did it stay down? → No restart policy on the container; no alert on container state.
4. Why single point of failure? → One MySQL instance, no replica/failover.

**Root cause:** The database container was stopped and there was no restart policy or automatic failover to recover it.

## 7. Resolution
`docker compose start mysql`, waited for healthcheck = healthy. API recovered without restart.

## 8. Preventive actions
| # | Action | Type | Status |
|---|---|---|---|
| 1 | Add `restart: unless-stopped` to `mysql` and `api` in docker-compose.yml | Mitigate | Done (after lab) |
| 2 | Alert on `/health` 503 for > 1 minute (uptime monitor) | Detect | Open |
| 3 | Production: managed DB with standby replica / automatic failover | Prevent | Open |
| 4 | Retry with backoff for idempotent reads (GET) in the API | Mitigate | Open |
| 5 | Change process: DB maintenance only in a window with a ticket | Prevent | Open |

## 9. Lessons learned
- **Went well:** fail-fast (3 s connect timeout) + clear 503 JSON error with errno; automatic recovery once DB was back.
- **Went badly:** nothing restarted the database automatically.
