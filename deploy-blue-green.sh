#!/bin/bash
# Blue/Green deployment management script
# Usage: 
#   ./deploy-blue-green.sh promote
#   ./deploy-blue-green.sh rollback
#   ./deploy-blue-green.sh status

set -e

# Configuration - Update these values for your environment
NAMESPACE="prod"
IMAGE_REPO="registry.gixtlab.com/ORG/PROJ/myapp"
IMAGE_TAG="latest"

COMMAND=${1}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Blue/Green Deployment Manager"
    echo ""
    echo "Configuration:"
    echo "  Namespace:  $NAMESPACE"
    echo "  Image:      $IMAGE_REPO:$IMAGE_TAG"
    echo ""
    echo "Usage:"
    echo "  $0 promote"
    echo "      Switch traffic from blue to green"
    echo ""
    echo "  $0 rollback"
    echo "      Switch traffic back to blue"
    echo ""
    echo "  $0 status"
    echo "      Show current deployment status"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 promote"
    echo "  $0 rollback"
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
    
    echo -e "${BLUE}📋 Blue/Green Deployment Status${NC}"
    echo "Namespace: $NAMESPACE"
    echo "Image:     $IMAGE_REPO:$IMAGE_TAG"
    echo ""
    
    # Check if router exists
    if ! kubectl -n $NAMESPACE get svc myapp &> /dev/null; then
        echo -e "${YELLOW}⚠️  Router service 'myapp' not found.${NC}"
        echo "Make sure deployments are created via CI/CD pipeline first."
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

promote_to_green() {
    check_namespace
    
    # Check if green deployment exists
    if ! kubectl -n $NAMESPACE get deploy myapp-green &> /dev/null; then
        echo -e "${RED}❌ Green deployment not found.${NC}"
        echo "Deploy green via CI/CD pipeline first."
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
    echo "Namespace: $NAMESPACE"
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
    echo "  $0 rollback"
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
    echo "Namespace: $NAMESPACE"
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
    promote)
        promote_to_green
        ;;
    rollback)
        rollback_to_blue
        ;;
    status)
        show_status
        ;;
    *)
        usage
        ;;
esac
