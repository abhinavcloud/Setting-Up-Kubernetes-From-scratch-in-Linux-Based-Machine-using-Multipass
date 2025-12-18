#!/usr/bin/env bash
# =============================================================================
# destroy.sh
#
# PURPOSE
# -------
# This script cleanly and safely tears down the Kubernetes environment created
# by setup.sh.
#
# It performs the teardown in the correct dependency order:
#
#   1. Verifies Multipass availability
#   2. Removes Kubernetes resources (best-effort)
#   3. Resets Kubernetes state on worker node
#   4. Resets Kubernetes state on control plane node
#   5. Deletes kubeconfig from host machine
#   6. Stops and deletes Multipass virtual machines
#
# DESIGN GOALS
# ------------
# - Fully non-interactive
# - Safe to re-run multiple times
# - Clear, verbose terminal output
# - Best-effort cleanup (no hard failure on missing resources)
#
# =============================================================================


# -----------------------------------------------------------------------------
# Bash Safety Flags
# -----------------------------------------------------------------------------
# -E : ERR trap inherited by functions
# -e : Exit on any unhandled error
# -u : Treat unset variables as errors
# -o pipefail : Fail pipelines on first failure
# -----------------------------------------------------------------------------
set -Eeuo pipefail


# -----------------------------------------------------------------------------
# Global Variables
# -----------------------------------------------------------------------------
CONTROL_PLANE="k8s-controlplane"
WORKER_NODE="k8s-worker1"

LOG_FILE="$HOME/k8s-destroy.log"


# -----------------------------------------------------------------------------
# Error Handling
# -----------------------------------------------------------------------------
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

error_handler() {
  echo
  echo "❌ ERROR OCCURRED DURING TEARDOWN"
  echo "   Line   : $1"
  echo "   Command: $2"
  echo "   Log    : $LOG_FILE"
  echo
  exit 1
}

# Log everything to terminal + file
exec > >(tee -a "$LOG_FILE") 2>&1


# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

# Prints a clear section header
step() {
  echo
  echo "================================================================"
  echo "🧨 $1"
  echo "================================================================"
}

# Execute a command inside a Multipass VM (non-interactive)
run_vm() {
  local VM="$1"
  shift
  multipass exec "$VM" -- bash -c "$*" || true
}

# Check if a Multipass VM exists
vm_exists() {
  multipass list | awk '{print $1}' | grep -qx "$1"
}


# -----------------------------------------------------------------------------
# STEP 1: Pre-flight Checks
# -----------------------------------------------------------------------------
step "Validating environment before teardown"

if ! command -v multipass &>/dev/null; then
  echo "⚠ Multipass is not installed. Nothing to destroy."
  exit 0
fi

echo "✔ Multipass detected"
multipass list || true


# -----------------------------------------------------------------------------
# STEP 2: Best-effort Kubernetes Cleanup (Control Plane)
# -----------------------------------------------------------------------------
step "Attempting Kubernetes resource cleanup (best-effort)"

if vm_exists "$CONTROL_PLANE"; then
  echo "➡️  Deleting all Kubernetes workloads and namespaces"
  run_vm "$CONTROL_PLANE" "
    kubectl delete all --all --all-namespaces || true
    kubectl delete namespaces --all || true
  "
else
  echo "⚠ Control plane VM not found. Skipping Kubernetes cleanup."
fi


# -----------------------------------------------------------------------------
# STEP 3: Reset Worker Node Kubernetes State
# -----------------------------------------------------------------------------
step "Resetting Kubernetes state on worker node"

if vm_exists "$WORKER_NODE"; then
  echo "➡️  Running kubeadm reset on worker node"
  run_vm "$WORKER_NODE" "
    sudo kubeadm reset -f || true
    sudo systemctl stop kubelet || true
    sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd ~/.kube
  "
else
  echo "⚠ Worker node VM not found. Skipping worker reset."
fi


# -----------------------------------------------------------------------------
# STEP 4: Reset Control Plane Kubernetes State
# -----------------------------------------------------------------------------
step "Resetting Kubernetes state on control plane node"

if vm_exists "$CONTROL_PLANE"; then
  echo "➡️  Running kubeadm reset on control plane"
  run_vm "$CONTROL_PLANE" "
    sudo kubeadm reset -f || true
    sudo systemctl stop kubelet || true
    sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd ~/.kube
  "
else
  echo "⚠ Control plane VM not found. Skipping control plane reset."
fi


# -----------------------------------------------------------------------------
# STEP 5: Remove kubectl Configuration from Host
# -----------------------------------------------------------------------------
step "Removing kubectl configuration from host machine"

if [ -f "$HOME/.kube/config" ]; then
  echo "➡️  Deleting ~/.kube/config"
  rm -f "$HOME/.kube/config"
else
  echo "✔ No kubectl config found on host"
fi


# -----------------------------------------------------------------------------
# STEP 6: Stop Multipass Virtual Machines
# -----------------------------------------------------------------------------
step "Stopping Multipass virtual machines"

for VM in "$WORKER_NODE" "$CONTROL_PLANE"; do
  if vm_exists "$VM"; then
    echo "➡️  Stopping VM: $VM"
    multipass stop "$VM" || true
  else
    echo "✔ VM $VM already stopped or removed"
  fi
done


# -----------------------------------------------------------------------------
# STEP 7: Delete Multipass Virtual Machines
# -----------------------------------------------------------------------------
step "Deleting Multipass virtual machines"

for VM in "$WORKER_NODE" "$CONTROL_PLANE"; do
  if vm_exists "$VM"; then
    echo "➡️  Deleting VM: $VM"
    multipass delete "$VM" || true
  else
    echo "✔ VM $VM already deleted"
  fi
done

# Permanently remove deleted instances
echo "➡️  Purging deleted Multipass instances"
multipass purge || true


# -----------------------------------------------------------------------------
# STEP 8: Final Verification
# -----------------------------------------------------------------------------
step "Final verification"

echo "➡️  Remaining Multipass instances (should be empty):"
multipass list || true

echo
echo "✅ Kubernetes environment destroyed successfully"
echo "📄 Full teardown log available at: $LOG_FILE"
