#!/bin/bash
#
# Copyright (c) 2025-2026 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Fix ImagePullBackOff on IPv6-only clusters when mirror ICSP hasn't been applied.
# Patches deployments and CheCluster to use local registry directly.
#
# Critical: devworkspace-webhook-server must have running pods. Without it, workspace
# creation fails with "no endpoints available for service devworkspace-webhookserver".
#
# Usage: ./fix-image-pulls.sh --kubeconfig <path> [--namespace <ns>] [--server-image <tag>] [--dashboard-image <tag>] [--registry <host:port>]
#
# The CheCluster patch is critical: che-server provides /api/kubernetes/namespace/provision
# and other APIs. Without che-server, the dashboard shows "Route POST:/api/kubernetes/namespace/provision not found".
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG_FILE=""
NAMESPACE="eclipse-che"
SERVER_IMAGE=""   # e.g. pr-951 or next; empty = infer from CheCluster
DASHBOARD_IMAGE="" # e.g. pr-1442 or next; empty = infer from CheCluster
REGISTRY_OVERRIDE=""  # optional; auto-detected from cluster if not set

while [[ $# -gt 0 ]]; do
    case $1 in
        --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --server-image) SERVER_IMAGE="$2"; shift 2 ;;
        --dashboard-image) DASHBOARD_IMAGE="$2"; shift 2 ;;
        --registry) REGISTRY_OVERRIDE="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [ -z "$KUBECONFIG_FILE" ] || [ ! -f "$KUBECONFIG_FILE" ]; then
    echo "Usage: $0 --kubeconfig <path> [--namespace eclipse-che] [--server-image <tag>] [--dashboard-image <tag>]"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG_FILE"

# Auto-detect local registry from cluster (ImageTagMirrorSet/ICSP applied by mirror script)
# Prevents wrong-registry errors when mirror was run on a different cluster
REGISTRY="${REGISTRY_OVERRIDE:-}"
if [ -z "$REGISTRY" ]; then
  REGISTRY=$(oc get imagetagmirrorset -o jsonpath='{.items[0].spec.imageTagMirrors[0].mirrors[0]}' 2>/dev/null | sed 's|/.*||' || echo "")
fi
if [ -z "$REGISTRY" ]; then
  REGISTRY=$(oc get imagecontentsourcepolicy -o jsonpath='{.items[0].spec.repositoryDigestMirrors[0].mirrors[0]}' 2>/dev/null | sed 's|/.*||' || echo "")
fi
if [ -z "$REGISTRY" ]; then
  REGISTRY="virthost.ostest.test.metalkube.org:5000"
  echo "WARN: Could not auto-detect registry, using default: $REGISTRY"
fi
echo "Using registry: $REGISTRY"

# Apply ImageTagMirrorSet if che-image-mirrors exists (with registry substitution)
MIRRORS_YAML="${REPO_ROOT}/manifests/che/che-image-mirrors.yaml"
if [ -f "$MIRRORS_YAML" ]; then
  echo "Applying ImageTagMirrorSet..."
  sed "s|virthost.ostest.test.metalkube.org:5000|${REGISTRY}|g" "$MIRRORS_YAML" | oc apply -f -
fi

echo "Patching che-operator..."
oc set image deployment/che-operator -n "$NAMESPACE" che-operator="${REGISTRY}/eclipse-che/eclipse/che-operator:next"

echo "Patching devworkspace-controller-manager..."
oc set image deployment/devworkspace-controller-manager -n devworkspace-controller devworkspace-controller="${REGISTRY}/eclipse-che/devfile/devworkspace-controller:next"

# Mount webhook TLS cert - controller crashes with "no such file or directory" without it
if ! oc get deployment devworkspace-controller-manager -n devworkspace-controller -o jsonpath='{.spec.template.spec.volumes}' 2>/dev/null | grep -q webhook-cert; then
  echo "Mounting webhook cert in devworkspace-controller-manager..."
  oc patch deployment devworkspace-controller-manager -n devworkspace-controller --type=json -p='[
    {"op":"add","path":"/spec/template/spec/volumes","value":[{"name":"webhook-cert","secret":{"secretName":"devworkspace-webhookserver-tls"}}]},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts","value":[{"name":"webhook-cert","mountPath":"/tmp/k8s-webhook-server/serving-certs","readOnly":true}]}
  ]' 2>/dev/null || true
fi

echo "Patching devworkspace-webhook-server..."
# Webhook deployment may be created by Che operator after CheCluster - retry a few times
for i in 1 2 3 4 5 6; do
  if oc set image deployment/devworkspace-webhook-server -n devworkspace-controller webhook-server="${REGISTRY}/eclipse-che/devfile/devworkspace-controller:next" 2>/dev/null; then
    echo "  devworkspace-webhook-server patched"
    break
  fi
  [ $i -lt 6 ] && sleep 5
done

# Delete failed DWO pods to trigger repull (critical for workspace creation - webhook must have endpoints)
echo "Deleting failed DevWorkspace Operator pods to trigger repull..."
oc delete pod -n devworkspace-controller -l app.kubernetes.io/name=devworkspace-webhook-server --force --grace-period=0 2>/dev/null || true
oc delete pod -n devworkspace-controller -l app.kubernetes.io/name=devworkspace-controller --force --grace-period=0 2>/dev/null || true

# Patch CheCluster to use local registry for che-server and dashboard.
# Without this, che-server never deploys (InstallOrUpdateFailed) and
# POST /api/kubernetes/namespace/provision returns "Route not found".
echo "Patching CheCluster (che-server, dashboard) to use local registry..."
if oc get checluster eclipse-che -n "$NAMESPACE" &>/dev/null; then
    SERVER_IMG="${SERVER_IMAGE:-$(oc get checluster eclipse-che -n "$NAMESPACE" -o jsonpath='{.spec.components.cheServer.deployment.containers[0].image}' 2>/dev/null | sed -n 's|.*/che-server:||p' || echo 'next')}"
    DASHBOARD_IMG="${DASHBOARD_IMAGE:-$(oc get checluster eclipse-che -n "$NAMESPACE" -o jsonpath='{.spec.components.dashboard.deployment.containers[0].image}' 2>/dev/null | sed -n 's|.*/che-dashboard:||p' || echo 'next')}"
    oc patch checluster eclipse-che -n "$NAMESPACE" --type=merge -p "{
        \"spec\": {
            \"components\": {
                \"cheServer\": {
                    \"deployment\": {
                        \"containers\": [{
                            \"name\": \"che-server\",
                            \"image\": \"${REGISTRY}/eclipse-che/eclipse/che-server:${SERVER_IMG}\",
                            \"imagePullPolicy\": \"Always\"
                        }]
                    }
                },
                \"dashboard\": {
                    \"deployment\": {
                        \"containers\": [{
                            \"name\": \"dashboard\",
                            \"image\": \"${REGISTRY}/eclipse-che/eclipse/che-dashboard:${DASHBOARD_IMG}\",
                            \"imagePullPolicy\": \"Always\"
                        }]
                    }
                }
            }
        }
    }"
    echo "CheCluster patched: che-server:${SERVER_IMG}, dashboard:${DASHBOARD_IMG}"
    echo "Ensure these images were mirrored (mirror script with --server-image ${SERVER_IMG} --dashboard-image ${DASHBOARD_IMG})."
else
    echo "CheCluster eclipse-che not found in $NAMESPACE, skipping CheCluster patch."
fi

echo "Deleting failed pods to trigger repull..."
oc delete pod -n "$NAMESPACE" -l app.kubernetes.io/name=che-operator --force --grace-period=0 2>/dev/null || true
oc delete pod -n devworkspace-controller -l app.kubernetes.io/name=devworkspace-controller --force --grace-period=0 2>/dev/null || true

echo "Done. If DWO controller crashes (missing webhook certs), run: oc patch deployment devworkspace-controller-manager -n devworkspace-controller --type=json -p='[{\"op\":\"add\",\"path\":\"/spec/template/spec/volumes\",\"value\":[{\"name\":\"webhook-cert\",\"secret\":{\"secretName\":\"devworkspace-webhookserver-tls\"}}]},{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/volumeMounts\",\"value\":[{\"name\":\"webhook-cert\",\"mountPath\":\"/tmp/k8s-webhook-server/serving-certs\",\"readOnly\":true}]}]'"
echo "And ensure devworkspace-webhookserver-tls secret exists (generate with openssl if needed)."
