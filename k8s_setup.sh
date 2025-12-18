#!/usr/bin/env bash
# =============================================================================
# setup.sh
#
# PURPOSE
# -------
# This script creates a complete Kubernetes cluster using Multipass.
#
# It performs the following end-to-end actions:
#   1. Installs Multipass (if not already installed)
#   2. Creates two Ubuntu VMs using Multipass
#        - 1 Control Plane node
#        - 1 Worker node
#   3. Prepares both nodes for Kubernetes
#        - Disables swap
#        - Loads kernel modules
#        - Applies sysctl networking settings
#   4. Installs containerd as the container runtime
#   5. Installs Kubernetes components (kubeadm, kubelet, kubectl)
#   6. Initializes the Kubernetes control plane
#   7. Installs Flannel CNI
#   8. Joins the worker node to the cluster
#   9. Configures kubectl access on the host machine
#
# DESIGN PRINCIPLES
# -----------------
# - Fully automated (no interactive shell into VMs)
# - Clear step-by-step terminal output
# - Strong error handling with line numbers
# - Logs everything to a file for troubleshooting
#
# REQUIREMENTS
# ------------
# - Linux host with snap support
# - sudo privileges
# - Internet access
#
# =============================================================================


# -----------------------------------------------------------------------------
# Bash Safety Flags
# -----------------------------------------------------------------------------
# -E : Ensures ERR trap is inherited by functions
# -e : Exit immediately if any command fails
# -u : Treat unset variables as errors
# -o pipefail : Fail pipelines if any command fails
# -----------------------------------------------------------------------------
set -Eeuo pipefail


# -----------------------------------------------------------------------------
# Global Variables
# -----------------------------------------------------------------------------
CONTROL_PLANE="k8s-controlplane"
WORKER_NODE="k8s-worker1"

# Pod network CIDR required by Flannel
POD_CIDR="10.244.0.0/16"

# Kubernetes version stream
K8S_VERSION="v1.30"

# Log file for full execution trace
LOG_FILE="$HOME/k8s-setup.log"


# -----------------------------------------------------------------------------
# Error Handling
# -----------------------------------------------------------------------------
# If any command fails, this function prints:
#   - Line number
#   - Failed command
#   - Log file location
# -----------------------------------------------------------------------------
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

error_handler() {
  echo
  echo "❌ ERROR OCCURRED"
  echo "   Line   : $1"
  echo "   Command: $2"
  echo "   Log    : $LOG_FILE"
  echo
  exit 1
}

# Redirect all output (stdout + stderr) to log file AND terminal
exec > >(tee -a "$LOG_FILE") 2>&1


# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

# Prints a clear section header in the terminal
step() {
  echo
  echo "================================================================"
  echo "➡️  $1"
  echo "================================================================"
}

# Executes commands inside a Multipass VM non-interactively
# This is equivalent to:
#   multipass shell <vm>
#   <commands>
#   exit
run_vm() {
  local VM="$1"
  shift
  multipass exec "$VM" -- bash -c "$*"
}


# -----------------------------------------------------------------------------
# STEP 1: Install Multipass on Host Machine
# -----------------------------------------------------------------------------
step "Installing Multipass on host machine"

# Check if multipass command already exists
if ! command -v multipass &>/dev/null; then
  echo "Multipass not found. Installing via snap..."
  sudo snap install multipass
else
  echo "✔ Multipass already installed"
fi


# -----------------------------------------------------------------------------
# STEP 2: Create Multipass Virtual Machines
# -----------------------------------------------------------------------------
step "Creating Multipass virtual machines"

# Create control plane VM only if it doesn't already exist
multipass list | grep -q "$CONTROL_PLANE" || \
  multipass launch \
    --name "$CONTROL_PLANE" \
    --cpus 2 \
    --memory 2.5G \
    --disk 20G

# Create worker VM only if it doesn't already exist
multipass list | grep -q "$WORKER_NODE" || \
  multipass launch \
    --name "$WORKER_NODE" \
    --cpus 2 \
    --memory 1.5G \
    --disk 10G

# Display current VM status
multipass list

# Capture control plane IP (needed later for kubeadm join)
CONTROL_IP=$(multipass info "$CONTROL_PLANE" | awk '/IPv4/ {print $2}')
echo "✔ Control Plane IP detected: $CONTROL_IP"


# -----------------------------------------------------------------------------
# STEP 3: Prepare Nodes for Kubernetes (BOTH NODES)
# -----------------------------------------------------------------------------
# Kubernetes requires:
#   - Swap disabled
#   - Certain kernel modules loaded
#   - Proper sysctl networking settings
# -----------------------------------------------------------------------------
NODE_PREP=$(cat <<'EOF'
set -e

# Update OS packages
sudo apt update && sudo apt upgrade -y

# Disable swap (required by kubelet)
sudo swapoff -a
sudo sed -i '/swap / s/^/#/' /etc/fstab

# Load required kernel modules
cat <<MOD | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
MOD

sudo modprobe overlay
sudo modprobe br_netfilter

# Apply Kubernetes networking sysctl parameters
cat <<SYS | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYS

sudo sysctl --system
EOF
)

step "Preparing control plane and worker nodes for Kubernetes"
run_vm "$CONTROL_PLANE" "$NODE_PREP"
run_vm "$WORKER_NODE"  "$NODE_PREP"


# -----------------------------------------------------------------------------
# STEP 4: Install containerd (Container Runtime)
# -----------------------------------------------------------------------------
# containerd is the CRI-compliant runtime used by kubelet
# SystemdCgroup must be enabled for kubeadm compatibility
# -----------------------------------------------------------------------------
CONTAINERD_INSTALL=$(cat <<'EOF'
set -e

sudo apt install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

# Enable systemd cgroup driver
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
  /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
EOF
)

step "Installing containerd on both nodes"
run_vm "$CONTROL_PLANE" "$CONTAINERD_INSTALL"
run_vm "$WORKER_NODE"  "$CONTAINERD_INSTALL"


# -----------------------------------------------------------------------------
# STEP 5: Install Kubernetes Components
# -----------------------------------------------------------------------------
# Installs:
#   - kubelet  : node agent
#   - kubeadm  : cluster bootstrap tool
#   - kubectl  : CLI tool
# -----------------------------------------------------------------------------
K8S_INSTALL=$(cat <<EOF
set -e

sudo apt install -y apt-transport-https ca-certificates curl
sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key |
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" |
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl

# Prevent accidental upgrades
sudo apt-mark hold kubelet kubeadm kubectl
EOF
)

step "Installing Kubernetes components on both nodes"
run_vm "$CONTROL_PLANE" "$K8S_INSTALL"
run_vm "$WORKER_NODE"  "$K8S_INSTALL"


# -----------------------------------------------------------------------------
# STEP 6: Initialize Kubernetes Control Plane
# -----------------------------------------------------------------------------
step "Initializing Kubernetes control plane"

run_vm "$CONTROL_PLANE" "
sudo kubeadm init --pod-network-cidr=$POD_CIDR

mkdir -p \$HOME/.kube
sudo cp /etc/kubernetes/admin.conf \$HOME/.kube/config
sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config
"


# -----------------------------------------------------------------------------
# STEP 7: Install Flannel CNI
# -----------------------------------------------------------------------------
step "Installing Flannel CNI plugin"

run_vm "$CONTROL_PLANE" "
kubectl apply -f \
https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
"


# -----------------------------------------------------------------------------
# STEP 8: Join Worker Node to Cluster
# -----------------------------------------------------------------------------
step "Joining worker node to Kubernetes cluster"

JOIN_CMD=$(run_vm "$CONTROL_PLANE" "kubeadm token create --print-join-command")
run_vm "$WORKER_NODE" "sudo $JOIN_CMD"


# -----------------------------------------------------------------------------
# STEP 9: Allow Scheduling on Control Plane (Optional)
# -----------------------------------------------------------------------------
step "Removing control-plane taint"

run_vm "$CONTROL_PLANE" "
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
"


# -----------------------------------------------------------------------------
# STEP 10: Configure kubectl on Host Machine
# -----------------------------------------------------------------------------
step "Configuring kubectl access on host machine"

if ! command -v kubectl &>/dev/null; then
  sudo snap install kubectl --classic
fi

mkdir -p ~/.kube
multipass exec "$CONTROL_PLANE" -- sudo cat /etc/kubernetes/admin.conf > ~/.kube/config
chmod 600 ~/.kube/config


# -----------------------------------------------------------------------------
# STEP 11: Add kubectl Aliases and Autocomplete
# -----------------------------------------------------------------------------
step "Enabling kubectl autocomplete and aliases"

grep -q "kubectl completion bash" ~/.bashrc || cat <<'EOF' >> ~/.bashrc

# Kubernetes CLI enhancements
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k

alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kgn='kubectl get nodes'
EOF

source ~/.bashrc


# -----------------------------------------------------------------------------
# STEP 12: Final Verification
# -----------------------------------------------------------------------------
step "Verifying Kubernetes cluster status"
kubectl get nodes -o wide

echo
echo "🎉 Kubernetes cluster setup completed successfully!"
echo "📄 Full log available at: $LOG_FILE"
