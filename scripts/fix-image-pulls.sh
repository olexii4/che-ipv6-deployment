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

# Apply ImageTagMirrorSet only if it does not exist yet.
# Re-applying an ITMS (even unchanged) can trigger a MachineConfigPool rollout
# which reboots cluster nodes. The proxy used by kubectl runs on a node, so a reboot
# severs the connection and makes the cluster appear unavailable.
# mirror-images-to-registry.sh applies the ITMS once at initial setup; skip here.
MIRRORS_YAML="${REPO_ROOT}/manifests/che/che-image-mirrors.yaml"
if [ -f "$MIRRORS_YAML" ]; then
  ITMS_NAME=$(grep -m1 'name:' "$MIRRORS_YAML" | awk '{print $2}' || echo "che-eclipse-mirror")
  if oc get imagetagmirrorset "${ITMS_NAME}" &>/dev/null 2>&1; then
    echo "ImageTagMirrorSet '${ITMS_NAME}' already exists — skipping apply (avoids node reboots)"
  else
    echo "Applying ImageTagMirrorSet '${ITMS_NAME}'..."
    sed "s|virthost.ostest.test.metalkube.org:5000|${REGISTRY}|g" "$MIRRORS_YAML" | oc apply -f -
  fi
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

# Ensure the exact SHA tag used by the DWO bundle is available in the local registry.
#
# Problem: DWO controller-manager reconciles devworkspace-webhook-server back to its original
# image tag (e.g. quay.io/devfile/devworkspace-controller:sha-cce29e8). If that SHA tag is not
# in the local registry, the webhook pod stays in ImagePullBackOff and workspace creation fails
# with "no endpoints available for service devworkspace-webhookserver".
#
# Solution: read the SHA tag from the bundle-deployed deployment, then re-tag :next as that SHA
# in the local registry using skopeo on a cluster node (nodes have direct registry access).
# Also handles project-clone - DWO injects it as an init container using the same SHA tag.
ensure_sha_tags_in_registry() {
  local registry="${1}"

  # Read the image tag the DWO bundle set (e.g. quay.io/devfile/devworkspace-controller:sha-cce29e8)
  local bundle_image
  bundle_image=$(oc get deployment devworkspace-webhook-server -n devworkspace-controller \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
  local sha_tag
  sha_tag=$(echo "${bundle_image}" | grep -oE 'sha-[a-f0-9]+$' || echo "")

  if [ -z "${sha_tag}" ]; then
    echo "  No sha-* tag detected in webhook deployment image (image: ${bundle_image}), skipping re-tag"
    return 0
  fi

  echo "  Detected DWO SHA tag: ${sha_tag}"

  # Pick a ready node to run skopeo on
  local node
  node=$(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
  if [ -z "${node}" ]; then
    echo "  WARN: no cluster node found - cannot re-tag SHA images. Run mirror-images-to-registry.sh with --mode full."
    return 0
  fi

  # Re-tag :next as :sha-xxx for both devworkspace-controller and project-clone.
  # project-clone is injected by DWO as an init container using the same SHA tag.
  local images=("devfile/devworkspace-controller" "devfile/project-clone")
  for img_path in "${images[@]}"; do
    local src="${registry}/eclipse-che/${img_path}:next"
    local dst="${registry}/eclipse-che/${img_path}:${sha_tag}"
    echo "  Re-tagging ${img_path}:${sha_tag} in local registry (via node ${node})..."
    if oc debug "node/${node}" --quiet -- chroot /host \
        skopeo copy --dest-tls-verify=false --src-tls-verify=false \
        "docker://${src}" "docker://${dst}" 2>/dev/null; then
      echo "    OK: ${img_path}:${sha_tag}"
    else
      # Fallback: podman pull + tag + push (available on all OpenShift nodes)
      oc debug "node/${node}" --quiet -- chroot /host bash -c \
        "podman pull --tls-verify=false '${src}' \
         && podman tag '${src}' '${dst}' \
         && podman push --tls-verify=false '${dst}'" 2>/dev/null \
        && echo "    OK (podman fallback): ${img_path}:${sha_tag}" \
        || echo "    WARN: re-tag failed for ${img_path}:${sha_tag}. Run mirror-images-to-registry.sh to add it manually."
    fi
  done
}

# Temporarily set DWO MutatingWebhookConfiguration to failurePolicy: Ignore.
# When devworkspace-webhook-server is in ImagePullBackOff (no endpoints), the webhook
# blocks ALL admission requests for matched resources. With failurePolicy: Fail this
# can cascade: oc debug node (needed for re-tag) creates a pod that the webhook tries
# to intercept, fails, and the re-tag never runs. Setting Ignore lets pods through
# while we fix the image; DWO controller-manager reconciles it back to Fail once healthy.
DWO_MWC_NAME=$(oc get mutatingwebhookconfiguration -o name 2>/dev/null | grep devworkspace | head -1 || echo "")
if [ -n "$DWO_MWC_NAME" ]; then
  echo "Patching DWO MutatingWebhookConfiguration to failurePolicy: Ignore (temporary)..."
  oc patch "${DWO_MWC_NAME}" --type='json' \
    -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"},{"op":"replace","path":"/webhooks/1/failurePolicy","value":"Ignore"}]' \
    2>/dev/null || \
  oc patch "${DWO_MWC_NAME}" --type='json' \
    -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]' \
    2>/dev/null || true
fi

echo "Ensuring DWO SHA tags are available in local registry..."
ensure_sha_tags_in_registry "${REGISTRY}"

# Restore DWO MutatingWebhookConfiguration to failurePolicy: Fail.
# DWO controller-manager will also reconcile this back automatically once healthy.
if [ -n "$DWO_MWC_NAME" ]; then
  echo "Restoring DWO MutatingWebhookConfiguration to failurePolicy: Fail..."
  oc patch "${DWO_MWC_NAME}" --type='json' \
    -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"},{"op":"replace","path":"/webhooks/1/failurePolicy","value":"Fail"}]' \
    2>/dev/null || \
  oc patch "${DWO_MWC_NAME}" --type='json' \
    -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"}]' \
    2>/dev/null || true
fi

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
