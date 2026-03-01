#!/bin/bash
#
# Copyright (c) 2025-2026 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Fixes 403 Forbidden on POST /api/kubernetes/namespace/provision by granting
# the user permission to create namespaces (self-provisioner cluster role).
#
# Usage: ./fix-namespace-provision-403.sh --kubeconfig <path> [--username <user>]
#
set -e

KUBECONFIG_FILE=""
USERNAME="kubeadmin"

while [[ $# -gt 0 ]]; do
    case $1 in
        --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
        --username) USERNAME="$2"; shift 2 ;;
        *)
            echo "Usage: $0 --kubeconfig <path> [--username kubeadmin]"
            exit 1
            ;;
    esac
done

if [ -z "$KUBECONFIG_FILE" ] || [ ! -f "$KUBECONFIG_FILE" ]; then
    echo "Usage: $0 --kubeconfig <path> [--username kubeadmin]"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG_FILE"

echo "Granting self-provisioner (namespace creation) to user: $USERNAME"
oc adm policy add-cluster-role-to-user self-provisioner "$USERNAME" 2>/dev/null || {
    echo "Note: User may already have the role. If 403 persists, try:"
    echo "  1. Log out of the dashboard and log back in"
    echo "  2. Clear cookies for the Che host"
    echo "  3. Ensure you complete the full OAuth flow (don't use port-forward)"
    exit 1
}

echo "Done. User $USERNAME can now provision namespaces. Log out and log back in to the dashboard, or clear cookies and retry."
