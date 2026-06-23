#!/usr/bin/env bash
set -euo pipefail

echo "=== Smoke test ==="
bash "$(dirname "$0")/smoke.sh"
echo ""
echo "=== Full test suite ==="

NAMESPACE=elasticsearch
DOMAIN=${DOMAIN:?DOMAIN env var required}
ES_PASS=$(kubectl get secret elasticsearch-master-credentials -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 -d)

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }

es_curl() {
  kubectl exec -n "$NAMESPACE" elasticsearch-master-0 -c elasticsearch -- \
    curl -sk -u "elastic:$ES_PASS" "$@" 2>/dev/null
}

# 1. StorageClass is default with Retain
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
[[ "$UNIQUE" -eq 3 ]] && pass "Each pod on a separate node" || fail "Pods share nodes (got $UNIQUE unique nodes)"

# 4. Pods only on elasticsearch-labeled nodes
echo "--- Node dedication ---"
for node in $(kubectl get pods -n "$NAMESPACE" -l app=elasticsearch-master \
  -o jsonpath='{.items[*].spec.nodeName}'); do
  LABEL=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.role}')
  [[ "$LABEL" == "elasticsearch" ]] && pass "Node $node has role=elasticsearch" \
    || fail "Node $node missing role=elasticsearch label"
done

# 5. Cluster health green, 3 nodes
echo "--- Cluster health ---"
HEALTH=$(es_curl https://localhost:9200/_cluster/health)
STATUS=$(echo "$HEALTH" | python3 -c 'import sys,json; h=json.load(sys.stdin); print(h["status"])')
NNODES=$(echo "$HEALTH" | python3 -c 'import sys,json; h=json.load(sys.stdin); print(h["number_of_nodes"])')
[[ "$STATUS" == "green" ]] && pass "Cluster status green" || fail "Cluster status: $STATUS"
[[ "$NNODES" -eq 3 ]]      && pass "3 nodes in cluster"  || fail "Expected 3 nodes, got $NNODES"

# 6. External HTTPS with valid cert
echo "--- TLS ---"
CERT_VALID=$(curl -sv --max-time 5 "https://$DOMAIN" 2>&1 | grep -c "SSL certificate verify ok" || true)
[[ "$CERT_VALID" -gt 0 ]] && pass "TLS certificate valid" || fail "TLS certificate invalid"

EXT_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$DOMAIN/")
[[ "$EXT_CODE" == "401" || "$EXT_CODE" == "200" ]] && pass "External HTTPS reachable ($EXT_CODE)" \
  || fail "External endpoint unreachable (HTTP $EXT_CODE)"

# 7. Data persists after pod deletion
echo "--- Persistence ---"
DOC_ID="test-persist-$(date +%s)"
WRITE=$(es_curl -X PUT "https://localhost:9200/test-index/_doc/$DOC_ID" \
  -H 'Content-Type: application/json' -d '{"test":"persistence"}')
echo "$WRITE" | grep -q '"result":"created"' && pass "Document written" || fail "Failed to write document"

kubectl delete pod elasticsearch-master-0 -n "$NAMESPACE"
echo "Waiting for pod to restart..."
sleep 5
kubectl wait pod/elasticsearch-master-0 -n "$NAMESPACE" \
  --for=condition=Ready --timeout=120s

RESULT=$(es_curl "https://localhost:9200/test-index/_doc/$DOC_ID")
echo "$RESULT" | grep -q '"found":true' && pass "Document persists after pod restart" || fail "Document lost after restart"

# Cleanup
es_curl -X DELETE "https://localhost:9200/test-index" > /dev/null

echo ""
echo "All tests passed"
