#!/usr/bin/env bash
# Quick smoke test — ES is up and reachable
set -euo pipefail

NAMESPACE=elasticsearch
DOMAIN=elastic.veselov.cc

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }

ES_PASS=$(kubectl get secret elasticsearch-credentials -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 -d)

# ES responds on HTTPS
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -u "elastic:$ES_PASS" "https://$DOMAIN")
[[ "$HTTP_CODE" == "200" ]] && pass "ES is up (HTTPS 200)" || fail "ES not reachable (HTTP $HTTP_CODE)"

# Cluster is not red
STATUS=$(curl -sk -u "elastic:$ES_PASS" "https://$DOMAIN/_cluster/health" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"])')
[[ "$STATUS" != "red" ]] && pass "Cluster status: $STATUS" || fail "Cluster status is RED"

echo "Smoke test passed ✅"
