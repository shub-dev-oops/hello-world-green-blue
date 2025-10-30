#!/bin/bash
# Quick test script to validate blue/green deployment pattern
# Usage: ./test-blue-green.sh <namespace> <image-tag>

set -e

NAMESPACE=${1:-prod}
IMAGE_TAG=${2:-demo}
IMAGE_REPO=${3:-myapp}

echo "🔵 Setting up Blue/Green test in namespace: $NAMESPACE"
echo "📦 Using image: $IMAGE_REPO:$IMAGE_TAG"
echo ""

# Create namespace
echo "1️⃣  Creating namespace..."
kubectl create ns $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Deploy blue
echo "2️⃣  Deploying BLUE deployment..."
helm upgrade --install myapp-blue charts/myapp -n $NAMESPACE \
  --set color=blue \
  --set service.enabled=false \
  --set image.repository=$IMAGE_REPO \
  --set image.tag=$IMAGE_TAG

# Deploy green
echo "3️⃣  Deploying GREEN deployment..."
helm upgrade --install myapp-green charts/myapp -n $NAMESPACE \
  --set color=green \
  --set service.enabled=false \
  --set image.repository=$IMAGE_REPO \
  --set image.tag=$IMAGE_TAG

# Wait for deployments
echo "⏳ Waiting for deployments to be ready..."
kubectl -n $NAMESPACE rollout status deploy/myapp-blue --timeout=120s
kubectl -n $NAMESPACE rollout status deploy/myapp-green --timeout=120s

# Create router pointing to blue
echo "4️⃣  Creating router Service (pointing to BLUE)..."
helm upgrade --install myapp-router charts/myapp -n $NAMESPACE \
  --set deployment.enabled=false \
  --set service.enabled=true \
  --set routeTo=blue

echo ""
echo "✅ Setup complete!"
echo ""
echo "📋 Current state:"
kubectl -n $NAMESPACE get deploy,svc,pods -l app=myapp

echo ""
echo "🔍 Service selector (should point to blue):"
kubectl -n $NAMESPACE get svc myapp -o jsonpath='{.spec.selector}' | jq
echo ""

echo "🧪 To test the traffic switch:"
echo "   # Switch to green:"
echo "   helm upgrade --install myapp-router charts/myapp -n $NAMESPACE --set deployment.enabled=false --set service.enabled=true --set routeTo=green"
echo ""
echo "   # Verify selector changed:"
echo "   kubectl -n $NAMESPACE get svc myapp -o jsonpath='{.spec.selector}' | jq"
echo ""
echo "   # Rollback to blue:"
echo "   helm upgrade --install myapp-router charts/myapp -n $NAMESPACE --set deployment.enabled=false --set service.enabled=true --set routeTo=blue"
