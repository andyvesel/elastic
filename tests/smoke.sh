#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=elasticsearch
DOMAIN=${DOMAIN:?DOMAIN env var required}

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }

# Pod is alive and ready
READY=$(kubectl get pods -n "$NAMESPACE" -l app=elasticsearch-master \
  -o jsonpath='{.items[*].status.containerStatuses[0].ready}')
[[ $(echo "$READY" | tr ' ' '\n' | grep -c true) -eq 3 ]] && pass "3 pods ready" || fail "Not all 3 pods ready"

# External endpoint reachable
EXT_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$DOMAIN/")
[[ "$EXT_CODE" == "401" || "$EXT_CODE" == "200" ]] && pass "External HTTPS reachable ($EXT_CODE)" \
  || fail "External endpoint unreachable (HTTP $EXT_CODE)"

echo "Smoke test passed"
