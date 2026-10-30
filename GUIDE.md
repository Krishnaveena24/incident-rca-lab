# 3-Hour Step-by-Step Guide (VS Code)

Follow this top to bottom. Every command is run in the **VS Code terminal** from the project root.
Times are targets — if you finish a step early, move on.

| Phase | Time | What you do |
|---|---|---|
| 0 | 0:00 – 0:20 | Install tools, open project in VS Code |
| 1 | 0:20 – 0:40 | Start API + MySQL with Docker Compose, read the code |
| 2 | 0:40 – 0:55 | Baseline: curl, Postman, logs, SQL |
| 3 | 0:55 – 2:10 | 5 incidents × 15 min: inject → observe → diagnose → fix → verify → save evidence |
| 4 | 2:10 – 2:40 | Personalise the 5 RCA reports with your own timestamps and outputs |
| 5 | 2:40 – 3:00 | Apply a preventive action, finish README, push to GitHub, interview prep |

---

## PHASE 0 — Setup (0:00 – 0:20)

### Step 0.1 Install (skip what you already have)
1. **Docker Desktop** – https://www.docker.com/products/docker-desktop
   - Windows: during install keep **"Use WSL 2"** ticked. Restart if asked.
   - Start Docker Desktop and wait until it says **"Engine running"**.
2. **VS Code** – you have it.
3. **Postman** desktop app (or the Postman extension inside VS Code).
4. **Git** – https://git-scm.com (Windows: this also installs **Git Bash**, which you need).

### Step 0.2 Verify in a terminal
```bash
docker --version          # Docker version 2x.x
docker compose version    # Docker Compose version v2.x
git --version
```

### Step 0.3 Open the project in VS Code
1. Unzip `incident-rca-lab.zip` somewhere simple, e.g. `C:\labs\incident-rca-lab` or `~/labs/incident-rca-lab`.
2. VS Code → **File → Open Folder…** → select `incident-rca-lab`.
3. Bottom-right popup "Install recommended extensions?" → **Install** (Docker, Python, Postman, Markdown, MySQL client).
4. Open terminal: **View → Terminal** (or ``Ctrl+` ``).

### Step 0.4 Windows only: use Bash, not PowerShell
In the terminal panel click the **˅** next to **+** → **Git Bash** (or **Ubuntu (WSL)**).
To make it the default: `Ctrl+Shift+P` → **Terminal: Select Default Profile** → **Git Bash**.

> All scripts are Bash. In Git Bash, for interactive MySQL shells prefix with `winpty`:
> `winpty docker compose exec mysql mysql -uroot -prootpass shopdb`

### Step 0.5 Make scripts executable (Mac/Linux/WSL)
```bash
chmod +x scripts/*.sh
```

### Step 0.6 Arrange VS Code for incident work
Click the **split terminal** icon twice so you have 3 terminals side by side:

| Terminal | Purpose |
|---|---|
| T1 | Commands (inject, curl, diagnose) |
| T2 | Live logs: `tail -f logs/api/api.log` (after Phase 1) |
| T3 | `docker stats` or MySQL shell |

---

## PHASE 1 — Build & run the stack (0:20 – 0:40)

### Step 1.1 Understand the project (5 min — open each file in VS Code)
```
incident-rca-lab/
├── docker-compose.yml   ← 2 services: mysql (8.0) + api (Flask/gunicorn). Read the comments.
├── api/
│   ├── app.py           ← REST API + JSON logging + error handlers. Read endpoints at the bottom.
│   ├── Dockerfile
│   └── requirements.txt
├── db/init.sql          ← schema + 500,000 seed orders (runs once on first start)
├── scripts/
│   ├── chaos.sh         ← inject / fix the 5 incidents
│   ├── diagnose.sh      ← one-shot diagnostic snapshot → evidence/
│   └── load.sh          ← concurrent traffic + latency percentiles
├── postman/             ← import into Postman
├── rca/                 ← RCA template + 5 reports
├── docs/diagnostic-commands.md ← cheat sheet (keep it open!)
├── sample-logs/         ← what each incident looks like in real logs
├── evidence/            ← your diagnostic snapshots go here
└── logs/api/api.log     ← appears after start (mounted from the container)
```
Key things to notice in `app.py`:
- Every request gets an `X-Request-ID` (returned in the response header **and** logged).
- Every log line is JSON with `level, version, status, duration_ms, slow, request_id`.
- `SLOW_REQUEST_MS=200` → requests slower than 200 ms are logged as `WARNING` with `"slow": true`.

### Step 1.2 Start everything
```bash
docker compose up -d --build
```
First run downloads images (~2–5 min). Then watch MySQL seed the data:
```bash
docker compose logs -f mysql
```
Wait until you see `ready for connections` **after** the init script lines (about 30–60 s), then `Ctrl+C`.
```bash
docker compose ps
```
Expected: `rca-mysql` → **healthy**, `rca-api` → **Up**.

> Tip: `Ctrl+Shift+P` → **Tasks: Run Task** → **Lab: Start** does the same thing. All lab commands exist as tasks.

### Step 1.3 Smoke test
```bash
curl -s http://localhost:8080/health
# {"db":"up","status":"ok","version":"1.0.0"}
```
In **T2** start the live log:
```bash
tail -f logs/api/api.log
```
Leave it running for the rest of the lab.

**Troubleshooting**
| Problem | Fix |
|---|---|
| `port is already allocated` 8080 or 3307 | Change the left side in `docker-compose.yml`, e.g. `"8081:5000"`, and use that port |
| API `Up` but curl fails | `docker compose logs api` — usually MySQL still initialising; wait 30 s |
| `permission denied: ./scripts/...` | `chmod +x scripts/*.sh` or run `bash scripts/chaos.sh ...` |
| `$'\r': command not found` | File has Windows line endings: in VS Code bottom bar click **CRLF → LF**, save |

---

## PHASE 2 — Baseline (0:40 – 0:55)

You must know what "healthy" looks like before you break anything.

### Step 2.1 curl (REST basics)
```bash
curl -i http://localhost:8080/products/1                      # note X-Request-ID, X-Response-Time-ms
curl -s http://localhost:8080/products
curl -i -X POST http://localhost:8080/orders -H 'Content-Type: application/json' \
  -d '{"customer_email":"user42@example.com","product_id":2,"quantity":1}'          # 201
curl -i -X POST http://localhost:8080/orders -H 'Content-Type: application/json' -d '{"product_id":1}'   # 400
curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" \
  "http://localhost:8080/orders/search?email=user42@example.com"                     # ~10 ms
```
Watch each request appear in T2.

### Step 2.2 Postman
1. Postman → **Import** → select both files in `postman/`.
2. Top-right environment dropdown → **RCA Lab - Local**.
3. Right-click folder **0 - Baseline** → **Run folder** → **Run**. All tests should be **green**.
4. Open **Console** (bottom-left) → every request prints its `request_id` — this is how you will jump from Postman to logs.

### Step 2.3 Baseline latency + SQL
```bash
./scripts/load.sh search 40 10          # write down p50 and max
docker compose exec mysql mysql -uroot -prootpass shopdb -e "SELECT COUNT(*) FROM orders; SHOW INDEX FROM orders;"
./scripts/diagnose.sh baseline          # creates evidence/diag-baseline-*.txt
```
Open the evidence file in VS Code and skim the 12 sections. This is your "normal" picture.

---

## PHASE 3 — The 5 incidents (0:55 – 2:10, ~15 min each)

**Same drill every time** (this is what interviewers want to hear):

1. **Inject** the failure
2. **Observe** symptoms like a user (curl / Postman) — write down the time
3. **Diagnose**: logs → processes → database → find the root cause
4. **Fix** (mitigate first, then the real fix)
5. **Verify** (Postman Baseline green again)
6. **Save evidence** (`diagnose.sh` + screenshot + notes in the RCA)

> Before each case, **do not look at the RCA file** for it. Try to find the cause yourself using `docs/diagnostic-commands.md`. Then compare.

---

### Case 1 — HTTP 500 after a bad release (0:55 – 1:10)

**Inject**
```bash
./scripts/chaos.sh inject 1
```
**Observe**
```bash
curl -i -X POST http://localhost:8080/orders -H 'Content-Type: application/json' \
  -d '{"customer_email":"user42@example.com","product_id":2,"quantity":1}'
curl -s http://localhost:8080/health
```
Question to ask yourself: *why is health "ok" while orders fail?*

**Diagnose**
```bash
# copy the request_id from the 500 response, then:
grep <request_id> logs/api/api.log
grep '"level": "ERROR"' logs/api/api.log | tail -3 | python3 -m json.tool   # read "traceback"
grep '"status": 500' logs/api/api.log | grep -o '"version": "[^"]*"' | sort | uniq -c
```
In VS Code: `Ctrl+P` → `app.py` → `Ctrl+G` → go to the line number from the traceback.
Verify nothing was written:
```bash
docker compose exec mysql mysql -uroot -prootpass shopdb -e "SELECT id, stock FROM products WHERE id=2;"
```
**Fix** (rollback) and **verify**
```bash
./scripts/chaos.sh fix 1
```
Postman → run **0 - Baseline** → all green.

**Evidence**
```bash
./scripts/diagnose.sh case1
```
Screenshot: Postman failed test + the log line with `KeyError`.

---

### Case 2 — Database down (1:10 – 1:25)

**Inject**
```bash
./scripts/chaos.sh inject 2
```
**Observe**
```bash
curl -s -w "\nHTTP %{http_code}\n" http://localhost:8080/health
curl -s -w "\nHTTP %{http_code}\n" http://localhost:8080/products
```
**Diagnose**
```bash
docker compose ps -a
docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' rca-mysql
docker compose logs --tail 20 mysql
grep '"mysql_errno": 2003' logs/api/api.log | tail -2
docker compose exec api getent hosts mysql || echo "DNS: mysql not resolvable"
./scripts/diagnose.sh case2
```
Notice: the API itself is **alive** and answers in milliseconds with a clean 503 — it fails fast because of `connect_timeout=3`.

**Fix** and **verify**
```bash
./scripts/chaos.sh fix 2
curl -s http://localhost:8080/health      # back to ok, API was never restarted
```

---

### Case 3 — Slow query / missing index (1:25 – 1:40)

**Inject**
```bash
./scripts/chaos.sh inject 3
```
**Observe**
```bash
curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" "http://localhost:8080/orders/search?email=user42@example.com"
./scripts/load.sh search 40 10         # compare with your baseline p50
```
Postman: run **Case 3** request with Runner, 30 iterations → latency test fails.

**Diagnose**
```bash
grep '"slow": true' logs/api/api.log | grep -o '"path": "[^"]*"' | sort | uniq -c
docker compose exec mysql tail -n 30 /var/lib/mysql/slow.log         # look at Rows_examined vs Rows_sent
```
Open the MySQL shell in **T3** (`winpty` prefix on Git Bash):
```bash
docker compose exec mysql mysql -uroot -prootpass shopdb
```
```sql
EXPLAIN SELECT o.id FROM orders o JOIN products p ON p.id = o.product_id
WHERE o.customer_email = 'user42@example.com' ORDER BY o.created_at DESC LIMIT 50\G
SHOW INDEX FROM orders;
```
`type: ALL`, `key: NULL`, `rows: ~500000` = full table scan.

**Fix** and **verify**
```bash
./scripts/chaos.sh fix 3
./scripts/load.sh search 40 10         # back to baseline
```
Re-run the EXPLAIN → `type: ref`, `key: idx_orders_customer_created`. Save both EXPLAIN outputs in your RCA.

---

### Case 4 — Process failure: worker OOM-killed (1:40 – 1:55)

**Prepare**: in **T3** run `docker stats rca-api` and watch MEM USAGE / LIMIT (256 MiB).

**Inject**
```bash
./scripts/chaos.sh inject 4
```
**Observe**: `curl: (52) Empty reply from server` (or "socket hang up" in Postman). No HTTP status at all.

**Diagnose**
```bash
tail -5 logs/api/api.log                       # nothing about this request! why?
docker compose logs --tail 20 api | grep -i -E "SIGKILL|memory|Booting"
docker compose exec api ps -eo pid,ppid,rss,etime,cmd   # one worker has a very short uptime (etime)
docker inspect -f 'oom={{.State.OOMKilled}} restarts={{.RestartCount}}' rca-api
./scripts/diagnose.sh case4
```
Key insight: SIGKILL cannot be caught, so the **app** logs nothing — the **process manager** (gunicorn master) logs the kill and starts a new worker. Then look at `export_orders()` in `app.py`: `fetchall()` with no `LIMIT`.

**Fix** (deploy v1.0.1 with pagination) and **verify**
```bash
./scripts/chaos.sh fix 4
curl -s "http://localhost:8080/orders/export?limit=2&after_id=0"
```
Postman: **Case 4 → Export paginated** then **Export next page**. Memory in `docker stats` stays flat.

---

### Case 5 — Lock wait timeout (1:55 – 2:10)

**Inject**
```bash
./scripts/chaos.sh inject 5
```
**Observe** (takes 15 s)
```bash
curl -s -w "\nHTTP %{http_code} in %{time_total}s\n" -X POST http://localhost:8080/orders \
  -H 'Content-Type: application/json' -d '{"customer_email":"a@b.com","product_id":1,"quantity":1}'
```
In Postman run **Case 5** folder: product 1 fails after 15 s, product 2 succeeds instantly. *What does that tell you?*

**Diagnose** — start a product-1 order in T1 and, **while it hangs**, run in T3:
```sql
SELECT waiting_pid, waiting_query, blocking_pid, blocking_query, wait_age,
       sql_kill_blocking_connection FROM sys.innodb_lock_waits\G
SELECT trx_mysql_thread_id, trx_state, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s FROM information_schema.innodb_trx;
SHOW FULL PROCESSLIST;
```
```bash
grep '"mysql_errno": 1205' logs/api/api.log | tail -1
./scripts/diagnose.sh case5
```
**Fix**: kill the blocker yourself in SQL (`KILL <blocking_pid>;`) — or `./scripts/chaos.sh fix 5`.
**Verify**: product 1 order → 201 in milliseconds.

---

## PHASE 4 — Write the RCAs (2:10 – 2:40)

The 5 reports in `rca/` are filled in with results from a real test run. Make them **yours**:
1. Open `rca/RCA-001-...md` and `Ctrl+K V` (Markdown preview side by side).
2. Replace **timeline times** with your own (take them from `"ts"` in `api.log` or from your `evidence/` files).
3. Replace request IDs, PIDs, latency numbers and outputs with what **you** saw.
4. Add 1–2 screenshots: save PNGs in `docs/screenshots/` and link them: `![Postman](../docs/screenshots/case1-postman.png)`.
5. Copy 3–5 key log lines from your `logs/api/api.log` into `sample-logs/` (replace the samples).
6. Repeat for all 5 (≈6 min each). Keep the **5 Whys** and **Preventive actions** sections — interviewers ask about them.

---

## PHASE 5 — Prevent, publish, prepare (2:40 – 3:00)

### Step 5.1 Apply one preventive action for real (5 min)
In `docker-compose.yml`, under `api:` **and** under `mysql:`, add / uncomment:
```yaml
    restart: unless-stopped
```
Also make the Case 4 fix permanent (otherwise the next `docker compose up` brings back v1.0.0). In the same file change:
```yaml
      APP_VERSION: ${APP_VERSION:-1.0.1}
      EXPORT_PAGINATION: ${EXPORT_PAGINATION:-true}
```
```bash
docker compose up -d
docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' rca-api rca-mysql   # unless-stopped
curl -s http://localhost:8080/health                                        # version 1.0.1
```
Update RCA-002 preventive action #1 to **Done**.

### Step 5.2 Push to GitHub (5 min)
Create an empty repo on GitHub named `incident-rca-lab`, then:
```bash
git init
git add .
git commit -m "Production incident troubleshooting & RCA lab: 5 incidents, RCAs, Postman, diagnostics"
git branch -M main
git remote add origin https://github.com/<your-username>/incident-rca-lab.git
git push -u origin main
```
(VS Code alternative: **Source Control** icon → **Publish to GitHub**.)

### Step 5.3 Shut down (when finished)
```bash
docker compose down        # keeps data
docker compose down -v     # wipes DB; next start re-seeds 500k rows
```

### Step 5.4 Interview prep (10 min) — practise saying these out loud
**60-second pitch:**
> "I built a lab with a Flask REST API and MySQL in Docker Compose, added structured JSON logs with request IDs, and injected five realistic production failures: a bad release causing 500s, a database outage, a slow query from a dropped index, a worker OOM-kill, and a row-lock timeout. For each one I diagnosed with curl/Postman, Linux tools, container logs and SQL — EXPLAIN, slow query log, processlist, InnoDB lock views — fixed it, verified with an automated Postman suite, and wrote an RCA with a timeline, 5 Whys and preventive actions."

**Likely questions and the answer in one line:**
| Question | Your answer |
|---|---|
| How do you start troubleshooting a 500? | Reproduce, get the request ID, grep logs for the stack trace, correlate with recent changes. |
| Health check was green but orders failed — why? | Shallow health check (DB ping only); add deep checks / synthetic transactions and 5xx-rate alerts. |
| 500 vs 503? | 500 = bug in our code; 503 = dependency unavailable, retryable. |
| How do you find a slow query? | Slow query log → Rows_examined vs Rows_sent → EXPLAIN → check indexes. |
| Why did app logs show nothing in the OOM case? | SIGKILL can't be caught; evidence is in the process manager/container logs and memory metrics. Exit code 137. |
| How do you find what's blocking a query? | `sys.innodb_lock_waits` / `information_schema.innodb_trx`, then `KILL` the blocker. |
| Mitigation vs root-cause fix? | Mitigate first (rollback, kill session, restart) to stop impact; then fix the root cause and add prevention. |
| What makes a good RCA? | Blameless, timeline, impact, evidence, 5 Whys, actionable preventive items with owners. |

---

## If you are running out of time
Priority order: Cases **1, 3, 5** (HTTP, SQL, locks) → RCA-001/003/005 → GitHub push. Cases 2 and 4 can be done later.
