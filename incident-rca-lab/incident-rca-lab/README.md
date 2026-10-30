# Production Incident Troubleshooting & RCA Lab

A hands-on lab that runs a REST API and a MySQL database locally, **injects five realistic production failures**, and documents how each was **detected, diagnosed, fixed and prevented** with full Root Cause Analysis reports.

**Skills demonstrated:** Linux · SQL (MySQL 8) · REST APIs · Postman · Structured logging · Docker Compose · Incident management & RCA

---

## Architecture

```
  Postman / curl / load.sh
            │  HTTP :8080
            ▼
 ┌────────────────────────────┐        ┌──────────────────────────────┐
 │ rca-api  (Docker)          │  SQL   │ rca-mysql  (Docker)          │
 │ gunicorn master            │ ─────► │ MySQL 8.0                    │
 │  ├─ worker 1  (Flask app)  │ :3306  │ shopdb: products, orders     │
 │  └─ worker 2  (Flask app)  │        │ 500,000 seeded orders        │
 │ mem_limit 256 MB           │        │ slow query log (>100 ms)     │
 │ JSON logs → logs/api/      │        │ innodb_lock_wait_timeout=15s │
 └────────────────────────────┘        └──────────────────────────────┘
```

## Quick start

```bash
docker compose up -d --build        # wait ~1 min for MySQL to seed data
curl http://localhost:8080/health   # {"db":"up","status":"ok","version":"1.0.0"}
```
Full step-by-step walkthrough: **[GUIDE.md](GUIDE.md)**

## API endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Liveness + DB connectivity |
| GET | `/products` | List products |
| GET | `/products/{id}` | One product (404 if missing) |
| POST | `/orders` | Create order (row lock on product, decrements stock) |
| GET | `/orders/search?email=` | Last 50 orders for a customer |
| GET | `/orders/export` | Export orders (unbounded in v1.0.0, paginated in v1.0.1) |

Every response carries `X-Request-ID` and `X-Response-Time-ms`; every log line is JSON containing the same `request_id`.

## Incidents

| # | Incident | Symptom | Root cause | Fix | Evidence |
|---|---|---|---|---|---|
| 1 | HTTP 500 after release | `POST /orders` 100% 500, `/health` still OK | `KeyError: 'unit_price'` in v1.1.0 | Rollback to v1.0.0 | [RCA-001](rca/RCA-001-http500-bad-release.md) |
| 2 | Database down | All endpoints 503, MySQL errno 2003 | MySQL container stopped, no restart policy | Start DB, add `restart: unless-stopped` | [RCA-002](rca/RCA-002-database-down.md) |
| 3 | Slow query | Search p50 54 ms → **1.3 s** | Migration dropped index → full scan of 500k rows | Recreate composite index | [RCA-003](rca/RCA-003-slow-query-missing-index.md) |
| 4 | Process failure (OOM) | `curl: (52) Empty reply`, no app log | Unbounded export ≈ 680 MB > 256 MB limit → worker SIGKILL | Keyset pagination (v1.0.1) | [RCA-004](rca/RCA-004-worker-oom-killed.md) |
| 5 | Lock wait timeout | Orders for product 1 hang 15 s → 500 (errno 1205) | Uncommitted manual transaction holding a row lock | `KILL` blocking session | [RCA-005](rca/RCA-005-lock-wait-timeout.md) |

Reproduce any of them:
```bash
./scripts/chaos.sh list
./scripts/chaos.sh inject 3
./scripts/diagnose.sh case3     # snapshot → evidence/
./scripts/chaos.sh fix 3
```

## Troubleshooting method used for every incident

1. **Detect** – Postman test suite / curl / log WARNING-ERROR lines
2. **Triage** – `docker compose ps`, `/health`, error rate in logs, scope (one endpoint? one product? everything?)
3. **Diagnose** – trace request ID in logs → process & container state → database (processlist, EXPLAIN, slow log, lock views)
4. **Mitigate** – fastest safe action to stop impact (rollback, restart, kill session)
5. **Fix & verify** – permanent fix, Postman baseline green, latency back to baseline
6. **RCA** – timeline, impact, 5 Whys, preventive actions (prevent / detect / mitigate)

## Repository contents (interview evidence)

| Evidence | Location |
|---|---|
| Postman collection + environment | [`postman/`](postman/) |
| Diagnostic commands (Linux, Docker, logs, SQL) | [`docs/diagnostic-commands.md`](docs/diagnostic-commands.md), [`scripts/diagnose.sh`](scripts/diagnose.sh) |
| Sample logs for each incident | [`sample-logs/`](sample-logs/) |
| RCA reports + template | [`rca/`](rca/) |
| Diagnostic snapshots | [`evidence/`](evidence/) |
| Failure injection / load scripts | [`scripts/`](scripts/) |

## Tech stack
Python 3.12 · Flask 3 · gunicorn · PyMySQL · MySQL 8.0 · Docker Compose · Bash · Postman
