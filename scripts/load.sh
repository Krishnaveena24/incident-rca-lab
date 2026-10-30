#!/usr/bin/env bash
# =====================================================================
# load.sh - send concurrent traffic and print status codes + latency
# Usage: ./scripts/load.sh search   [requests] [parallel]
#        ./scripts/load.sh orders   [requests] [parallel]
#        ./scripts/load.sh products [requests] [parallel]
# =====================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1   # stops Git Bash on Windows from mangling /var/... paths
API="http://localhost:8080"
KIND="${1:-search}"; N="${2:-40}"; P="${3:-10}"

one() {
  case "$KIND" in
    search)   curl -s -o /dev/null -w "%{http_code} %{time_total}\n" "$API/orders/search?email=user$1@example.com" ;;
    orders)   curl -s -o /dev/null -w "%{http_code} %{time_total}\n" -X POST "$API/orders" \
                -H 'Content-Type: application/json' \
                -d "{\"customer_email\":\"load$1@example.com\",\"product_id\":$(( $1 % 10 + 1 )),\"quantity\":1}" ;;
    products) curl -s -o /dev/null -w "%{http_code} %{time_total}\n" "$API/products" ;;
  esac
}
export -f one; export API KIND

echo "Sending $N '$KIND' requests, $P in parallel..."
seq 1 "$N" | xargs -P "$P" -I{} bash -c 'one {}' | sort -k2 -n > /tmp/load_results.txt
echo "Status codes:"; awk '{print "  " $1}' /tmp/load_results.txt | sort | uniq -c
awk '{t[NR]=$2} END {
  i50 = int(NR*0.50); if (i50 < 1) i50 = 1
  i95 = int(NR*0.95); if (i95 < 1) i95 = 1
  printf "Latency (s): min=%.3f  p50=%.3f  p95=%.3f  max=%.3f\n", t[1], t[i50], t[i95], t[NR] }' /tmp/load_results.txt
