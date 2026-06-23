# Elasticsearch on Kubernetes

The steps to deploy Elasticsearch 3-node HA cluster on Kubernetes.

It is designed to be provider-agnostic and can be scaled to any standard Kubernetes cluster of 4 nodes (1 control-plane, 3 workers).
Tested on a multiple k3s installations.

---

## Prerequisites

- A Kubernetes cluster with 4 nodes (1 control-plane, 3 workers with at least 4GB RAM each)
- `kubectl`, `helm` >= 3 installed locally
- A domain with a DNS A record pointing to your cluster's public IP
- Port 80 and 443 open on the ingress node

**Set the CI/CD variables**

If deploying via a pipeline (GitHub Actions, GitLab CI, Jenkins, etc.), set the following as repository/environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `DOMAIN` | Public domain for the ES endpoint | `elastic.example.com` |
| `EMAIL` | Let's Encrypt registration email | `admin@example.com` |
| `STORAGE_PROVISIONER` | CSI provisioner for your platform | `rancher.io/local-path` |
| `KUBECONFIG` | *(secret)* base64-encoded kubeconfig for a scoped service account | — |

The `KUBECONFIG` secret should use the scoped `elasticsearch-deployer` service account (see `ci/deployer-rbac.yaml`), not the cluster admin kubeconfig. This limits blast radius if the credential leaks.

**Local deployment:**

```bash
export DOMAIN=elastic.example.com
export EMAIL=admin@example.com
export STORAGE_PROVISIONER=rancher.io/local-path
```

---

## Deployment

### 1. Prepare worker nodes

```bash
for node in <es-node-1> <es-node-2> <es-node-3>; do
  kubectl label node $node role=elasticsearch
  kubectl taint node $node dedicated=elasticsearch:NoSchedule
done
```

### 2. Install cluster components

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --set crds.enabled=true

# On bare-metal, set externalIPs to your public IP.
# On cloud providers, omit the externalIPs flag.
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set "controller.service.externalIPs={<public-ip>}"
```

### 3. Deploy ES

```bash
helm dependency update
helm upgrade --install elasticsearch-k8s . \
  -n elasticsearch --create-namespace \
  --set domain=$DOMAIN \
  --set email=$EMAIL \
  --set storageProvisioner=$STORAGE_PROVISIONER
```

Storage provisioner values by platform:

| Platform | `storageProvisioner` |
|----------|----------------------|
| k3s / bare-metal | `rancher.io/local-path` |
| AWS EKS | `ebs.csi.aws.com` |
| GCP GKE | `pd.csi.storage.gke.io` |
| Azure AKS | `disk.csi.azure.com` |
| Longhorn | `driver.longhorn.io` |

Ready-made values files for each platform are in `examples/`.

### 5. Run the tests

```bash
bash tests/smoke.sh  # quick sanity check
bash tests/test.sh   # full suite
```

### Getting the access to ES

```bash
kubectl get secret elasticsearch-master-credentials -n elasticsearch \
  -o go-template='user: {{ index .data "username" | base64decode }}
pass: {{ index .data "password" | base64decode }}
'
```

### Teardown

```bash
bash teardown.sh
```

Removes the Helm release, namespace, StorageClass, and ClusterIssuer. Does not remove node labels/taints or cluster components (cert-manager, ingress-nginx).

---

## Troubleshooting

**cert-manager install hangs or "another operation is in progress"**

This happens when a previous install left behind CRDs or a stuck Helm release state. Clean up and retry:

```bash
# Remove stuck Helm release
helm delete cert-manager -n cert-manager 2>/dev/null || true
kubectl delete ns cert-manager --force --grace-period=0 2>/dev/null || true

# Remove leftover CRDs (Helm keeps these on uninstall by default)
kubectl get crd | grep cert-manager | awk '{print $1}' | xargs kubectl delete crd

# Reinstall
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --set crds.enabled=true
```

**Pods stuck in `Pending`**

```bash
kubectl describe pod <pod-name> -n elasticsearch | grep -A10 Events
```

Check that nodes are labeled `role=elasticsearch` and tainted `dedicated=elasticsearch:NoSchedule`, and that the chart tolerations match.

**Certificate not issuing**

```bash
kubectl describe certificaterequest -n elasticsearch
kubectl describe order -n elasticsearch
```

Verify `http://<domain>/.well-known/acme-challenge/` is publicly reachable and port 80 is open. On bare-metal confirm `externalIPs` is set on the ingress-nginx service.

**Worker node `NotReady` or agent not joining**

Port 6443 is likely blocked. Verify and restart the agent:

```bash
nc -zv <control-plane-ip> 6443
systemctl restart k3s-agent
```

**Cluster status `red`**

```bash
kubectl exec -n elasticsearch elasticsearch-master-0 -- \
  curl -sk -u elastic:<password> https://localhost:9200/_cluster/health?pretty

kubectl exec -n elasticsearch elasticsearch-master-0 -- \
  curl -sk -u elastic:<password> "https://localhost:9200/_cat/shards?v" | grep UNASSIGNED
```

Red means unassigned primary shards. Check that all 3 pods are running and PVCs are bound.

**PVC not binding**

`WaitForFirstConsumer` means the PVC binds only once a pod is scheduled. Fix the pod scheduling issue first, then the PVC will bind automatically.
