#!/bin/bash
#
# Copyright (c) 2025-2026 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Eclipse Che Deployment from OLM Bundles
#
# Automated script for deploying Eclipse Che operators without OLM (Operator Lifecycle Manager).
# Instead of using OLM catalog, this script:
#   1. Extracts operator manifests directly from OLM bundle images
#   2. Applies them manually to the cluster
#   3. Creates CheCluster custom resource
#
# Why this approach:
#   - Bypasses OLM catalog networking issues on IPv6-only clusters
#   - Works when catalog pods cannot pull images due to IPv6 ClusterIP connectivity
#   - Uses official OLM bundle images (same source as OLM would use)

set -e

# Get script directory for accessing manifest files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
NAMESPACE="eclipse-che"
DASHBOARD_IMAGE=""
CHE_SERVER_IMAGE=""
KUBECONFIG_PATH=""
SKIP_DEVWORKSPACE=false
AIRGAP_SAMPLES=true
DEVWORKSPACE_BUNDLE_IMAGE="quay.io/devfile/devworkspace-operator-bundle:next"
CHE_BUNDLE_IMAGE="quay.io/eclipse/eclipse-che-olm-bundle@sha256:b525748e410cf2ddb405209ac5bce7b4ed2e401b7141f6c4edcea0e32e5793a1"

# Function to print colored output
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --kubeconfig)
            KUBECONFIG_PATH="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --dashboard-image)
            DASHBOARD_IMAGE="$2"
            shift 2
            ;;
        --server-image|--che-server-image)
            CHE_SERVER_IMAGE="$2"
            shift 2
            ;;
        --skip-devworkspace)
            SKIP_DEVWORKSPACE=true
            shift
            ;;
        --devworkspace-bundle)
            DEVWORKSPACE_BUNDLE_IMAGE="$2"
            shift 2
            ;;
        --che-bundle)
            CHE_BUNDLE_IMAGE="$2"
            shift 2
            ;;
        --airgap-samples)
            AIRGAP_SAMPLES=true
            shift
            ;;
        --no-airgap-samples)
            AIRGAP_SAMPLES=false
            shift
            ;;
        --help)
            echo "Manual Eclipse Che Deployment from OLM Bundles"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --kubeconfig <path>              Path to kubeconfig file (required)"
            echo "  --namespace <name>               Namespace for Eclipse Che (default: eclipse-che)"
            echo "  --dashboard-image <image>        Dashboard container image (shortcuts: pr-XXXX, next, latest)"
            echo "  --server-image <image>           Che server container image (shortcuts: pr-XXXX, next, latest)"
            echo "  --skip-devworkspace              Skip DevWorkspace Operator installation"
            echo "  --devworkspace-bundle <image>    DevWorkspace bundle image (default: quay.io/devfile/devworkspace-operator-bundle:next)"
            echo "  --che-bundle <image>             Che bundle image (default: quay.io/eclipse/eclipse-che-openshift-opm-bundles:next)"
            echo "  --airgap-samples                 Enable air-gap samples (mount in dashboard, no proxy needed) (default)"
            echo "  --no-airgap-samples              Disable air-gap samples (samples require GitHub/proxy)"
            echo "  --help                           Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$KUBECONFIG_PATH" ]; then
    log_error "Missing required argument: --kubeconfig"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

# Check for podman
if ! command -v podman &> /dev/null; then
    log_error "podman is required but not installed"
    exit 1
fi

log_info "=== Manual Eclipse Che Deployment from OLM Bundles ==="
log_info "Namespace: $NAMESPACE"
log_info "Dashboard Image: ${DASHBOARD_IMAGE:-default}"
log_info "Che Server Image: ${CHE_SERVER_IMAGE:-default}"
log_info "Air-gap samples: $AIRGAP_SAMPLES (samples run without proxy when enabled)"
log_info "DevWorkspace Bundle: $DEVWORKSPACE_BUNDLE_IMAGE"
log_info "Che Bundle: $CHE_BUNDLE_IMAGE"
echo

# Create temporary directory for manifests
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

log_info "Using temp directory: $TEMP_DIR"
echo

#######################################
# Step 1: Deploy DevWorkspace Operator
#######################################

if [ "$SKIP_DEVWORKSPACE" = false ]; then
    log_info "Step 1: Deploying DevWorkspace Operator from bundle"

    # Pull bundle image
    log_info "Pulling DevWorkspace bundle image..."
    podman pull "$DEVWORKSPACE_BUNDLE_IMAGE"

    # Extract manifests from bundle
    log_info "Extracting manifests from bundle..."
    BUNDLE_CONTAINER=$(podman create "$DEVWORKSPACE_BUNDLE_IMAGE")
    podman cp "${BUNDLE_CONTAINER}:/manifests" "$TEMP_DIR/devworkspace-manifests"
    podman rm "$BUNDLE_CONTAINER"

    # Find and apply CSV (contains all manifests)
    CSV_FILE=$(find "$TEMP_DIR/devworkspace-manifests" -name "*.clusterserviceversion.yaml" | head -1)

    if [ -z "$CSV_FILE" ]; then
        log_error "No ClusterServiceVersion found in bundle"
        exit 1
    fi

    log_info "Found CSV: $(basename $CSV_FILE)"

    # Extract and apply CRDs from bundle
    log_info "Applying DevWorkspace CRDs..."

    # Create devworkspace-controller namespace if it doesn't exist
    kubectl create namespace devworkspace-controller --dry-run=client -o yaml | kubectl apply -f -

    # Apply all CRD files from the bundle (using server-side apply for large resources)
    find "$TEMP_DIR/devworkspace-manifests" -name "*.crd.yaml" -o -name "*_devworkspace*.yaml" | while read crd; do
        log_info "  Applying $(basename $crd)"
        kubectl apply --server-side=true --force-conflicts -f "$crd" 2>/dev/null || kubectl apply -f "$crd"
    done

    # Parse CSV and extract deployment/RBAC specs
    log_info "Extracting operator deployment from CSV..."

    # Use yq or python to parse CSV and extract deployment
    # Check if yq is the Go version (mikefarah/yq) which supports 'eval' command
    # Python yq (kislyuk/yq) is a jq wrapper and doesn't support the eval syntax
    if command -v yq &> /dev/null && ! yq --help 2>&1 | grep -q "jq wrapper"; then
        # Extract deployment name and SA from CSV (OLM format)
        DEPLOY_NAME=$(yq eval '.spec.install.spec.deployments[0].name' "$CSV_FILE")
        SA_NAME=$(yq eval '.spec.install.spec.clusterPermissions[0].serviceAccountName' "$CSV_FILE")
        export DEPLOY_NAME SA_NAME

        # Build Deployment: header from manifest + spec from CSV
        envsubst < "${MANIFEST_DIR}/che/dwo-deployment-header.yaml" > "$TEMP_DIR/dwo-deployment.yaml"
        yq eval '.spec.install.spec.deployments[0].spec' "$CSV_FILE" | sed 's/^/  /' >> "$TEMP_DIR/dwo-deployment.yaml"

        # Build RBAC: header + rules from CSV + footer
        envsubst < "${MANIFEST_DIR}/che/dwo-rbac-header.yaml" > "$TEMP_DIR/dwo-rbac.yaml"
        yq eval '.spec.install.spec.clusterPermissions[0].rules' "$CSV_FILE" | sed 's/^/  /' >> "$TEMP_DIR/dwo-rbac.yaml"
        envsubst < "${MANIFEST_DIR}/che/dwo-rbac-footer.yaml" >> "$TEMP_DIR/dwo-rbac.yaml"

    else
        log_warn "yq not found, using simplified extraction"
        OPERATOR_IMAGE=$(grep 'image:' "$CSV_FILE" | grep devworkspace-controller | head -1 | sed -E 's/.*image: *([^ ]+).*/\1/')
        OPERATOR_IMAGE="${OPERATOR_IMAGE:-quay.io/devfile/devworkspace-controller:next}"
        export OPERATOR_IMAGE
        envsubst < "${MANIFEST_DIR}/che/dwo-fallback.yaml" > "$TEMP_DIR/dwo-deployment.yaml"
    fi

    # Apply manifests
    log_info "Applying DevWorkspace Operator manifests..."
    if [ -f "$TEMP_DIR/dwo-rbac.yaml" ]; then
        kubectl apply -f "$TEMP_DIR/dwo-rbac.yaml" -f "$TEMP_DIR/dwo-deployment.yaml"
    else
        kubectl apply -f "$TEMP_DIR/dwo-deployment.yaml"
    fi

    # Wait for deployment
    log_info "Waiting for DevWorkspace Operator..."
    kubectl wait --for=condition=available --timeout=300s \
        deployment/devworkspace-controller-manager \
        -n devworkspace-controller 2>/dev/null || {
        log_warn "Deployment wait failed, checking pod status..."
        sleep 30
    }

    log_success "DevWorkspace Operator deployed"
    echo
else
    log_warn "Skipping DevWorkspace Operator installation"
    log_info "Installing DevWorkspace CRDs (required by Che Operator)..."

    # Even when skipping DevWorkspace operator, we still need the CRDs
    # Pull bundle image
    podman pull "$DEVWORKSPACE_BUNDLE_IMAGE" >/dev/null 2>&1

    # Extract manifests from bundle
    BUNDLE_CONTAINER=$(podman create "$DEVWORKSPACE_BUNDLE_IMAGE")
    podman cp "${BUNDLE_CONTAINER}:/manifests" "$TEMP_DIR/devworkspace-manifests" 2>/dev/null
    podman rm "$BUNDLE_CONTAINER" >/dev/null 2>&1

    # Apply all DevWorkspace CRDs
    find "$TEMP_DIR/devworkspace-manifests" -name "*.crd.yaml" -o -name "*devworkspace*.yaml" | while read crd; do
        log_info "  Applying $(basename $crd)"
        kubectl apply --server-side=true --force-conflicts -f "$crd" 2>/dev/null || kubectl apply -f "$crd"
    done

    log_success "DevWorkspace CRDs installed"
    echo
fi

#######################################
# Step 2: Create Eclipse Che Namespace
#######################################

log_info "Step 2: Creating namespace $NAMESPACE"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Add monitoring label for OpenShift
kubectl label namespace "$NAMESPACE" \
    app.kubernetes.io/part-of=che.eclipse.org \
    app.kubernetes.io/component=che \
    --overwrite

log_success "Namespace $NAMESPACE ready"
echo

SAMPLES_JSON="${MANIFEST_DIR}/che/air-gap-samples.json"

#######################################
# Step 2c: Create air-gap samples Secret (samples run without proxy)
#######################################
# Prepares samples from air-gap-samples.json: clones repos, zips them,
# transforms URLs to dashboard API (devfile/project download). Mounts at
# /public/dashboard/devfile-registry/air-gap. Dashboard serves via /dashboard/api/airgap-sample/*
# so workspace creation does not need GitHub/proxy access.

AIRGAP_SECRET_CREATED=false
if [ "$AIRGAP_SAMPLES" = true ] && [ -f "$SAMPLES_JSON" ]; then
    log_info "Step 2c: Preparing air-gap samples (no proxy needed for sample workspaces)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    AIRGAP_DIR="${REPO_ROOT}/build/air-gap"
    PREPARE_SCRIPT="${SCRIPT_DIR}/prepare-airgap-from-samples.sh"

    if [ -x "$PREPARE_SCRIPT" ]; then
        if (cd "$REPO_ROOT" && "$PREPARE_SCRIPT" -i "$SAMPLES_JSON" -o "$AIRGAP_DIR") 2>/dev/null; then
            if [ -f "${AIRGAP_DIR}/index.json" ] && [ -n "$(ls -A "$AIRGAP_DIR" 2>/dev/null)" ]; then
                # Substitute CHE_DASHBOARD_INTERNAL_URL with pod env value (matches Che operator)
                # http://che-dashboard.<namespace>.svc:8080
                CHE_DASHBOARD_INTERNAL_URL="http://che-dashboard.${NAMESPACE}.svc:8080"
                for f in "${AIRGAP_DIR}"/index.json "${AIRGAP_DIR}"/*-devfile.yaml; do
                    if [ -f "$f" ]; then
                        sed "s|CHE_DASHBOARD_INTERNAL_URL|${CHE_DASHBOARD_INTERNAL_URL}|g" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    fi
                done
                log_info "Creating che-dashboard-airgap Secret (mounts into /public/dashboard/devfile-registry/air-gap)"
                # CRITICAL: Use sorted file order. Non-deterministic order causes operator to generate
                # different volume mount order each reconcile -> "object has been modified" conflict ->
                # InstallOrUpdateFailed and che-server never deploys (Route POST:/api/.../provision not found)
                FROM_FILE_ARGS=()
                while IFS= read -r f; do
                    [ -f "$f" ] && FROM_FILE_ARGS+=(--from-file="$(basename "$f")=$f")
                done < <(find "${AIRGAP_DIR}" -maxdepth 1 -type f | sort)
                if [ ${#FROM_FILE_ARGS[@]} -gt 0 ]; then
                    kubectl create secret generic che-dashboard-airgap \
                        "${FROM_FILE_ARGS[@]}" \
                        -n "$NAMESPACE" \
                        --dry-run=client -o yaml | kubectl apply -f -
                else
                    kubectl create secret generic che-dashboard-airgap \
                        --from-file="${AIRGAP_DIR}/" \
                        -n "$NAMESPACE" \
                        --dry-run=client -o yaml | kubectl apply -f -
                fi
                kubectl label secret che-dashboard-airgap \
                    app.kubernetes.io/part-of=che.eclipse.org \
                    app.kubernetes.io/component=che-dashboard-secret \
                    -n "$NAMESPACE" --overwrite
                kubectl annotate secret che-dashboard-airgap \
                    che.eclipse.org/mount-as=subpath \
                    che.eclipse.org/mount-path=/public/dashboard/devfile-registry/air-gap \
                    -n "$NAMESPACE" --overwrite
                AIRGAP_SECRET_CREATED=true
                log_success "Air-gap samples Secret created (samples use dashboard API, no GitHub URLs)"
            else
                log_warn "Air-gap output empty, skipping Secret creation"
            fi
        else
            log_warn "prepare-airgap-from-samples failed (network required for git clone). Samples will need proxy."
        fi
    else
        log_warn "prepare-airgap-from-samples.sh not found or not executable, skipping air-gap Secret"
    fi
elif [ "$AIRGAP_SAMPLES" = false ]; then
    log_info "Step 2c: Skipping air-gap samples (--no-airgap-samples)"
fi
echo

#######################################
# Step 2b: Create Getting Started Samples ConfigMap (fallback only)
#######################################
# When air-gap Secret exists, dashboard uses it (zip/dashboard API). Skip ConfigMap.
# When air-gap fails or --no-airgap-samples, use ConfigMap with GitHub URLs as fallback.

if [ "$AIRGAP_SECRET_CREATED" = false ] && [ -f "$SAMPLES_JSON" ]; then
    log_info "Step 2b: Creating getting-started-samples ConfigMap (GitHub URLs fallback)"
    kubectl create configmap getting-started-samples \
        --from-file=samples.json="$SAMPLES_JSON" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    kubectl label configmap getting-started-samples \
        app.kubernetes.io/part-of=che.eclipse.org \
        app.kubernetes.io/component=getting-started-samples \
        -n "$NAMESPACE" --overwrite
    log_success "Getting started samples ConfigMap created"
fi
echo

#######################################
# Step 3: Deploy Che Operator from Bundle
#######################################

log_info "Step 3: Deploying Eclipse Che Operator from bundle"

# Pull Che bundle image
log_info "Pulling Che bundle image..."
podman pull "$CHE_BUNDLE_IMAGE"

# Extract manifests from bundle
log_info "Extracting manifests from bundle..."
BUNDLE_CONTAINER=$(podman create "$CHE_BUNDLE_IMAGE")
podman cp "${BUNDLE_CONTAINER}:/manifests" "$TEMP_DIR/che-manifests"
podman rm "$BUNDLE_CONTAINER"

# Apply CRDs
log_info "Applying Che CRDs..."
find "$TEMP_DIR/che-manifests" -name "*_checlusters*.yaml" -o -name "*.crd.yaml" | while read crd; do
    log_info "Applying $(basename $crd)"
    # Use server-side apply to handle large CRD annotations
    kubectl apply --server-side=true --force-conflicts -f "$crd"
done

# Find CSV
CSV_FILE=$(find "$TEMP_DIR/che-manifests" -name "*.clusterserviceversion.yaml" | head -1)

if [ -z "$CSV_FILE" ]; then
    log_error "No ClusterServiceVersion found in Che bundle"
    exit 1
fi

log_info "Found Che CSV: $(basename $CSV_FILE)"

# Extract operator deployment
# Check if yq is the Go version (mikefarah/yq), not the Python jq wrapper
if command -v yq &> /dev/null && ! yq --help 2>&1 | grep -q "jq wrapper"; then
    log_info "Using yq to extract deployment..."
    SA_NAME=$(yq eval '.spec.install.spec.clusterPermissions[0].serviceAccountName' "$CSV_FILE")
    SA_NAME="${SA_NAME:-che-operator}"
    DEPLOY_NAME=$(yq eval '.spec.install.spec.deployments[0].name' "$CSV_FILE")
    export NAMESPACE SA_NAME DEPLOY_NAME

    # Build che-operator.yaml from manifests + CSV
    envsubst < "${MANIFEST_DIR}/che/che-operator-sa.yaml" > "$TEMP_DIR/che-operator.yaml"
    envsubst < "${MANIFEST_DIR}/che/che-operator-cr-header.yaml" >> "$TEMP_DIR/che-operator.yaml"
    yq eval '.spec.install.spec.clusterPermissions[0].rules' "$CSV_FILE" | sed 's/^/  /' >> "$TEMP_DIR/che-operator.yaml"
    envsubst < "${MANIFEST_DIR}/che/che-operator-crb.yaml" >> "$TEMP_DIR/che-operator.yaml"
    envsubst < "${MANIFEST_DIR}/che/che-operator-deployment-header.yaml" >> "$TEMP_DIR/che-operator.yaml"
    yq eval '.spec.install.spec.deployments[0].spec' "$CSV_FILE" | sed 's/^/  /' >> "$TEMP_DIR/che-operator.yaml"

else
    log_warn "yq not found, using simplified operator deployment"
    OPERATOR_IMAGE=$(grep 'image:' "$CSV_FILE" | grep che-operator | head -1 | sed -E 's/.*image: *([^ ]+).*/\1/')
    OPERATOR_IMAGE="${OPERATOR_IMAGE:-quay.io/eclipse/che-operator:next}"
    export NAMESPACE OPERATOR_IMAGE
    envsubst < "${MANIFEST_DIR}/che/che-operator-fallback.yaml" > "$TEMP_DIR/che-operator.yaml"
fi

# Apply Che Operator manifests
log_info "Applying Che Operator manifests..."
kubectl apply -f "$TEMP_DIR/che-operator.yaml"

# Create webhook TLS certificate for Che Operator
log_info "Creating webhook TLS certificate..."
CERT_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR $CERT_DIR" EXIT

# Generate self-signed certificate
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CERT_DIR/tls.key" \
    -out "$CERT_DIR/tls.crt" \
    -days 365 \
    -subj "/CN=che-operator-webhook-server.${NAMESPACE}.svc" \
    >/dev/null 2>&1

# Create kubernetes.io/tls secret
kubectl create secret tls che-operator-webhook-server-cert \
    -n "$NAMESPACE" \
    --cert="$CERT_DIR/tls.crt" \
    --key="$CERT_DIR/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f -

# Patch operator deployment to mount webhook certificates
log_info "Mounting webhook certificates to operator..."
kubectl patch deployment che-operator -n "$NAMESPACE" --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes",
    "value": [
      {
        "name": "webhook-cert",
        "secret": {
          "secretName": "che-operator-webhook-server-cert"
        }
      }
    ]
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts",
    "value": [
      {
        "name": "webhook-cert",
        "mountPath": "/tmp/k8s-webhook-server/serving-certs",
        "readOnly": true
      }
    ]
  }
]' 2>/dev/null || log_warn "Webhook cert mount patch skipped (may already exist)"

# Create leader election RBAC for Che Operator
log_info "Creating leader election RBAC..."
export NAMESPACE
export SA_NAME=${SA_NAME:-che-operator}
envsubst < "${MANIFEST_DIR}/che/leader-election-rbac.yaml" | kubectl apply -f -

# Wait for Che Operator
log_info "Waiting for Che Operator..."
sleep 10  # Give operator time to restart with webhook certs
kubectl wait --for=condition=available --timeout=300s \
    deployment/che-operator \
    -n "$NAMESPACE" 2>/dev/null || {
    log_warn "Deployment wait failed, checking pod status..."
    sleep 30
}

log_success "Che Operator deployed"
echo

#######################################
# Step 4: Create CheCluster CR
#######################################

log_info "Step 4: Creating CheCluster Custom Resource"

# Expand che-server image shortcuts
if [ -n "$CHE_SERVER_IMAGE" ]; then
    case "$CHE_SERVER_IMAGE" in
        pr-*)
            CHE_SERVER_IMAGE="quay.io/eclipse/che-server:$CHE_SERVER_IMAGE"
            ;;
        next)
            CHE_SERVER_IMAGE="quay.io/eclipse/che-server:next"
            ;;
        latest)
            CHE_SERVER_IMAGE="quay.io/eclipse/che-server:latest"
            ;;
    esac
fi

# Expand dashboard image shortcuts
if [ -n "$DASHBOARD_IMAGE" ]; then
    case "$DASHBOARD_IMAGE" in
        pr-*)
            DASHBOARD_IMAGE="quay.io/eclipse/che-dashboard:$DASHBOARD_IMAGE"
            ;;
        next)
            DASHBOARD_IMAGE="quay.io/eclipse/che-dashboard:next"
            ;;
        latest)
            DASHBOARD_IMAGE="quay.io/eclipse/che-dashboard:latest"
            ;;
    esac
fi

# Build image lines for template substitution
CHE_SERVER_IMAGE_LINE=""
if [ -n "$CHE_SERVER_IMAGE" ]; then
    CHE_SERVER_IMAGE_LINE=$'\n'"            image: ${CHE_SERVER_IMAGE}"
fi

DASHBOARD_IMAGE_LINE=""
if [ -n "$DASHBOARD_IMAGE" ]; then
    DASHBOARD_IMAGE_LINE=$'\n'"            image: ${DASHBOARD_IMAGE}"
fi

# Check if cluster-wide proxy is configured
CLUSTER_PROXY_HTTP=$(kubectl get proxy cluster -o jsonpath='{.spec.httpProxy}' 2>/dev/null || echo "")
CLUSTER_PROXY_HTTPS=$(kubectl get proxy cluster -o jsonpath='{.spec.httpsProxy}' 2>/dev/null || echo "")
CLUSTER_NO_PROXY=$(kubectl get proxy cluster -o jsonpath='{.spec.noProxy}' 2>/dev/null || echo "")

# Devfile registry: IPv6-only clusters use internal registry + air-gap samples only.
# No cluster-wide proxy: IPv4 proxy does not work from IPv6-only pods.
# cheServer.proxy: only set when cluster Proxy CR is explicitly configured (e.g. dual-stack).
# We do NOT use kubeconfig proxy-url for cheServer.proxy (it would block Gitea/internal traffic).
CHE_SERVER_PROXY_LINE=""
PROXY_URL_RAW="${CLUSTER_PROXY_HTTP:-$CLUSTER_PROXY_HTTPS}"
if [ -n "$CLUSTER_PROXY_HTTP" ] || [ -n "$CLUSTER_PROXY_HTTPS" ]; then
    log_info "Cluster-wide proxy detected - enabling cheServer.proxy"
    log_info "Devfile registry: internal only (IPv6 pods cannot reach registry.devfile.io)"

    # Build explicit cheServer.proxy so che-server (factory resolver) may use proxy on dual-stack
    # Cluster Proxy Status can lag; explicit CR overrides ensure proxy is applied immediately
    if [ -n "$PROXY_URL_RAW" ]; then
        PROXY_URL_RAW="${PROXY_URL_RAW%/}"
        PROXY_URL_BASE=$(echo "$PROXY_URL_RAW" | sed -E 's/:([0-9]+)\/?$//')
        PROXY_PORT=$(echo "$PROXY_URL_RAW" | sed -En 's/.*:([0-9]+)\/?$/\1/p')
        if [ -z "$PROXY_PORT" ]; then
            [ "${PROXY_URL_RAW#https:}" != "$PROXY_URL_RAW" ] && PROXY_PORT="443" || PROXY_PORT="80"
        fi
        # nonProxyHosts: use cluster noProxy if set, else defaults (comma-separated -> YAML array)
        if [ -n "$CLUSTER_NO_PROXY" ]; then
            NO_PROXY_STR="$CLUSTER_NO_PROXY"
        else
            NO_PROXY_STR="localhost,127.0.0.1,.cluster.local,.svc,.metalkube.org,virthost.ostest.test.metalkube.org,fd02::/112,registry.devfile.io,.devfile.io,github.com,raw.githubusercontent.com,githubusercontent.com"
        fi
        NON_PROXY_YAML=""
        IFS=',' read -ra PARTS <<< "$NO_PROXY_STR"
        for h in "${PARTS[@]}"; do
            h=$(echo "$h" | tr -d ' ')
            [ -z "$h" ] && continue
            NON_PROXY_YAML="${NON_PROXY_YAML}
          - ${h}"
        done
        CHE_SERVER_PROXY_LINE="
      proxy:
        url: ${PROXY_URL_BASE}
        port: \"${PROXY_PORT}\"
        nonProxyHosts:${NON_PROXY_YAML}"
    fi
else
    log_warn "No cluster-wide proxy detected - cheServer.proxy disabled"
fi

# Apply CheCluster CR from template
export NAMESPACE
export CHE_SERVER_IMAGE_LINE
export DASHBOARD_IMAGE_LINE
export CHE_SERVER_PROXY_LINE
envsubst < "${MANIFEST_DIR}/che/checluster.yaml" > "$TEMP_DIR/checluster.yaml"

log_info "Applying CheCluster CR:"
cat "$TEMP_DIR/checluster.yaml"
echo

kubectl apply -f "$TEMP_DIR/checluster.yaml"

log_success "CheCluster CR created"
echo

#######################################
# Step 4b: Patch images for IPv6 (local registry)
#######################################
# Prevents InstallOrUpdateFailed and "Route POST:/api/kubernetes/namespace/provision not found"
# by patching CheCluster and deployments to use mirrored images.

if [ -n "$KUBECONFIG_PATH" ] && [ -f "$KUBECONFIG_PATH" ]; then
    log_info "Step 4b: Patching CheCluster and deployments for local registry (IPv6)"
    FIX_SCRIPT="${SCRIPT_DIR}/fix-image-pulls.sh"
    FIX_CMD=("$FIX_SCRIPT" --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE")
    [ -n "$CHE_SERVER_IMAGE" ] && FIX_CMD+=(--server-image "${CHE_SERVER_IMAGE##*:}")
    [ -n "$DASHBOARD_IMAGE" ] && FIX_CMD+=(--dashboard-image "${DASHBOARD_IMAGE##*:}")
    if [ -x "$FIX_SCRIPT" ]; then
        if "${FIX_CMD[@]}" 2>/dev/null; then
            log_success "Image patches applied"
        else
            log_warn "fix-image-pulls failed (non-fatal). Che may show InstallOrUpdateFailed."
        fi
    else
        log_warn "fix-image-pulls.sh not found. Run it manually if che-server does not deploy."
    fi
    echo
fi

#######################################
# Step 5: Wait for Che Components
#######################################

log_info "Step 5: Waiting for Eclipse Che components to be ready..."
log_info "This may take several minutes..."
echo

# Wait for CheCluster to be available
log_info "Waiting for CheCluster status..."
PROVISION_FALLBACK_RUN=false
for i in {1..60}; do
    CHE_URL=$(kubectl get checluster eclipse-che -n "$NAMESPACE" -o jsonpath='{.status.cheURL}' 2>/dev/null || echo "")
    CHE_PHASE=$(kubectl get checluster eclipse-che -n "$NAMESPACE" -o jsonpath='{.status.chePhase}' 2>/dev/null || echo "")
    CHE_REASON=$(kubectl get checluster eclipse-che -n "$NAMESPACE" -o jsonpath='{.status.reason}' 2>/dev/null || echo "")
    CHE_MESSAGE=$(kubectl get checluster eclipse-che -n "$NAMESPACE" -o jsonpath='{.status.message}' 2>/dev/null || echo "")
    CHE_SERVER_EXISTS=$(kubectl get deploy che -n "$NAMESPACE" 2>/dev/null | grep -c "che" || echo "0")

    if [ -n "$CHE_URL" ] && [ "$CHE_PHASE" = "Active" ]; then
        log_success "Eclipse Che is ready!"
        log_success "Che URL: $CHE_URL"
        break
    fi

    # Fallback: if InstallOrUpdateFailed and no che-server after ~5 min, provision manually
    if [ "$PROVISION_FALLBACK_RUN" = false ] && [ "$i" -ge 30 ] && [ "$CHE_REASON" = "InstallOrUpdateFailed" ] && [ "$CHE_SERVER_EXISTS" = "0" ]; then
        log_warn "CheCluster stuck in InstallOrUpdateFailed, che-server not deployed. Running provisioning fallback..."
        PROVISION_SCRIPT="${SCRIPT_DIR}/provision-che-server-manually.sh"
        PROVISION_CMD=("$PROVISION_SCRIPT" --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE")
        [ -n "$CHE_SERVER_IMAGE" ] && PROVISION_CMD+=(--server-image "${CHE_SERVER_IMAGE##*:}")
        if [ -x "$PROVISION_SCRIPT" ] && [ -n "$KUBECONFIG_PATH" ]; then
            if "${PROVISION_CMD[@]}" 2>/dev/null; then
                log_success "che-server provisioned manually. Namespace provisioning should work."
                CHE_URL="https://$(kubectl get route che -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")"
                break
            else
                log_warn "provision-che-server-manually failed. Run it manually if needed."
            fi
        fi
        PROVISION_FALLBACK_RUN=true
    fi

    if [ $((i % 10)) -eq 0 ]; then
        log_info "Status: ${CHE_PHASE:-Pending} - ${CHE_MESSAGE} (${i}/60)"
    fi

    sleep 10
done

# Show final status
echo
log_info "=== Deployment Summary ==="
kubectl get checluster -n "$NAMESPACE"
echo
kubectl get pods -n "$NAMESPACE"
echo

# Get Che URL
CHE_URL=$(kubectl get checluster eclipse-che -n "$NAMESPACE" -o jsonpath='{.status.cheURL}' 2>/dev/null || echo "")
if [ -n "$CHE_URL" ]; then
    echo
    log_success "=== Eclipse Che Deployed Successfully ==="
    log_success "Che URL: $CHE_URL"
    echo

    # Extract proxy information from kubeconfig
    if [ -n "$KUBECONFIG_PATH" ]; then
        PROXY_URL=$(grep proxy-url "$KUBECONFIG_PATH" 2>/dev/null | awk '{print $2}' || echo "")
        PROXY_URL="${PROXY_URL%/}"  # Remove trailing slash

        if [ -n "$PROXY_URL" ]; then
            PROXY_HOST=$(echo "$PROXY_URL" | sed 's|http://||' | sed 's|https://||' | cut -d: -f1)
            PROXY_PORT=$(echo "$PROXY_URL" | sed 's|http://||' | sed 's|https://||' | cut -d: -f2 | tr -d '/')

            log_info "=== Next Steps: Access the Dashboard ==="
            echo
            echo "The cluster is only accessible via proxy from the kubeconfig:"
            echo "  Proxy: $PROXY_URL"
            echo
            echo "Step 1: Launch Google Chrome with proxy (2>/dev/null suppresses stderr):"
            echo "  (--ignore-certificate-errors required for ostest self-signed cert)"
            echo
            echo "  macOS:"
            echo "    /Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome \\"
            echo "      --proxy-server=\"${PROXY_HOST}:${PROXY_PORT}\" \\"
            echo "      --ignore-certificate-errors \\"
            echo "      --user-data-dir=\"/tmp/chrome-che-\$(date +%s)\" \\"
            echo "      --no-first-run \\"
            echo "      \"${CHE_URL}/dashboard/\" 2>/dev/null"
            echo
            echo "  Linux:"
            echo "    google-chrome \\"
            echo "      --proxy-server=\"${PROXY_HOST}:${PROXY_PORT}\" \\"
            echo "      --ignore-certificate-errors \\"
            echo "      --user-data-dir=\"/tmp/chrome-che-\$(date +%s)\" \\"
            echo "      --no-first-run \\"
            echo "      \"${CHE_URL}/dashboard/\" 2>/dev/null"
            echo
            echo "Step 2: Login with OpenShift credentials"
            echo "  (Use the kubeadmin credentials from cluster-bot)"
            echo
        else
            log_warn "No proxy-url found in kubeconfig"
            log_info "To access the dashboard, navigate to: ${CHE_URL}/dashboard/"
        fi
    else
        log_info "To access the dashboard, navigate to: ${CHE_URL}/dashboard/"
    fi
else
    log_warn "Che URL not yet available. Check status with:"
    echo "  kubectl get checluster -n $NAMESPACE -w"
fi

echo
log_info "=== Additional Commands ==="
echo "To check operator logs:"
echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=che-operator -f"
echo
echo "To check CheCluster status:"
echo "  kubectl describe checluster eclipse-che -n $NAMESPACE"
echo
echo "To get Che URL later:"
echo "  kubectl get checluster eclipse-che -n $NAMESPACE -o jsonpath='{.status.cheURL}'"
