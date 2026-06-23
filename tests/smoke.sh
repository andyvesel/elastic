#!/usr/bin/env bash
# Quick smoke test — ES is up and reachable
set -euo pipefail

NAMESPACE=elasticsearch
DOMAIN=${DOMAIN:?DOMAIN env var required}

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }

ES_PASS=$(kubectl get secret elasticsearch-master-credentials -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 -d)

# ES responds on HTTPS (test from inside the cluster via kubectl exec)
for i in $(seq 1 12); do
  HTTP_CODE=$(kubectl exec -n "$NAMESPACE" elasticsearch-master-0 -c elasticsearch -- \
    curl -sk -o /dev/null -w '%{http_code}' -u "elastic:$ES_PASS" https://localhost:9200/ 2>/dev/null) && break
  sleep 5
done
[[ "$HTTP_CODE" == "200" ]] && pass "ES is up (HTTPS 200 from inside)" || fail "ES not reachable (HTTP $HTTP_CODE)"

# Cluster is not red
STATUS=$(kubectl exec -n "$NAMESPACE" elasticsearch-master-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASS" https://localhost:9200/_cluster/health 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"])')
[[ "$STATUS" != "red" ]] && pass "Cluster status: $STATUS" || fail "Cluster status is RED"

# External TLS reachable (401 is fine — proves TLS and routing work)
EXT_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$DOMAIN/")
[[ "$EXT_CODE" == "401" || "$EXT_CODE" == "200" ]] && pass "External TLS reachable ($EXT_CODE)" \
  || fail "External endpoint unreachable (HTTP $EXT_CODE)"

echo "Smoke test passed"
