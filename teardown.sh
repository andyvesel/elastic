#!/usr/bin/env bash
# Removes all deployed resources. Does NOT delete node labels/taints or cluster components.
set -euo pipefail

NAMESPACE=elasticsearch

helm uninstall elasticsearch-k8s -n $NAMESPACE 2>/dev/null || true
kubectl delete -f secrets/sealed-credentials.yaml 2>/dev/null || true
kubectl delete ns $NAMESPACE --ignore-not-found
kubectl delete storageclass elasticsearch-storage --ignore-not-found
kubectl delete clusterissuer letsencrypt-prod --ignore-not-found

echo "Teardown complete"
