#!/usr/bin/env bash
# =====================================================================
# diagnose.sh - one-shot incident snapshot (your "first 5 minutes")
# Saves everything to evidence/diag-<timestamp>.txt
# Usage: ./scripts/diagnose.sh [label]      e.g. ./scripts/diagnose.sh case1
# =====================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1   # stops Git Bash on Windows from mangling /var/... paths
cd "$(dirname "$0")/.."
LABEL="${1:-snapshot}"
mkdir -p evidence
OUT="evidence/diag-${LABEL}-$(date +%Y%m%d-%H%M%S).txt"
SQL="docker compose exec -T mysql mysql -uroot -prootpass shopdb"

section() { echo; echo "################ $* ################"; }

{
  section "TIME"; date
  section "1. CONTAINERS (docker compose ps -a)"; docker compose ps -a
  section "2. EXIT CODE / OOM / RESTARTS (api)"
  docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}} oomkilled={{.State.OOMKilled}} restarts={{.RestartCount}} started={{.State.StartedAt}}' rca-api 2>&1
  section "3. RESOURCE USAGE (docker stats)"; docker stats --no-stream 2>&1
  section "4. HEALTH ENDPOINT"
  curl -s -m 5 -w "\nHTTP %{http_code} in %{time_total}s\n" http://localhost:8080/health || echo "API NOT REACHABLE"
  section "5. API PROCESSES (ps inside container)"
  docker compose exec -T api ps -eo pid,ppid,rss,etime,cmd 2>&1
  section "6. LAST 15 ERROR/WARNING LOG LINES (logs/api/api.log)"
  grep -E '"level": "(ERROR|WARNING)"' logs/api/api.log 2>/dev/null | tail -15 | cut -c1-400
  section "7. GUNICORN / CONTAINER STDERR (last 20)"
  docker compose logs --tail 20 api 2>&1 | grep -v '"msg": "request completed"'
  section "8. MYSQL PROCESSLIST"
  $SQL -e "SELECT id, user, command, time, state, LEFT(info, 80) AS query FROM information_schema.processlist WHERE command <> 'Daemon' ORDER BY time DESC;" 2>&1 | grep -v Warning
  section "9. OPEN INNODB TRANSACTIONS"
  $SQL -e "SELECT trx_mysql_thread_id AS thread, trx_state, trx_started, TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s, trx_rows_locked FROM information_schema.innodb_trx;" 2>&1 | grep -v Warning
  section "10. LOCK WAITS (who blocks whom)"
  $SQL -e "SELECT waiting_pid, LEFT(waiting_query,60) AS waiting_query, blocking_pid, LEFT(blocking_query,40) AS blocking_query, wait_age, sql_kill_blocking_connection FROM sys.innodb_lock_waits;" 2>&1 | grep -v Warning
  section "11. SLOW QUERY LOG (last 15 lines)"
  docker compose exec -T mysql tail -n 15 /var/lib/mysql/slow.log 2>&1
  section "12. INDEXES ON orders"
  $SQL -e "SHOW INDEX FROM orders;" 2>&1 | grep -v Warning | awk '{print $3, $5}' | sort -u
} > "$OUT" 2>&1

echo "Diagnostic snapshot saved to $OUT"
