#!/bin/bash
#
# Copyright (c) 2025-2026 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Post-deploy verification and fix script. Ensures Eclipse Che deployment is
# fully ready for use (login works, workspace creation works).
#
# Runs:
#   1. fix-image-pulls - patches DWO webhook for workspace creation
#   2. fix-oauth-redirect - fixes login invalid_request error
#   3. Waits for devworkspace-webhook to have endpoints (required for workspace create)
#
# Usage: ./ensure-deployment-ready.sh --kubeconfig <path> [--namespace <ns>] [--no-wait]
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE=""
NAMESPACE="eclipse-che"
NO_WAIT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --no-wait) NO_WAIT=true; shift ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [ -z "$KUBECONFIG_FILE" ] || [ ! -f "$KUBECONFIG_FILE" ]; then
    echo "Usage: $0 --kubeconfig <path> [--namespace eclipse-che] [--no-wait]"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG_FILE"

echo "=== Ensuring Eclipse Che deployment is ready ==="

# 1. Fix image pulls (webhook, controller, CheCluster)
FIX_IMAGE_SCRIPT="${SCRIPT_DIR}/fix-image-pulls.sh"
if [ -x "$FIX_IMAGE_SCRIPT" ]; then
    echo "Running fix-image-pulls..."
    "$FIX_IMAGE_SCRIPT" --kubeconfig "$KUBECONFIG_FILE" --namespace "$NAMESPACE" || true
else
    echo "fix-image-pulls.sh not found, skipping"
fi

# 2. Fix OAuth redirect URI
OAUTH_FIX_SCRIPT="${SCRIPT_DIR}/fix-oauth-redirect.sh"
if [ -x "$OAUTH_FIX_SCRIPT" ]; then
    echo "Running fix-oauth-redirect..."
    "$OAUTH_FIX_SCRIPT" --kubeconfig "$KUBECONFIG_FILE" --namespace "$NAMESPACE" || true
else
    echo "fix-oauth-redirect.sh not found, skipping"
fi

# 3. Wait for devworkspace-webhook to have endpoints (workspace creation will fail otherwise)
if [ "$NO_WAIT" = false ]; then
    echo "Waiting for devworkspace-webhook to have endpoints..."
    for i in $(seq 1 24); do
        if oc get endpoints devworkspace-webhookserver -n devworkspace-controller -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
            echo "  devworkspace-webhook has endpoints - workspace creation will work"
            echo "Done."
            exit 0
        fi
        [ $i -lt 24 ] && sleep 5
    done
    echo "  WARN: devworkspace-webhook has no endpoints after 2 min. Workspace creation may fail."
    echo "  Run: ./scripts/fix-image-pulls.sh --kubeconfig $KUBECONFIG_FILE"
fi

echo "Done."
