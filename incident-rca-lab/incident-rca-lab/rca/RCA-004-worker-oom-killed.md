# RCA-004: API worker OOM-killed by unbounded export endpoint

| Field | Value |
|---|---|
| Incident ID | INC-004 |
| Severity | SEV2 |
| Status | Resolved |
| Duration | ~15 min |
| Services | order-api |

## 1. Summary
A partner called `GET /orders/export`, which loads **all 500,000 orders into memory** in one request. The gunicorn worker grew to ~680 MB, exceeding the container memory limit of **256 MB**, and the kernel OOM killer sent it **SIGKILL**. The client received an empty reply; the gunicorn master restarted the worker. Fixed by deploying v1.0.1, which enforces keyset pagination (max 1,000 rows per page; ~38 MB peak).

## 2. Customer impact
- `/orders/export`: 100% failure (`curl: (52) Empty reply from server`, Postman "socket hang up").
- Other requests on the same worker at the moment of the kill also failed; with 2 workers, capacity was halved while the export was running.
- Repeated calls = repeated crashes (crash loop risk).

## 3. Timeline
| Time | Event |
|---|---|
| 11:00 | Partner job calls `/orders/export` (`./scripts/chaos.sh inject 4`) |
| 11:00 | Client: `Empty reply from server`. No HTTP status, no JSON error |
| 11:02 | `api.log` has **no** error line for the request (process died before logging) |
| 11:03 | `docker compose logs api` → `Worker (pid:N) was sent SIGKILL! Perhaps out of memory?` |
| 11:05 | `docker stats` during a repeat call: MEM USAGE near 256MiB LIMIT |
| 11:08 | Code reviewed: `fetchall()` with no LIMIT. Root cause confirmed |
| 11:12 | v1.0.1 deployed (`./scripts/chaos.sh fix 4`) |
| 11:14 | Paginated export returns 1,000 rows per page, memory stable. Resolved |

## 4. Detection
Only the client noticed. Application logs were silent because the process was killed with SIGKILL (can't be caught). The evidence was in the **process manager logs (gunicorn master)**, not app logs.

## 5. Diagnosis
```bash
curl -sS -o /dev/null -w "HTTP %{http_code}\n" http://localhost:8080/orders/export
# curl: (52) Empty reply from server

# App log: nothing for this request -> the process died mid-request
tail -5 logs/api/api.log

# Process manager log
docker compose logs --tail 20 api | grep -i -E "SIGKILL|out of memory|Booting worker"
# [ERROR] Worker (pid:1604) was sent SIGKILL! Perhaps out of memory?
# [INFO]  Booting worker with pid: 1615

# Watch memory while reproducing (2nd terminal)
docker stats rca-api
# MEM USAGE / LIMIT  ~250MiB / 256MiB

# Processes inside the container: new worker PID / short uptime proves restart
docker compose exec api ps -eo pid,ppid,rss,etime,cmd

# Container itself was NOT killed (only the worker), so this stays false:
docker inspect -f 'oom={{.State.OOMKilled}} restarts={{.RestartCount}}' rca-api
```

## 6. Root cause (5 Whys)
1. Why empty reply? → The worker process was SIGKILLed mid-request.
2. Why? → Kernel OOM killer: container memory exceeded 256 MB.
3. Why so much memory? → Endpoint did `SELECT ... FROM orders` with no LIMIT and `fetchall()` → 500k Python dicts + an 80 MB JSON body.
4. Why was it written that way? → Built when the table was small; no limit on result size; not tested with production volume.

**Root cause:** Unbounded query result loaded fully into memory, exceeding the container memory limit.

## 7. Resolution
Deployed v1.0.1 (`EXPORT_PAGINATION=true`): keyset pagination
`WHERE id > :after_id ORDER BY id LIMIT :limit` (limit capped at 1,000), response includes `next_after_id`.

## 8. Preventive actions
| # | Action | Type | Status |
|---|---|---|---|
| 1 | Every list/export endpoint must be paginated with a hard max page size | Prevent | Done (v1.0.1) |
| 2 | Alert on container memory > 80% of limit | Detect | Open |
| 3 | Alert on gunicorn "was sent SIGKILL" / worker restarts in logs | Detect | Open |
| 4 | Large exports via async job → file in object storage, not an HTTP response | Prevent | Open |
| 5 | Rate limit the export endpoint per client | Mitigate | Open |

## 9. Lessons learned
- SIGKILL leaves **no application log**; always check the supervisor/container logs and `docker stats`.
- The gunicorn master saved us from a full outage by respawning the worker – process supervision matters.
