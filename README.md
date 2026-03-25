# Kubernetes Full Stack App on Azure VMs

A fully containerised web application running on a bare-metal Kubernetes cluster
hosted on Azure VMs. Built with nginx (frontend), Node.js Express (backend),
and MySQL (database) — all orchestrated with Kubernetes and exposed via nginx ingress.

---

## Stack

| Layer        | Technology                          |
|-------------|-------------------------------------|
| Frontend     | nginx serving static HTML/CSS/JS    |
| Backend      | Node.js + Express REST API          |
| Database     | MySQL 8.0                           |
| Container    | Docker + Docker Hub                 |
| Orchestration| Kubernetes (kubeadm)                |
| Ingress      | nginx-ingress-controller (NodePort) |
| Cloud        | Microsoft Azure (Ubuntu 24.04 VMs)  |

---

## Architecture
```
Internet
    │
    ▼
Azure Worker VM Public IP :30303 (NodePort)
    │
    ▼
nginx-ingress-controller
    │
    ├── /api/*  ──▶  backend-service:3000  ──▶  2x Node.js pods
    │                                               │
    │                                          mysql-service
    │                                               │
    │                                          MySQL pod + PVC
    │
    └── /*  ──▶  frontend-service:80  ──▶  2x nginx pods
                     ├── index.html      (home page)
                     ├── login.html      (register + login)
                     └── dashboard.html  (protected user dashboard)
```

---

## Project Structure
```
k8s-nginx-project/
├── frontend/
│   ├── Dockerfile
│   └── html/
│       ├── index.html
│       ├── login.html
│       └── dashboard.html
├── backend/
│   ├── Dockerfile
│   ├── package.json
│   └── src/
│       ├── index.js
│       ├── db.js
│       └── routes/
│           └── auth.js
└── k8s/
    ├── mysql-secret.yaml
    ├── mysql-pvc.yaml
    ├── mysql-deployment.yaml
    ├── mysql-service.yaml
    ├── backend-deployment.yaml
    ├── backend-service.yaml
    ├── frontend-deployment.yaml
    ├── frontend-service.yaml
    └── ingress.yaml
```

---

## Prerequisites

- 2x Azure VMs (Ubuntu 24.04 LTS) — one master, one worker
- Docker Hub account
- Git repository

---

## Part 1 — Cluster Setup

### Master Node Setup
```bash
chmod +x master-setup.sh
sudo ./master-setup.sh
```

The script handles:
- System update and swap disable
- Kernel modules (overlay, br_netfilter)
- Sysctl network params
- containerd install and configuration (SystemdCgroup = true)
- kubeadm, kubelet, kubectl install (v1.29)
- kubeadm init with pod-network-cidr=192.168.0.0/16
- Calico CNI install
- kubeconfig setup

At the end of the script, copy the join command printed:
```bash
kubeadm join <MASTER_IP>:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>
```

### Worker Node Setup
```bash
chmod +x worker-setup.sh
sudo ./worker-setup.sh
```

Then run the join command from above on the worker node:
```bash
sudo kubeadm join <MASTER_IP>:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>
```

Verify the cluster from master:
```bash
kubectl get nodes -o wide
# both nodes should show Ready
```

---

## Part 2 — Build and Push Docker Images

### Install Docker on master node
```bash
sudo apt install -y docker.io
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker
```

### Clone repo and build images
```bash
git clone https://github.com/YOUR_USERNAME/k8s-nginx-project.git
cd k8s-nginx-project

docker login
```

Build and push frontend:
```bash
docker build --no-cache -t YOUR_DOCKERHUB_USERNAME/k8s-frontend:latest ./frontend
docker push YOUR_DOCKERHUB_USERNAME/k8s-frontend:latest
```

Build and push backend:
```bash
docker build --no-cache -t YOUR_DOCKERHUB_USERNAME/k8s-backend:latest ./backend
docker push YOUR_DOCKERHUB_USERNAME/k8s-backend:latest
```

Update image names in deployment YAMLs:
```bash
sed -i 's/YOUR_DOCKERHUB_USERNAME/youractualusername/g' k8s/frontend-deployment.yaml
sed -i 's/YOUR_DOCKERHUB_USERNAME/youractualusername/g' k8s/backend-deployment.yaml
```

---

## Part 3 — Generate Secrets
```bash
echo -n 'yourRootPassword' | base64
echo -n 'yourAppPassword'  | base64
echo -n 'yourJWTSecret'    | base64
```

Paste the output into `k8s/mysql-secret.yaml`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mysql-secret
type: Opaque
data:
  root-password: <base64>
  app-password:  <base64>
  jwt-secret:    <base64>
```

---

## Part 4 — Install nginx Ingress Controller
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/baremetal/deploy.yaml

# wait for controller pod to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# delete admission webhook (causes timeout issues on bare-metal)
kubectl delete validatingwebhookconfiguration ingress-nginx-admission

# check which NodePort was assigned
kubectl get svc -n ingress-nginx
# note the port mapped to 80 — e.g. 80:30303/TCP
```

---

## Part 5 — Install StorageClass for MySQL PVC
```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

# set as default
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# verify
kubectl get storageclass
```

---

## Part 6 — Deploy Everything

Apply in this exact order:
```bash
# 1. secrets
kubectl apply -f k8s/mysql-secret.yaml

# 2. storage
kubectl apply -f k8s/mysql-pvc.yaml

# 3. mysql
kubectl apply -f k8s/mysql-deployment.yaml
kubectl apply -f k8s/mysql-service.yaml

# 4. wait for mysql to be ready
kubectl wait --for=condition=ready pod \
  --selector=app=mysql \
  --timeout=120s

# 5. backend
kubectl apply -f k8s/backend-deployment.yaml
kubectl apply -f k8s/backend-service.yaml

# 6. frontend
kubectl apply -f k8s/frontend-deployment.yaml
kubectl apply -f k8s/frontend-service.yaml

# 7. ingress
kubectl apply -f k8s/ingress.yaml
```

Verify everything is running:
```bash
kubectl get pods -o wide
kubectl get svc
kubectl get ingress
```

---

## Part 7 — Azure NSG Rules

Add inbound rule on the **worker node NSG**:

| Setting  | Value                          |
|----------|-------------------------------|
| Source   | Any                            |
| Protocol | TCP                            |
| Port     | 30303 (your ingress NodePort)  |
| Action   | Allow                          |
| Priority | 1020                           |
| Name     | Allow-Ingress-HTTP             |

> Always confirm the NodePort with `kubectl get svc -n ingress-nginx`
> as it may differ from 30303.

---

## Part 8 — Test the App
```bash
# health check
curl http://WORKER_PUBLIC_IP:30303/api/health

# register
curl -X POST http://WORKER_PUBLIC_IP:30303/api/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","email":"test@example.com","password":"password123"}'

# login
curl -X POST http://WORKER_PUBLIC_IP:30303/api/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}'

# protected route (use token from login response)
curl http://WORKER_PUBLIC_IP:30303/api/me \
  -H "Authorization: Bearer YOUR_TOKEN"
```

Open in browser:
```
http://WORKER_PUBLIC_IP:30303               # home page
http://WORKER_PUBLIC_IP:30303/login.html    # login + register
http://WORKER_PUBLIC_IP:30303/dashboard.html # dashboard (requires login)
```

---

## Part 9 — Update Workflow

After making changes to code:
```bash
cd k8s-nginx-project
git pull

# if frontend changed
docker build --no-cache -t YOUR_DOCKERHUB_USERNAME/k8s-frontend:latest ./frontend
docker push YOUR_DOCKERHUB_USERNAME/k8s-frontend:latest
kubectl rollout restart deployment/frontend-deployment
kubectl rollout status deployment/frontend-deployment

# if backend changed
docker build --no-cache -t YOUR_DOCKERHUB_USERNAME/k8s-backend:latest ./backend
docker push YOUR_DOCKERHUB_USERNAME/k8s-backend:latest
kubectl rollout restart deployment/backend-deployment
kubectl rollout status deployment/backend-deployment
```

---

## Useful kubectl Commands
```bash
# pod status
kubectl get pods -o wide
kubectl get pods -w                              # watch live

# logs
kubectl logs -f deployment/backend-deployment
kubectl logs -f deployment/frontend-deployment
kubectl logs -f deployment/mysql-deployment

# debug
kubectl describe pod <pod-name>
kubectl exec -it <pod-name> -- sh

# services and ingress
kubectl get svc
kubectl get ingress
kubectl describe ingress app-ingress

# mysql shell
kubectl exec -it <mysql-pod-name> -- mysql -u appuser -p k8sapp
# then inside mysql:
# SHOW TABLES;
# SELECT * FROM users;

# scale
kubectl scale deployment backend-deployment --replicas=3

# restart a deployment
kubectl rollout restart deployment/backend-deployment
```

---

## API Endpoints

| Method | Endpoint        | Auth     | Description                    |
|--------|----------------|----------|-------------------------------|
| GET    | /api/health    | No       | Health check                   |
| POST   | /api/register  | No       | Register new user              |
| POST   | /api/login     | No       | Login, returns JWT token       |
| GET    | /api/me        | JWT      | Get logged in user profile     |

---

## Issues We Hit and How We Fixed Them

### 1. Ingress YAML parse error — tab characters
**Error:** `error converting YAML to JSON: yaml: line 30: found character that cannot start any token`

**Cause:** YAML does not allow tab characters for indentation. Tabs crept in during copy-paste.

**Fix:** Rewrote the ingress YAML using spaces only. Check for tabs with:
```bash
cat -A k8s/ingress.yaml | grep -n $'\t'
```

---

### 2. Ingress admission webhook timeout
**Error:** `failed calling webhook "validate.nginx.ingress.kubernetes.io": context deadline exceeded`

**Cause:** On bare-metal Azure VMs the ingress admission webhook pod is not reachable from the control plane due to network constraints.

**Fix:** Delete the webhook — safe for dev/learning clusters:
```bash
kubectl delete validatingwebhookconfiguration ingress-nginx-admission
```

---

### 3. MySQL pod stuck in Pending
**Error:** `0/2 nodes are available: pod has unbound immediate PersistentVolumeClaims`

**Cause:** No default StorageClass exists on bare-metal Kubernetes — unlike managed cloud Kubernetes (AKS, EKS), bare-metal clusters have no built-in dynamic provisioner.

**Fix:** Install Rancher local-path provisioner and set it as default:
```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Also add `storageClassName: local-path` to the PVC manifest:
```yaml
spec:
  storageClassName: local-path
```

---

### 4. Backend CrashLoopBackOff — DNS failure
**Error:** `getaddrinfo EAI_AGAIN mysql-service`

**Cause:** The mysql-service was configured as a headless service (`clusterIP: None`) which caused DNS resolution failures in the cluster. Pods were using the host's systemd-resolved (`127.0.0.53`) instead of kube-dns (`10.96.0.10`).

**Fix:** Remove `clusterIP: None` from mysql-service to give it a stable ClusterIP and proper DNS entry:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql-service
spec:
  selector:
    app: mysql
  ports:
    - protocol: TCP
      port: 3306
      targetPort: 3306
  # clusterIP: None  <-- removed this line
```

---

### 5. Wrong NodePort in NSG rule
**Error:** `curl: (7) Failed to connect to port 32080`

**Cause:** The ingress controller was assigned port `30303` by Kubernetes, not `32080` as assumed. The Azure NSG rule was created for the wrong port.

**Fix:** Always check the actual assigned NodePort before creating NSG rules:
```bash
kubectl get svc -n ingress-nginx
```
Then create the NSG rule for the port shown, not an assumed value.

---

### 6. Ingress rewrite breaking frontend routes
**Error:** `/login.html` and `/dashboard.html` returning 404

**Cause:** A single ingress with `rewrite-target: /$2` was applied to all paths including frontend ones. When a request came in for `/login.html` the rewrite turned it into `/api/login.html` which didn't exist on the backend.

**Fix:** Split into two separate ingress objects — one for backend with rewrite, one for frontend with no rewrite:
```yaml
# backend — rewrites /api/xxx correctly
nginx.ingress.kubernetes.io/rewrite-target: /api/$2

# frontend — no rewrite annotation, passes path as-is
# no annotations needed
```

---

### 7. Docker build cache — new files not included in image
**Error:** `/login.html` and `/dashboard.html` returning 404 even after rebuild

**Cause:** Docker's layer cache detected no changes in the `COPY` layer because the file timestamps or checksums weren't picked up correctly after the files were created.

**Fix:** Always use `--no-cache` when you add new files:
```bash
docker build --no-cache -t YOUR_DOCKERHUB_USERNAME/k8s-frontend:latest ./frontend
```

---

### 8. containerd SystemdCgroup not set on worker
**Cause:** Original worker setup script was missing the `SystemdCgroup = true` fix in containerd config. Without it, containerd uses `cgroupfs` but kubelet expects `systemd`, causing pods to crashloop.

**Fix:** Added to worker setup script:
```bash
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```
