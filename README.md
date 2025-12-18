# Kubernetes Cluster Setup using Multipass

## Overview

This repository provides a **fully automated Bash script (`setup.sh`)** that provisions a **single-control-plane Kubernetes cluster with one worker node** using **Multipass virtual machines**.

With **one command**, the script:

* Creates virtual machines
* Installs all Kubernetes dependencies
* Bootstraps the cluster using `kubeadm`
* Configures networking
* Exposes the cluster to the host machine via `kubectl`

The entire setup is **non-interactive, reproducible, and logged**, making it suitable for:

* Learning Kubernetes fundamentals
* Local development and experimentation
* Interview demos
* Proof-of-concept environments

---

## What This Project Does

At a high level, this project automates the following:

1. Installs **Multipass** on the host machine
2. Creates two Ubuntu virtual machines:

   * `k8s-controlplane`
   * `k8s-worker1`
3. Prepares both nodes for Kubernetes:

   * Disables swap
   * Configures kernel modules
   * Applies required sysctl parameters
4. Installs and configures **containerd** as the container runtime
5. Installs Kubernetes components:

   * `kubeadm`
   * `kubelet`
   * `kubectl`
6. Initializes the Kubernetes control plane
7. Installs **Flannel** as the CNI plugin
8. Automatically joins the worker node to the cluster
9. Configures `kubectl` access on the **host machine**
10. Enables useful CLI aliases and auto-completion

---

## How It Does This (Architecture & Flow)

### Architecture

```
Host Machine (Linux)
│
├── Multipass
│   ├── k8s-controlplane (Ubuntu 24.04)
│   │   ├── kubeadm
│   │   ├── kubelet
│   │   ├── kubectl
│   │   ├── containerd
│   │   └── Flannel CNI
│   │
│   └── k8s-worker1 (Ubuntu 24.04)
│       ├── kubelet
│       ├── kubeadm
│       └── containerd
│
└── kubectl (configured on host)
```

### Execution Model

* The script **does not open interactive shells**
* All commands run inside VMs using:

  ```bash
  multipass exec <vm> -- bash -c "<commands>"
  ```
* This ensures:

  * Full automation
  * Strong error handling
  * Script reusability
  * Clean logging

---

## System Requirements

### Host Machine

| Requirement     | Details                    |
| --------------- | -------------------------- |
| OS              | Linux (Ubuntu recommended) |
| Architecture    | x86_64                     |
| Privileges      | sudo access                |
| Internet        | Required                   |
| Package Manager | snap                       |

### Minimum Hardware

| Resource | Recommended |
| -------- | ----------- |
| CPU      | 4 cores     |
| Memory   | 6 GB RAM    |
| Disk     | 40 GB free  |

---

## Prerequisites

Before running the script, ensure:

* You can run `sudo` without restrictions
* Snap is installed and working
* No existing Kubernetes cluster is running on the host
* Required ports are not blocked (default kubeadm ports)

> ⚠️ The script installs Multipass automatically if it is not present.

---

## Assumptions

This script assumes:

* The user is running it on a **fresh or clean system**
* No existing Multipass VMs with the same names exist
* Kubernetes version `v1.30` is acceptable
* Flannel is sufficient as the CNI
* Single control plane is enough (no HA setup)

This is **not** designed for:

* Production clusters
* Multi-control-plane HA
* Air-gapped environments

---

## User Journey (Step-by-Step)

### 1. User Logs into Terminal

```bash
ssh user@linux-machine
```

### 2. Clone the Repository

```bash
git clone <repository-url>
cd <repository-directory>
```

### 3. Make Script Executable

```bash
chmod +x setup.sh
```

### 4. Run the Setup Script

```bash
./setup.sh
```

### 5. Observe Progress

The script prints clearly labeled steps such as:

```
➡️ Installing Multipass
➡️ Creating virtual machines
➡️ Preparing nodes
➡️ Initializing Kubernetes control plane
➡️ Joining worker node
```

All output is logged to:

```
~/k8s-setup.log
```

### 6. Verify the Cluster

Once the script completes:

```bash
kubectl get nodes
```

Expected output:

```
NAME                STATUS   ROLES           AGE   VERSION
k8s-controlplane    Ready    control-plane   X     v1.30.x
k8s-worker1         Ready    <none>           X     v1.30.x
```

---

## What This Achieves

By the end of execution, you will have:

* A fully functional Kubernetes cluster
* One control plane + one worker node
* Networking configured and working
* `kubectl` access from your local machine
* CLI aliases and auto-completion enabled
* A clean, reproducible environment

---

## Advantages of This Approach

### 🚀 Automation

* One command to provision an entire cluster
* No manual SSH or copy-paste

### 🔁 Reproducibility

* Same setup every time
* Suitable for demos and learning

### 🧪 Safe Experimentation

* Runs inside isolated VMs
* No host pollution

### 📘 Educational Value

* Verbose comments explain *why* each step exists
* Mirrors real-world kubeadm flows

### 🛠 Debuggable

* Centralized logging
* Fails fast with meaningful errors

---

## Limitations

* Not production-ready
* No persistent storage configuration
* No ingress controller
* No monitoring or observability stack
* Single control plane only

---

## Future Enhancements (Optional)

* Multi-worker support
* HA control plane
* Calico CNI option
* Ingress (NGINX)
* Metrics Server
* Helm bootstrap
* Cleanup / teardown script

---

## Conclusion

This project provides a **clean, automated, and educational way** to understand how Kubernetes clusters are built using `kubeadm`, without the complexity of cloud providers or managed services.



