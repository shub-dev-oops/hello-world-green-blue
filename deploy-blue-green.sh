#!/bin/bash
# Blue/Green deployment management script
# Usage: 
#   ./deploy-blue-green.sh setup <namespace> <image-tag> [image-repo]
#   ./deploy-blue-green.sh deploy-green <namespace> <image-tag> [image-repo]
#   ./deploy-blue-green.sh promote <namespace>
#   ./deploy-blue-green.sh rollback <namespace>
#   ./deploy-blue-green.sh status <namespace>

set -e

COMMAND=${1}
NAMESPACE=${2:-prod}
IMAGE_TAG=${3:-demo}
IMAGE_REPO=${4:-myapp}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Blue/Green Deployment Manager"
    echo ""
    echo "Usage:"
    echo "  $0 setup <namespace> <image-tag> [image-repo]"
    echo "      Initialize blue baseline and router service"
    echo ""
    echo "  $0 deploy-green <namespace> <new-image-tag> [image-repo]"
    echo "      Deploy new version to green deployment"
    echo ""
    echo "  $0 promote <namespace>"
    echo "      Switch traffic from blue to green"
    echo ""
    echo "  $0 rollback <namespace>"
    echo "      Switch traffic back to blue"
    echo ""
    echo "  $0 status <namespace>"
    echo "      Show current deployment status"
    echo ""
    echo "Examples:"
    echo "  $0 setup prod v1.0.0 myregistry.io/myapp"
    echo "  $0 deploy-green prod v1.1.0 myregistry.io/myapp"
    echo "  $0 promote prod"
    echo "  $0 rollback prod"
    exit 1
}

check_namespace() {
    if ! kubectl get namespace $NAMESPACE &> /dev/null; then
        echo -e "${RED}❌ Namespace '$NAMESPACE' does not exist${NC}"
        exit 1
    fi
}

get_current_target() {
    local target=$(kubectl -n $NAMESPACE get svc myapp -o jsonpath='{.spec.selector.color}' 2>/dev/null || echo "none")
    echo $target
}

show_status() {
    check_namespace
    
    echo -e "${BLUE}📋 Current Deployment Status${NC}"
    echo "Namespace: $NAMESPACE"
    echo ""
    
    # Check if router exists
    if ! kubectl -n $NAMESPACE get svc myapp &> /dev/null; then
        echo -e "${YELLOW}⚠️  Router service 'myapp' not found. Run 'setup' first.${NC}"
        exit 1
    fi
    
    local current_target=$(get_current_target)
    echo -e "🎯 Active traffic target: ${GREEN}${current_target}${NC}"
    echo ""
    
    echo "Deployments:"
    kubectl -n $NAMESPACE get deploy -l app=myapp -o wide 2>/dev/null || echo "  No deployments found"
    echo ""
    
    echo "Pods:"
    kubectl -n $NAMESPACE get pods -l app=myapp -o wide 2>/dev/null || echo "  No pods found"
    echo ""
    
    echo "Service:"
    kubectl -n $NAMESPACE get svc myapp 2>/dev/null || echo "  Service not found"
    echo ""
    
    echo -e "${BLUE}Service Selector:${NC}"
    kubectl -n $NAMESPACE get svc myapp -o jsonpath='{.spec.selector}' 2>/dev/null | jq || echo "{}"
}

setup_baseline() {
    echo -e "${BLUE}🔵 Setting up Blue/Green baseline${NC}"
    echo "Namespace: $NAMESPACE"
    echo "Image: $IMAGE_REPO:$IMAGE_TAG"
    echo ""
    
    # Create namespace
    echo -e "${YELLOW}1️⃣  Creating namespace...${NC}"
    kubectl create ns $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    
    # Deploy blue baseline
    echo -e "${YELLOW}2️⃣  Deploying BLUE baseline...${NC}"
    helm upgrade --install myapp-blue charts/myapp -n $NAMESPACE \
      --set color=blue \
      --set service.enabled=false \
      --set image.repository=$IMAGE_REPO \
      --set image.tag=$IMAGE_TAG
    
    # Wait for blue to be ready
    echo -e "${YELLOW}⏳ Waiting for blue deployment...${NC}"
    kubectl -n $NAMESPACE rollout status deploy/myapp-blue --timeout=120s
    
    # Create router pointing to blue
    echo -e "${YELLOW}3️⃣  Creating router Service (pointing to BLUE)...${NC}"
    helm upgrade --install myapp-router charts/myapp -n $NAMESPACE \
      --set deployment.enabled=false \
      --set service.enabled=true \
      --set routeTo=blue
    
    echo ""
    echo -e "${GREEN}✅ Setup complete!${NC}"
    echo ""
    show_status
    
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo "  1. Test the blue deployment:"
    echo "     kubectl -n $NAMESPACE port-forward deploy/myapp-blue 8080:8080"
    echo ""
    echo "  2. Deploy a new version to green:"
    echo "     $0 deploy-green $NAMESPACE <new-tag> $IMAGE_REPO"
}

deploy_green() {
    check_namespace
    
    echo -e "${GREEN}🟢 Deploying GREEN deployment${NC}"
    echo "Namespace: $NAMESPACE"
    echo "Image: $IMAGE_REPO:$IMAGE_TAG"
    echo ""
    
    # Deploy green
    echo -e "${YELLOW}1️⃣  Deploying GREEN deployment...${NC}"
    helm upgrade --install myapp-green charts/myapp -n $NAMESPACE \
      --set color=green \
      --set service.enabled=false \
      --set image.repository=$IMAGE_REPO \
      --set image.tag=$IMAGE_TAG
    
    # Wait for green to be ready
    echo -e "${YELLOW}⏳ Waiting for green deployment...${NC}"
    kubectl -n $NAMESPACE rollout status deploy/myapp-green --timeout=120s
    
    echo ""
    echo -e "${GREEN}✅ Green deployment ready!${NC}"
    echo ""
    
    local current_target=$(get_current_target)
    echo -e "Current traffic target: ${BLUE}${current_target}${NC}"
    echo ""
    
    echo -e "${BLUE}Next steps:${NC}"
    echo "  1. Test the green deployment:"
    echo "     kubectl -n $NAMESPACE port-forward deploy/myapp-green 8080:8080"
    echo ""
    echo "  2. Run smoke tests against green pods"
    echo ""
    echo "  3. Promote traffic to green:"
    echo "     $0 promote $NAMESPACE"
    echo ""
    echo "  4. If issues occur, rollback to blue:"
    echo "     $0 rollback $NAMESPACE"
}

promote_to_green() {
    check_namespace
    
    # Check if green deployment exists
    if ! kubectl -n $NAMESPACE get deploy myapp-green &> /dev/null; then
        echo -e "${RED}❌ Green deployment not found. Deploy green first:${NC}"
        echo "   $0 deploy-green $NAMESPACE <image-tag> [image-repo]"
        exit 1
    fi
    
    # Check if green pods are ready
    local green_ready=$(kubectl -n $NAMESPACE get deploy myapp-green -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local green_desired=$(kubectl -n $NAMESPACE get deploy myapp-green -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    
    if [ "$green_ready" != "$green_desired" ] || [ "$green_ready" == "0" ]; then
        echo -e "${RED}❌ Green deployment not ready: $green_ready/$green_desired pods${NC}"
        echo "Wait for green deployment to be fully ready before promoting."
        exit 1
    fi
    
    local current_target=$(get_current_target)
    
    if [ "$current_target" == "green" ]; then
        echo -e "${YELLOW}⚠️  Traffic is already routed to GREEN${NC}"
        exit 0
    fi
    
    echo -e "${GREEN}🔀 Promoting: Switching traffic from ${BLUE}BLUE${GREEN} → ${GREEN}GREEN${NC}"
    echo ""
    
    read -p "Continue with promotion? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Promotion cancelled."
        exit 0
    fi
    
    # Switch router to green
    helm upgrade --install myapp-router charts/myapp -n $NAMESPACE \
      --set deployment.enabled=false \
      --set service.enabled=true \
      --set routeTo=green
    
    echo ""
    echo -e "${GREEN}✅ Traffic switched to GREEN!${NC}"
    echo ""
    
    echo -e "${BLUE}Service selector:${NC}"
    kubectl -n $NAMESPACE get svc myapp -o jsonpath='{.spec.selector}' | jq
    echo ""
    
    echo -e "${BLUE}Monitor the application:${NC}"
    echo "  - Check metrics/logs for errors"
    echo "  - Verify application behavior"
    echo ""
    echo -e "${YELLOW}If issues arise, rollback immediately:${NC}"
    echo "  $0 rollback $NAMESPACE"
}

rollback_to_blue() {
    check_namespace
    
    # Check if blue deployment exists
    if ! kubectl -n $NAMESPACE get deploy myapp-blue &> /dev/null; then
        echo -e "${RED}❌ Blue deployment not found${NC}"
        exit 1
    fi
    
    local current_target=$(get_current_target)
    
    if [ "$current_target" == "blue" ]; then
        echo -e "${YELLOW}⚠️  Traffic is already routed to BLUE${NC}"
        exit 0
    fi
    
    echo -e "${RED}🔙 Rolling back: Switching traffic from ${GREEN}GREEN${RED} → ${BLUE}BLUE${NC}"
    echo ""
    
    read -p "Continue with rollback? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Rollback cancelled."
        exit 0
    fi
    
    # Switch router back to blue
    helm upgrade --install myapp-router charts/myapp -n $NAMESPACE \
      --set deployment.enabled=false \
      --set service.enabled=true \
      --set routeTo=blue
    
    echo ""
    echo -e "${GREEN}✅ Traffic switched back to BLUE!${NC}"
    echo ""
    
    echo -e "${BLUE}Service selector:${NC}"
    kubectl -n $NAMESPACE get svc myapp -o jsonpath='{.spec.selector}' | jq
    echo ""
}

# Main command dispatcher
case $COMMAND in
    setup)
        if [ -z "$NAMESPACE" ] || [ -z "$IMAGE_TAG" ]; then
            usage
        fi
        setup_baseline
        ;;
    deploy-green)
        if [ -z "$NAMESPACE" ] || [ -z "$IMAGE_TAG" ]; then
            usage
        fi
        deploy_green
        ;;
    promote)
        if [ -z "$NAMESPACE" ]; then
            usage
        fi
        promote_to_green
        ;;
    rollback)
        if [ -z "$NAMESPACE" ]; then
            usage
        fi
        rollback_to_blue
        ;;
    status)
        if [ -z "$NAMESPACE" ]; then
            usage
        fi
        show_status
        ;;
    *)
        usage
        ;;
esac
