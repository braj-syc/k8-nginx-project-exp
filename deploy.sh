#!/bin/bash
# ============================================================
# Full Stack K8s Deploy Script
# Usage:
#   1. git clone your repo
#   2. cd into repo
#   3. nano deploy.sh and set DOCKERHUB_USERNAME
#   4. chmod +x deploy.sh
#   5. docker login -u your_username
#   6. ./deploy.sh
# ============================================================

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check() { if [ $? -ne 0 ]; then error "$1 failed. Exiting."; fi }

# ============================================================
# CONFIGURE THIS BEFORE RUNNING
# ============================================================
DOCKERHUB_USERNAME="brajsharma"
# ============================================================

echo ""
echo "============================================================"
echo "   K8s Full Stack Deploy Script — $(date)"
echo "============================================================"
echo ""

# ─── Validate config ─────────────────────────────────────────
if [ -z "$DOCKERHUB_USERNAME" ]; then
  error "Please set DOCKERHUB_USERNAME at the top of this script before running."
fi

# ─── Root check ──────────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
  error "Do NOT run this script as root. Run as azureuser."
fi

# ─── Repo structure check ────────────────────────────────────
if [ ! -f "deploy.sh" ] || [ ! -d "k8s" ] || [ ! -d "frontend" ] || [ ! -d "backend" ]; then
  error "Please run this script from the root of the cloned repo directory."
fi

# ============================================================
# STEP 1 — Install Docker if not present
# ============================================================
log "Step 1/8 — Checking Docker"
if ! command -v docker &>/dev/null; then
  log "Docker not found — installing..."
  sudo apt update -y
  sudo apt install -y docker.io
  sudo systemctl enable --now docker
  sudo usermod -aG docker $USER
  check "Docker install"
  success "Docker installed — re-launching with docker group active..."
  exec sg docker "$0 $*"
else
  if ! groups $USER | grep -q docker; then
    sudo usermod -aG docker $USER
    exec sg docker "$0 $*"
  fi
  success "Docker already installed"
fi

# ============================================================
# STEP 2 — Verify Docker Hub login
# ============================================================
log "Step 2/8 — Verifying Docker Hub login"
if ! cat ~/.docker/config.json 2>/dev/null | grep -q "auths"; then
  error "Not logged in to Docker Hub. Please run 'docker login -u ${DOCKERHUB_USERNAME}' first then re-run this script."
fi
success "Docker Hub credentials found"

# ============================================================
# STEP 3 — Build and push images
# ============================================================
log "Step 3/8 — Building and pushing Docker images"

log "  Building frontend image..."
docker build --no-cache -t "${DOCKERHUB_USERNAME}/k8s-frontend:latest" ./frontend
check "Frontend build"
docker push "${DOCKERHUB_USERNAME}/k8s-frontend:latest"
check "Frontend push"
success "Frontend image pushed"

log "  Building backend image..."
docker build --no-cache -t "${DOCKERHUB_USERNAME}/k8s-backend:latest" ./backend
check "Backend build"
docker push "${DOCKERHUB_USERNAME}/k8s-backend:latest"
check "Backend push"
success "Backend image pushed"

# ============================================================
# STEP 4 — Update image names in YAML
# ============================================================
log "Step 4/8 — Updating image names in deployment YAMLs"
sed -i "s|YOUR_DOCKERHUB_USERNAME|${DOCKERHUB_USERNAME}|g" k8s/frontend-deployment.yaml
sed -i "s|YOUR_DOCKERHUB_USERNAME|${DOCKERHUB_USERNAME}|g" k8s/backend-deployment.yaml
sed -i "s|image: .*/k8s-frontend:latest|image: ${DOCKERHUB_USERNAME}/k8s-frontend:latest|g" k8s/frontend-deployment.yaml
sed -i "s|image: .*/k8s-backend:latest|image: ${DOCKERHUB_USERNAME}/k8s-backend:latest|g" k8s/backend-deployment.yaml
success "Image names updated"

# ============================================================
# STEP 5 — Install StorageClass if not present
# ============================================================
log "Step 5/8 — Checking StorageClass"
if ! kubectl get storageclass local-path &>/dev/null; then
  log "  local-path StorageClass not found — installing..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  check "local-path provisioner install"

  log "  Waiting for provisioner pod to be ready..."
  kubectl wait --namespace local-path-storage \
    --for=condition=ready pod \
    --selector=app=local-path-provisioner \
    --timeout=60s
  check "local-path provisioner ready"

  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  check "StorageClass default patch"
  success "local-path StorageClass installed and set as default"
else
  success "StorageClass already exists"
fi

# ============================================================
# STEP 6 — Install nginx ingress controller if not present
# ============================================================
log "Step 6/8 — Checking nginx ingress controller"
if ! kubectl get ns ingress-nginx &>/dev/null; then
  log "  ingress-nginx not found — installing..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/baremetal/deploy.yaml
  check "ingress-nginx install"

  log "  Waiting for ingress controller pod to be ready..."
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s
  check "ingress-nginx ready"

  kubectl delete validatingwebhookconfiguration ingress-nginx-admission 2>/dev/null || true
  success "nginx ingress controller installed"
else
  success "ingress-nginx already installed"
fi

# ============================================================
# STEP 7 — Clean up existing deployments
# ============================================================
log "Step 7/8 — Cleaning up existing deployments"

kubectl delete ingress frontend-ingress backend-ingress 2>/dev/null || true
kubectl delete -f k8s/frontend-deployment.yaml          2>/dev/null || true
kubectl delete -f k8s/frontend-service.yaml             2>/dev/null || true
kubectl delete -f k8s/backend-deployment.yaml           2>/dev/null || true
kubectl delete -f k8s/backend-service.yaml              2>/dev/null || true
kubectl delete -f k8s/mysql-deployment.yaml             2>/dev/null || true
kubectl delete -f k8s/mysql-service.yaml                2>/dev/null || true
kubectl delete -f k8s/mysql-pvc.yaml                    2>/dev/null || true
kubectl delete -f k8s/mysql-secret.yaml                 2>/dev/null || true

log "  Waiting for pods to terminate..."
sleep 15
success "Cleanup done"

# ============================================================
# STEP 8 — Deploy everything in order
# ============================================================
log "Step 8/8 — Deploying to Kubernetes"

# 1. secrets
log "  Applying secrets..."
kubectl apply -f k8s/mysql-secret.yaml
check "mysql-secret"

# 2. storage
log "  Applying PVC..."
kubectl apply -f k8s/mysql-pvc.yaml
check "mysql-pvc"

# 3. mysql
log "  Deploying MySQL..."
kubectl apply -f k8s/mysql-deployment.yaml
kubectl apply -f k8s/mysql-service.yaml
check "mysql deploy"

log "  Waiting for MySQL to be ready (this takes ~30s)..."
kubectl wait --for=condition=ready pod \
  --selector=app=mysql \
  --timeout=180s
check "MySQL ready"
success "MySQL is ready"

# 4. restart coredns to fix DNS before backend starts
log "  Restarting CoreDNS to ensure DNS resolution is working..."
kubectl rollout restart deployment/coredns -n kube-system
kubectl wait --namespace kube-system \
  --for=condition=ready pod \
  --selector=k8s-app=kube-dns \
  --timeout=60s
check "CoreDNS restart"
success "CoreDNS ready"

# 5. backend
log "  Deploying backend..."
kubectl apply -f k8s/backend-deployment.yaml
kubectl apply -f k8s/backend-service.yaml
check "backend deploy"

log "  Waiting for backend to be ready..."
kubectl wait --for=condition=ready pod \
  --selector=app=backend \
  --timeout=300s
check "backend ready"
success "Backend is ready"

# 6. frontend
log "  Deploying frontend..."
kubectl apply -f k8s/frontend-deployment.yaml
kubectl apply -f k8s/frontend-service.yaml
check "frontend deploy"

# 7. ingress
log "  Applying ingress rules..."
kubectl apply -f k8s/ingress.yaml
check "ingress"

log "  Waiting for frontend to be ready..."
kubectl wait --for=condition=ready pod \
  --selector=app=frontend \
  --timeout=60s
check "frontend ready"
success "Frontend is ready"

# ============================================================
# DONE — Print summary
# ============================================================
echo ""
echo "============================================================"
echo -e "${GREEN}   Deployment Complete!${NC}"
echo "============================================================"
echo ""

NODEPORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "unknown")

WORKER_IP=$(kubectl get nodes -o wide \
  --no-headers | grep worker | awk '{print $7}' 2>/dev/null || echo "YOUR_WORKER_IP")

echo -e "${CYAN}All pods:${NC}"
kubectl get pods -o wide

echo ""
echo -e "${CYAN}All services:${NC}"
kubectl get svc

echo ""
echo -e "${CYAN}Ingress:${NC}"
kubectl get ingress

echo ""
echo -e "${YELLOW}============================================================"
echo "   Access your app"
echo "============================================================${NC}"
echo ""
echo -e "  Home page  : ${GREEN}http://${WORKER_IP}:${NODEPORT}${NC}"
echo -e "  Login page : ${GREEN}http://${WORKER_IP}:${NODEPORT}/login.html${NC}"
echo -e "  Dashboard  : ${GREEN}http://${WORKER_IP}:${NODEPORT}/dashboard.html${NC}"
echo -e "  Health API : ${GREEN}http://${WORKER_IP}:${NODEPORT}/api/health${NC}"
echo ""
echo -e "${YELLOW}[NOTE]${NC} Make sure Azure NSG on worker node allows TCP port ${NODEPORT} inbound."
echo ""
