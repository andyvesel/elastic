#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=elasticsearch
DOMAIN=${DOMAIN:?DOMAIN env var required}

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }

es_exec() {
  kubectl exec -n "$NAMESPACE" elasticsearch-master-0 -c elasticsearch -- sh -c "$1" 2>/dev/null
}

# 1. StorageClass
echo "--- StorageClass ---"
SC=$(kubectl get storageclass elasticsearch-storage -o json)
DEFAULT=$(echo "$SC" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["metadata"]["annotations"].get("storageclass.kubernetes.io/is-default-class","false"))')
[[ "$DEFAULT" == "true" ]]  && pass "StorageClass is default" || fail "StorageClass not default"
RECLAIM=$(echo "$SC" | python3 -c 'import sys,json; print(json.load(sys.stdin)["reclaimPolicy"])')
[[ "$RECLAIM" == "Retain" ]] && pass "ReclaimPolicy is Retain" || fail "ReclaimPolicy not Retain"

# 2. All 3 ES pods Running
echo "--- Pods ---"
READY=$(kubectl get pods -n "$NAMESPACE" -l app=elasticsearch-master \
  -o jsonpath='{.items[*].status.containerStatuses[0].ready}')
[[ $(echo "$READY" | tr ' ' '\n' | grep -c true) -eq 3 ]] && pass "3 pods ready" || fail "Not all 3 pods ready"

# 3. Each pod on a different node
echo "--- Anti-affinity ---"
NODES=$(kubectl get pods -n "$NAMESPACE" -l app=elasticsearch-master \
  -o jsonpath='{.items[*].spec.nodeName}')
UNIQUE=$(echo "$NODES" | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
[[ "$UNIQUE" -eq 3 ]] && pass "Each pod on a separate node" || fail "Pods share nodes"

# 4. Pods only on elasticsearch-labeled nodes
echo "--- Node dedication ---"
for node in $(kubectl get pods -n "$NAMESPACE" -l app=elasticsearch-master \
  -o jsonpath='{.items[*].spec.nodeName}'); do
  LABEL=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.role}')
  [[ "$LABEL" == "elasticsearch" ]] && pass "Node $node dedicated" || fail "Node $node not dedicated"
done

# 5. ES responds inside pod (uses pod's own env, no secret access needed)
echo "--- ES health ---"
STATUS=$(es_exec 'curl -sk -u elastic:$ELASTIC_PASSWORD https://localhost:9200/_cluster/health' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"])')
[[ "$STATUS" == "green" ]] && pass "Cluster status green" || fail "Cluster status: $STATUS"

# 6. External TLS reachable
echo "--- TLS ---"
EXT_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$DOMAIN/")
[[ "$EXT_CODE" == "401" || "$EXT_CODE" == "200" ]] && pass "External HTTPS reachable ($EXT_CODE)" \
  || fail "External endpoint unreachable (HTTP $EXT_CODE)"

echo ""
echo "All tests passed"
