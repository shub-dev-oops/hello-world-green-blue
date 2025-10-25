# hello-world-green-blue

This repository contains a minimal blue/green deployment demo for Amazon EKS that exposes a public-facing AWS Network Load Balancer (NLB) without using an Ingress controller. It includes:

- A sample Flask application with `/`, `/healthz`, and `/readyz` endpoints suitable for smoke checks.
- A Helm chart that deploys `blue` and `green` variants and flips traffic by updating a single LoadBalancer Service.
- A GitLab CI/CD pipeline that builds the container image, deploys the green environment, runs smoke tests, and offers manual promote/rollback jobs.
- Optional Kubernetes RBAC resources so the GitLab runner can manage the application.

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

Install the blue baseline (deployment only):

```bash
helm upgrade --install myapp-blue charts/myapp -n prod \
  --set color=blue \
  --set service.enabled=false \
  --set image.repository=<your-repo>/myapp \
  --set image.tag=demo
```

Create the shared router Service pointing to blue:

```bash
helm upgrade --install myapp-router charts/myapp -n prod \
  --set deployment.enabled=false \
  --set routeTo=blue
```

Deploy green when ready:

```bash
helm upgrade --install myapp-green charts/myapp -n prod \
  --set color=green \
  --set service.enabled=false \
  --set image.repository=<your-repo>/myapp \
  --set image.tag=demo
```

Promote by switching the router release:

```bash
helm upgrade --install myapp-router charts/myapp -n prod \
  --set deployment.enabled=false \
  --set routeTo=green
```

Rollback by setting `routeTo=blue` again (and keeping `deployment.enabled=false`).

## GitLab CI/CD pipeline

The `.gitlab-ci.yml` file defines the following stages:

1. **build** – builds and pushes the container image.
2. **deploy_green** – deploys the green release with Helm and waits for rollout.
3. **smoke** – runs basic readiness checks against the green pod.
4. **promote** (manual) – updates the Service selector to send traffic to green.
5. **rollback** (manual) – switches traffic back to blue.

Populate your Kubernetes credentials inside the pipeline (for example through `KUBECONFIG_CONTENT`) so the Helm commands can authenticate with your cluster.

## RBAC bootstrap

`rbac-myapp-ci.yaml` contains a ServiceAccount, Role, and RoleBinding that grant GitLab CI the permissions required to run the pipeline jobs. Apply it once per cluster/namespace:

```bash
kubectl create ns prod || true
kubectl -n prod apply -f rbac-myapp-ci.yaml
```

Feel free to tailor replica counts, probes, resource requests/limits, and security settings in `charts/myapp/values.yaml` to match your environment.
