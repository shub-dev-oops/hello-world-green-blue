# hello-world-green-blue

This repository contains a minimal blue/green deployment demo for Amazon EKS that exposes a public-facing AWS Network Load Balancer (NLB) without using an Ingress controller. It includes:

- A sample Flask application with `/`, `/healthz`, and `/readyz` endpoints suitable for smoke checks.
- A Helm chart that deploys `blue` and `green` variants and flips traffic by updating a single LoadBalancer Service.
- A GitLab CI/CD pipeline that builds the container image, deploys the green environment, runs smoke tests, and offers manual promote/rollback jobs.
- Optional Kubernetes RBAC resources so the GitLab runner can manage the application.

## Architecture

This setup uses a **three-release pattern**:

1. **`myapp-blue`** - Deployment with `color=blue` label (Deployment only, no Service)
2. **`myapp-green`** - Deployment with `color=green` label (Deployment only, no Service)
3. **`myapp-router`** - Shared LoadBalancer Service that routes to either blue or green (Service only, no Deployment)

Traffic switching is instantaneous - the router Service's selector updates from `color: blue` → `color: green` without changing the AWS NLB endpoint.

## Public Load Balancer accessibility

The Service is created with the annotation `service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"`, so AWS provisions a public NLB. You can reach the app from the internet using the DNS name (or static Elastic IPs if configured) that appears under `EXTERNAL-IP` when you run:

```bash
kubectl -n <namespace> get svc myapp
```

If you prefer an internal-only load balancer, change the annotation value to `"internal"` in `charts/myapp/values.yaml`.

## Sample application

The sample application lives under `app/` and is packaged via the root `Dockerfile`. It echoes the deployment color and other metadata, making it obvious which variant is serving traffic.

To run it locally:

```bash
pip install -r requirements.txt
export APP_COLOR=blue
python -m app.main
```

Then visit `http://localhost:8080/`.

## Building and pushing the image

Update `IMAGE_REPO` in `.gitlab-ci.yml` (and `charts/myapp/values.yaml`) to point to your container registry. The pipeline builds `registry.gitlab.com/ORG/PROJ/myapp:<SHA>` and the Helm chart uses that image tag for each deployment.

For manual builds:

```bash
docker build -t <your-repo>/myapp:demo .
docker push <your-repo>/myapp:demo
```

## Deploying with Helm

### Initial Setup (One-Time)

Create the namespace and deploy the blue baseline:

```bash
# Create namespace
kubectl create ns prod || true

# Deploy blue baseline (Deployment only, no Service)
helm upgrade --install myapp-blue charts/myapp -n prod \
  --set color=blue \
  --set service.enabled=false \
  --set image.repository=<your-repo>/myapp \
  --set image.tag=v1.0.0

# Create the shared router Service pointing to blue
# This creates the public AWS NLB
helm upgrade --install myapp-router charts/myapp -n prod \
  --set deployment.enabled=false \
  --set service.enabled=true \
  --set routeTo=blue
```

### Blue/Green Deployment Workflow

When deploying a new version:

```bash
# 1. Deploy green (Deployment only, no Service)
helm upgrade --install myapp-green charts/myapp -n prod \
  --set color=green \
  --set service.enabled=false \
  --set image.repository=<your-repo>/myapp \
  --set image.tag=v1.1.0

# 2. Test green pods directly (port-forward or exec into pod)
kubectl -n prod port-forward deploy/myapp-green 8080:8080

# 3. Promote: switch router to point to green
helm upgrade --install myapp-router charts/myapp -n prod \
  --set deployment.enabled=false \
  --set service.enabled=true \
  --set routeTo=green

# 4. If issues arise, rollback to blue instantly
helm upgrade --install myapp-router charts/myapp -n prod \
  --set deployment.enabled=false \
  --set service.enabled=true \
  --set routeTo=blue

# 5. Once green is stable, update blue for next cycle
helm upgrade --install myapp-blue charts/myapp -n prod \
  --set color=blue \
  --set service.enabled=false \
  --set image.repository=<your-repo>/myapp \
  --set image.tag=v1.1.0
```

## GitLab CI/CD pipeline

The `.gitlab-ci.yml` file defines the following stages:

1. **build** – builds and pushes the container image.
2. **deploy_green** – deploys the green release with Helm and waits for rollout.
3. **smoke** – runs basic readiness checks against the green pod.
4. **promote** (manual) – updates the Service selector to send traffic to green.
5. **rollback** (manual) – switches traffic back to blue.

Populate your Kubernetes credentials inside the pipeline (for example through `KUBECONFIG_CONTENT`) so the Helm commands can authenticate with your cluster.

## Node Affinity and Public Subnet Placement

**Why this matters**: Because this setup does **not** use the AWS Load Balancer Controller, the NLB is provisioned as a classic Kubernetes `type: LoadBalancer` Service. The NLB targets worker nodes directly (not pods), so your pods must run on nodes that are reachable by the NLB.

### Strategies for Ensuring NLB Reachability

#### Option A: Zone-Based Affinity (Recommended for Multi-AZ)

If your public subnets exist only in specific availability zones, you can constrain pods to those AZs using `nodeAffinity`:

```bash
# Deploy blue to us-west-2a (where public subnets exist)
helm upgrade --install myapp-blue charts/myapp -n prod \
  --set color=blue \
  --set service.enabled=false \
  --set image.repository=<your-repo>/myapp \
  --set image.tag=v1.0.0 \
  --set nodeAffinity.enabled=true \
  --set nodeAffinity.required.key=topology.kubernetes.io/zone \
  --set nodeAffinity.required.values[0]=us-west-2a
```

**Notes**:
- `topology.kubernetes.io/zone` is the standard Kubernetes label for AZ (replaces the deprecated `failure-domain.beta.kubernetes.io/zone`).
- Use `nodeAffinity.required` to guarantee scheduling only in allowed zones.
- For multi-AZ deployments, pass multiple zones:
  ```bash
  --set nodeAffinity.required.values[0]=us-west-2a \
  --set nodeAffinity.required.values[1]=us-west-2b
  ```

#### Option B: Node Labels (Recommended for Mixed Public/Private Node Groups)

Create a dedicated node group for nodes in public subnets and label them at creation time, or label existing nodes manually:

**1. Label nodes in the public-subnet node group:**
```bash
kubectl label node <node-name> subnet-type=public
```

**2. Deploy using `nodeSelector`:**
```bash
helm upgrade --install myapp-blue charts/myapp -n prod \
  --set color=blue \
  --set service.enabled=false \
  --set image.repository=<your-repo>/myapp \
  --set image.tag=v1.0.0 \
  --set nodeSelector.subnet-type=public
```

**Best practice**: If using EKS managed node groups or self-managed Auto Scaling groups, add the label to the launch template so all nodes in the group inherit it automatically.

#### Option C: Tolerations (For Tainted Public Nodes)

If you taint public nodes to prevent non-NLB workloads from scheduling there:

**1. Taint the public nodes:**
```bash
kubectl taint nodes <node-name> public=true:NoSchedule
```

**2. Deploy with toleration:**
```bash
helm upgrade --install myapp-blue charts/myapp -n prod \
  --set color=blue \
  --set service.enabled=false \
  --set image.repository=<your-repo>/myapp \
  --set image.tag=v1.0.0 \
  --set tolerations[0].key=public \
  --set tolerations[0].operator=Equal \
  --set tolerations[0].value=true \
  --set tolerations[0].effect=NoSchedule
```

### externalTrafficPolicy Considerations

- **`externalTrafficPolicy: Cluster`** (default in `values.yaml`):
  - NLB forwards to any node; kube-proxy NATs to pods on other nodes if needed.
  - Client source IP is lost (replaced with node IP).
  - More resilient to pod distribution imbalances.

- **`externalTrafficPolicy: Local`**:
  - NLB only forwards to nodes that have a local ready pod.
  - Preserves client source IP.
  - Requires pods to be distributed across all nodes that will receive NLB traffic (use `podAntiAffinity` or `topologySpreadConstraints` to ensure this).

If using `Local`, ensure each AZ that the NLB targets has at least one running pod, or those targets will fail health checks.

### Example: Complete Deployment with Zone Affinity

```bash
# Create namespace
kubectl create ns prod || true

# Deploy blue to public AZs (Deployment only, no Service)
helm upgrade --install myapp-blue charts/myapp -n prod \
  --set color=blue \
  --set service.enabled=false \
  --set image.repository=<your-repo>/myapp \
  --set image.tag=v1.0.0 \
  --set nodeAffinity.enabled=true \
  --set nodeAffinity.required.key=topology.kubernetes.io/zone \
  --set nodeAffinity.required.values[0]=us-west-2a \
  --set nodeAffinity.required.values[1]=us-west-2b

# Create the shared router Service pointing to blue (creates the public AWS NLB)
helm upgrade --install myapp-router charts/myapp -n prod \
  --set deployment.enabled=false \
  --set service.enabled=true \
  --set routeTo=blue

# Wait for NLB DNS
kubectl -n prod get svc myapp -w

# Deploy green to the same AZs
helm upgrade --install myapp-green charts/myapp -n prod \
  --set color=green \
  --set service.enabled=false \
  --set image.repository=<your-repo>/myapp \
  --set image.tag=v1.1.0 \
  --set nodeAffinity.enabled=true \
  --set nodeAffinity.required.key=topology.kubernetes.io/zone \
  --set nodeAffinity.required.values[0]=us-west-2a \
  --set nodeAffinity.required.values[1]=us-west-2b

# Test green pods directly
kubectl -n prod port-forward deploy/myapp-green 8080:8080

# Promote to green
helm upgrade --install myapp-router charts/myapp -n prod \
  --set deployment.enabled=false \
  --set service.enabled=true \
  --set routeTo=green
```

## RBAC bootstrap

`rbac-myapp-ci.yaml` contains a ServiceAccount, Role, and RoleBinding that grant GitLab CI the permissions required to run the pipeline jobs. Apply it once per cluster/namespace:

```bash
kubectl create ns prod || true
kubectl -n prod apply -f rbac-myapp-ci.yaml
```

Feel free to tailor replica counts, probes, resource requests/limits, and security settings in `charts/myapp/values.yaml` to match your environment.
