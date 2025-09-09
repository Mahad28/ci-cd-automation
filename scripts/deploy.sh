#!/bin/bash

# CI/CD Deployment Script
# Author: Mahad Siddiqui
# Description: Automated deployment script for test automation framework

set -e

# Configuration
ENVIRONMENT=${1:-staging}
VERSION=${2:-latest}
NAMESPACE="test-automation-${ENVIRONMENT}"
DOCKER_REGISTRY="your-registry.com"
IMAGE_NAME="test-automation"
FULL_IMAGE_NAME="${DOCKER_REGISTRY}/${IMAGE_NAME}:${VERSION}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    
    # Check if docker is installed
    if ! command -v docker &> /dev/null; then
        log_error "docker is not installed or not in PATH"
        exit 1
    fi
    
    # Check if helm is installed
    if ! command -v helm &> /dev/null; then
        log_warn "helm is not installed, some features may not work"
    fi
    
    log_info "Prerequisites check completed"
}

# Build Docker image
build_image() {
    log_info "Building Docker image..."
    
    docker build -t ${FULL_IMAGE_NAME} -f docker/Dockerfile .
    
    if [ $? -eq 0 ]; then
        log_info "Docker image built successfully: ${FULL_IMAGE_NAME}"
    else
        log_error "Failed to build Docker image"
        exit 1
    fi
}

# Push Docker image
push_image() {
    log_info "Pushing Docker image to registry..."
    
    docker push ${FULL_IMAGE_NAME}
    
    if [ $? -eq 0 ]; then
        log_info "Docker image pushed successfully"
    else
        log_error "Failed to push Docker image"
        exit 1
    fi
}

# Deploy to Kubernetes
deploy_to_k8s() {
    log_info "Deploying to Kubernetes namespace: ${NAMESPACE}"
    
    # Create namespace if it doesn't exist
    kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
    
    # Apply Kubernetes manifests
    kubectl apply -f kubernetes/deployments/${ENVIRONMENT}/ -n ${NAMESPACE}
    kubectl apply -f kubernetes/services/${ENVIRONMENT}/ -n ${NAMESPACE}
    
    # Update deployment with new image
    kubectl set image deployment/test-automation test-automation=${FULL_IMAGE_NAME} -n ${NAMESPACE}
    
    # Wait for rollout to complete
    kubectl rollout status deployment/test-automation -n ${NAMESPACE} --timeout=300s
    
    if [ $? -eq 0 ]; then
        log_info "Deployment completed successfully"
    else
        log_error "Deployment failed"
        exit 1
    fi
}

# Run health checks
run_health_checks() {
    log_info "Running health checks..."
    
    # Get service URL
    SERVICE_URL=$(kubectl get service test-automation -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    
    if [ -z "$SERVICE_URL" ]; then
        SERVICE_URL="localhost:8080"
    fi
    
    # Wait for service to be ready
    log_info "Waiting for service to be ready..."
    sleep 30
    
    # Check health endpoint
    if curl -f http://${SERVICE_URL}/health; then
        log_info "Health check passed"
    else
        log_error "Health check failed"
        exit 1
    fi
}

# Run smoke tests
run_smoke_tests() {
    log_info "Running smoke tests..."
    
    # Run basic smoke tests
    kubectl run smoke-test --image=curlimages/curl --rm -i --restart=Never -- \
        curl -f http://test-automation.${NAMESPACE}.svc.cluster.local:8080/health
    
    if [ $? -eq 0 ]; then
        log_info "Smoke tests passed"
    else
        log_error "Smoke tests failed"
        exit 1
    fi
}

# Cleanup old deployments
cleanup_old_deployments() {
    log_info "Cleaning up old deployments..."
    
    # Keep only last 3 deployments
    kubectl get replicasets -n ${NAMESPACE} -l app=test-automation --sort-by=.metadata.creationTimestamp | \
    tail -n +4 | awk '{print $1}' | xargs -r kubectl delete replicaset -n ${NAMESPACE}
    
    log_info "Cleanup completed"
}

# Send notification
send_notification() {
    local status=$1
    local message=$2
    
    if [ ! -z "$SLACK_WEBHOOK" ]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"${message}\"}" \
            ${SLACK_WEBHOOK}
    fi
}

# Main deployment function
main() {
    log_info "Starting deployment process..."
    log_info "Environment: ${ENVIRONMENT}"
    log_info "Version: ${VERSION}"
    log_info "Image: ${FULL_IMAGE_NAME}"
    
    # Check prerequisites
    check_prerequisites
    
    # Build and push image
    build_image
    push_image
    
    # Deploy to Kubernetes
    deploy_to_k8s
    
    # Run health checks
    run_health_checks
    
    # Run smoke tests
    run_smoke_tests
    
    # Cleanup old deployments
    cleanup_old_deployments
    
    # Send success notification
    send_notification "success" "✅ Deployment to ${ENVIRONMENT} completed successfully! Version: ${VERSION}"
    
    log_info "Deployment process completed successfully!"
}

# Error handling
trap 'log_error "Deployment failed at line $LINENO"; send_notification "error" "❌ Deployment to ${ENVIRONMENT} failed! Version: ${VERSION}"; exit 1' ERR

# Run main function
main "$@"
