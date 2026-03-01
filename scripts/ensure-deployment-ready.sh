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
#   3. Fix workspace SCC - adds system:serviceaccounts to anyuid (prevents "Forbidden: not usable by user or serviceaccount")
#   4. DevWorkspaceOperatorConfig - runAsNonRoot:false for workspace containers
#   5. Patch workspace Deployments - che-gateway runAsNonRoot:false (Traefik image runs as root)
#   6. Waits for devworkspace-webhook to have endpoints (required for workspace create)
#
# Usage: ./ensure-deployment-ready.sh --kubeconfig <path> [--namespace <ns>] [--no-wait] [--gateway-patch-only]
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE=""
NAMESPACE="eclipse-che"
NO_WAIT=false
GATEWAY_PATCH_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --no-wait) NO_WAIT=true; shift ;;
        --gateway-patch-only) GATEWAY_PATCH_ONLY=true; shift ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [ -z "$KUBECONFIG_FILE" ] || [ ! -f "$KUBECONFIG_FILE" ]; then
    echo "Usage: $0 --kubeconfig <path> [--namespace eclipse-che] [--no-wait] [--gateway-patch-only]"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG_FILE"

# Helper: patch workspace Deployments to allow che-gateway (root image) to run.
# Invoked by --gateway-patch-only and as part of full run.
patch_workspace_gateway_deployments() {
    local NS
    for NS in $(oc get devworkspace -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u); do
        patch_deployments_in_namespace "$NS"
    done
    for NS in $(oc get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '\-che\-' || true); do
        patch_deployments_in_namespace "$NS"
    done
}

patch_deployments_in_namespace() {
    local NS="$1"
    local DEPLOY CNAME IDX CUR
    for DEPLOY in $(oc get deploy -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
        CONTAINERS=$(oc get deploy "$DEPLOY" -n "$NS" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null)
        IDX=0
        for CNAME in $CONTAINERS; do
            if [ "$CNAME" = "che-gateway" ]; then
                CUR=$(oc get deploy "$DEPLOY" -n "$NS" -o jsonpath="{.spec.template.spec.containers[$IDX].securityContext.runAsNonRoot}" 2>/dev/null || echo "")
                if [ "$CUR" = "true" ]; then
                    if oc patch deploy "$DEPLOY" -n "$NS" --type=json -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/$IDX/securityContext/runAsNonRoot\",\"value\":false}]" 2>/dev/null; then
                        echo "  Patched $NS/$DEPLOY (che-gateway runAsNonRoot=false)"
                    fi
                fi
                break
            fi
            IDX=$((IDX + 1))
        done
    done
}

if [ "$GATEWAY_PATCH_ONLY" = true ]; then
    echo "=== Patching workspace Deployments (che-gateway runAsNonRoot) ==="
    patch_workspace_gateway_deployments
    echo "Done."
    exit 0
fi

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

# 3. Fix workspace SCC (allows workspace pods to run with SETGID/SETUID/allowPrivilegeEscalation)
# Ostest/metal clusters: workspace devfiles need anyuid SCC with SETGID/SETUID in allowedCapabilities.
# Without groups: workspace SA "Forbidden: not usable by user or serviceaccount"
# Without allowedCapabilities: "Invalid value: SETGID/SETUID: capability may not be added"
echo "Ensuring workspace pods can use anyuid SCC..."
if oc get scc anyuid &>/dev/null; then
    NEED_PATCH=false
    if ! oc get scc anyuid -o jsonpath='{.groups}' 2>/dev/null | grep -q 'system:serviceaccounts'; then
        oc patch scc anyuid --type=json -p='[{"op":"add","path":"/groups/-","value":"system:serviceaccounts"}]' 2>/dev/null && \
            echo "  Added system:serviceaccounts to anyuid groups" || \
            echo "  WARN: Could not add system:serviceaccounts to anyuid (may need cluster-admin)"
    fi
    if ! oc get scc anyuid -o jsonpath='{.allowedCapabilities}' 2>/dev/null | grep -q 'SETGID'; then
        oc patch scc anyuid --type=merge -p '{"allowedCapabilities":["SETGID","SETUID"]}' 2>/dev/null && \
            echo "  Added SETGID,SETUID to anyuid allowedCapabilities - workspaces will start" || \
            echo "  WARN: Could not add allowedCapabilities to anyuid"
    else
        echo "  anyuid SCC already configured for workspaces - OK"
    fi
else
    echo "  anyuid SCC not found (non-OpenShift?), skipping"
fi

# 3b. DevWorkspaceOperatorConfig - runAsNonRoot:false for workspace containers.
# Che routing controller still hardcodes runAsNonRoot:true for che-gateway, so we also patch Deployments (step 4b).
if oc get devworkspaceoperatorconfig devworkspace-config -n "$NAMESPACE" &>/dev/null; then
    CUR=$(oc get devworkspaceoperatorconfig devworkspace-config -n "$NAMESPACE" -o jsonpath='{.config.workspace.containerSecurityContext.runAsNonRoot}' 2>/dev/null || echo "")
    if [ "$CUR" != "false" ]; then
        if oc patch devworkspaceoperatorconfig devworkspace-config -n "$NAMESPACE" --type=merge -p '{"config":{"workspace":{"containerSecurityContext":{"runAsNonRoot":false}}}}' 2>/dev/null; then
            echo "  DevWorkspaceOperatorConfig: set containerSecurityContext.runAsNonRoot=false"
        else
            echo "  WARN: Could not patch devworkspace-config (Che operator may own it)"
        fi
    fi
fi

# 4. Fix workspace namespace Pod Security (allows che-gateway sidecar to run as root)
# Workspace pods include che-gateway (Traefik) which runs as root. Restricted PSA adds runAsNonRoot,
# causing "container has runAsNonRoot and image will run as root". Use privileged for workspace namespaces.
echo "Ensuring workspace namespaces allow root containers (che-gateway)..."
for NS in $(oc get devworkspace -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u); do
    CUR=$(oc get namespace "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || echo "")
    if [ "$CUR" != "privileged" ]; then
        if oc label namespace "$NS" pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite 2>/dev/null; then
            echo "  Set $NS to pod-security=privileged (che-gateway can run as root)"
        else
            echo "  WARN: Could not label $NS (may need cluster-admin)"
        fi
    fi
done
# Also fix namespaces matching <username>-che-* (created before first DevWorkspace exists)
for NS in $(oc get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '\-che\-' || true); do
    CUR=$(oc get namespace "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || echo "")
    if [ "$CUR" != "privileged" ]; then
        oc label namespace "$NS" pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite 2>/dev/null && \
            echo "  Set $NS to pod-security=privileged" || true
    fi
done

# 4b. Patch workspace Deployments: che-gateway sidecar has runAsNonRoot:true from Che routing controller
# but the Traefik image runs as root. DevWorkspaceOperatorConfig runAsNonRoot:false doesn't apply to gateway.
# Directly patch Deployments that have a che-gateway container.
echo "Patching workspace Deployments (che-gateway runAsNonRoot)..."
patch_workspace_gateway_deployments

# 5. Wait for devworkspace-webhook to have endpoints (workspace creation will fail otherwise)
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
