#!/bin/bash
#
# Copyright (c) 2025-2026 Red Hat, Inc.
# SPDX-License-Identifier: EPL-2.0
#
# Creates a hostPath PV for workspace PVCs when cluster has no StorageClass.
# Use when claim-devworkspace is Pending and ephemeral strategy isn't suitable.
#
# Usage: ./create-workspace-pv.sh [--kubeconfig <path>] [--namespace <ns>] [--size 10Gi]
#
set -e

KUBECONFIG_FILE=""
NAMESPACE=""
SIZE="10Gi"

while [[ $# -gt 0 ]]; do
  case $1 in
    --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

if [ -n "$KUBECONFIG_FILE" ]; then
  export KUBECONFIG="$KUBECONFIG_FILE"
fi

# Get first worker node
NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$NODE" ] && { echo "No node found"; exit 1; }

PV_NAME="workspace-pv-$(date +%s)"
echo "Creating hostPath PV $PV_NAME (${SIZE}, RWO) on node $NODE"

oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
spec:
  capacity:
    storage: ${SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /mnt/che-workspace-${PV_NAME}
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${NODE}
EOF

echo "PV created. Existing Pending PVCs may bind; for new workspaces, prefer ephemeral."
echo "  oc patch checluster eclipse-che -n eclipse-che --type=merge -p '{\"spec\":{\"devEnvironments\":{\"storage\":{\"pvcStrategy\":\"ephemeral\"}}}}'"
