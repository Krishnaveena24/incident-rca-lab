#!/usr/bin/env bash
# =====================================================================
# chaos.sh - inject and fix the 5 lab incidents
# Usage:  ./scripts/chaos.sh inject <1-5>
#         ./scripts/chaos.sh fix    <1-5>
#         ./scripts/chaos.sh list
# =====================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1   # stops Git Bash on Windows from mangling /var/... paths
cd "$(dirname "$0")/.."

ACTION="${1:-}"
CASE="${2:-}"
SQL="docker compose exec -T mysql mysql -uroot -prootpass shopdb"
API="http://localhost:8080"

banner() { echo; echo "==== [$(date '+%H:%M:%S')] $* ===="; }

wait_healthy() {
  echo -n "Waiting for $1 to be healthy"
  for _ in $(seq 1 60); do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = "healthy" ]; then
      echo " -> healthy"; return 0; fi
    echo -n "."; sleep 2
  done
  echo " -> TIMEOUT"; return 1
}

wait_api() {
  echo -n "Waiting for API"
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "$API/health"; then echo " -> up"; return 0; fi
    echo -n "."; sleep 1
  done
  echo " -> not responding"
}

list() {
  cat <<'EOF'
  1  HTTP 500 after a bad release (v1.1.0)        -> fix: rollback to v1.0.0
  2  Database down (MySQL container stopped)     -> fix: start MySQL, add restart policy
  3  Slow query (index dropped by a migration)   -> fix: recreate index
  4  Process failure (worker OOM-killed)         -> fix: deploy paginated export (v1.0.1)
  5  Lock wait timeout (open transaction)        -> fix: kill the blocking session
EOF
}

case "${ACTION}-${CASE}" in
  inject-1)
    banner "INJECT 1: deploying release v1.1.0"
    BUG_MODE=true APP_VERSION=1.1.0 docker compose up -d --no-deps api
    wait_api
    echo "Now try: POST $API/orders" ;;
  fix-1)
    banner "FIX 1: rolling back to v1.0.0"
    BUG_MODE=false APP_VERSION=1.0.0 docker compose up -d --no-deps api
    wait_api ;;

  inject-2)
    banner "INJECT 2: stopping MySQL"
    docker compose stop mysql ;;
  fix-2)
    banner "FIX 2: starting MySQL"
    docker compose start mysql
    wait_healthy rca-mysql ;;

  inject-3)
    banner "INJECT 3: migration drops idx_orders_customer_created"
    $SQL -e "ALTER TABLE orders DROP INDEX idx_orders_customer_created;" 2>&1 | grep -v Warning
    echo "Now run: ./scripts/load.sh search" ;;
  fix-3)
    banner "FIX 3: recreating index"
    $SQL -e "CREATE INDEX idx_orders_customer_created ON orders (customer_email, created_at);" 2>&1 | grep -v Warning
    $SQL -e "SHOW INDEX FROM orders;" 2>&1 | grep -v Warning ;;

  inject-4)
    banner "INJECT 4: partner calls the unbounded export endpoint"
    curl -sS -o /dev/null -w "HTTP %{http_code} after %{time_total}s\n" "$API/orders/export" \
      || echo "(request failed - that is the incident)" ;;
  fix-4)
    banner "FIX 4: deploying v1.0.1 with paginated export"
    EXPORT_PAGINATION=true APP_VERSION=1.0.1 docker compose up -d --no-deps api
    wait_api
    curl -s "$API/orders/export?limit=3" ; echo ;;

  inject-5)
    banner "INJECT 5: someone leaves a transaction open on product 1"
    docker compose exec -d mysql mysql -uroot -prootpass shopdb -e \
      "START TRANSACTION; UPDATE products SET stock = stock + 0 WHERE id = 1; DO SLEEP(600); COMMIT;"
    sleep 1
    echo "Now try: POST $API/orders with product_id 1 (it will hang ~15 s, then fail)" ;;
  fix-5)
    banner "FIX 5: finding and killing long-running transactions (> 20 s)"
    IDS=$($SQL -N -e "SELECT trx_mysql_thread_id FROM information_schema.innodb_trx
                      WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 20;" 2>/dev/null)
    if [ -z "$IDS" ]; then echo "No long-running transactions found."; fi
    for id in $IDS; do echo "KILL $id"; $SQL -e "KILL $id;" 2>/dev/null; done ;;

  list-*) list ;;
  *) echo "Usage: $0 inject|fix <1-5>   or   $0 list"; list; exit 1 ;;
esac
