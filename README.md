# Elasticsearch on Kubernetes

The steps to deploy Elasticsearch 3-node HA cluster on Kubernetes.

It is designed to be provider-agnostic and can be scaled to any standard Kubernetes cluster of 4 nodes (1 control-plane, 3 workers).
Tested on a multiple k3s installations.

---

## Prerequisites

- A Kubernetes cluster with 4 nodes (1 control-plane, 3 workers with at least 4GB RAM each)
- `kubectl`, `helm` >= 3, `kubeseal` installed locally
- A domain with a DNS A record pointing to your cluster's public IP
- Port 80 and 443 open on the ingress node

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

kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.3/controller.yaml
```

### 3. Seal credentials

```bash
PASSWORD=$(openssl rand -base64 32)

kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d > pub.pem

cat <<EOF | kubeseal --format yaml --cert pub.pem > secrets/sealed-credentials.yaml
apiVersion: v1
kind: Secret
metadata:
  name: elasticsearch-credentials
  namespace: elasticsearch
type: Opaque
stringData:
  username: elastic
  password: "${PASSWORD}"
EOF

kubectl apply -f secrets/sealed-credentials.yaml
```

### 4. Deploy ES

```bash
helm dependency update
helm upgrade --install elasticsearch-k8s . \
  -n elasticsearch --create-namespace \
  --set domain=elastic.example.com \
  --set email=admin@example.com \
  --set storageProvisioner=<provisioner>
```

Storage provisioner values by platform:

| Platform | `storageProvisioner` |
|----------|----------------------|
| k3s / bare-metal | `rancher.io/local-path` |
| AWS EKS | `ebs.csi.aws.com` |
| GCP GKE | `pd.csi.storage.gke.io` |
| Azure AKS | `disk.csi.azure.com` |
| Longhorn | `driver.longhorn.io` |

### 5. Run the tests

```bash
bash tests/smoke.sh  # quick sanity check
bash tests/test.sh   # full suite
```

### Getting the access to ES

```bash
kubectl get secret elasticsearch-credentials -n elasticsearch \
  -o go-template='user: {{ index .data "username" | base64decode }}
pass: {{ index .data "password" | base64decode }}
'
```

### Teardown

```bash
bash teardown.sh
```

Removes the Helm release, sealed secret, namespace, StorageClass, and ClusterIssuer. Does not remove node labels/taints or cluster components (cert-manager, ingress-nginx, sealed-secrets controller).

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

**Sealed secret apply fails with "namespace not found"**

The namespace must exist before applying the sealed secret. Create it first:

```bash
kubectl create namespace elasticsearch
kubectl apply -f secrets/sealed-credentials.yaml
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

**Sealed secret not decrypting**

```bash
kubectl get pods -n kube-system | grep sealed
kubectl describe sealedsecret elasticsearch-credentials -n elasticsearch
```

If the cluster was rebuilt, the controller's private key changed. Re-seal using the new public key.

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
