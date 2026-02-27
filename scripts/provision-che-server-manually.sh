#!/bin/bash
#
# Copyright (c) 2025-2026 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Manually provision che-server when the operator fails to create it.
# Use as a workaround for InstallOrUpdateFailed / "Route POST:/api/kubernetes/namespace/provision not found"
#
# Prerequisites: che-dashboard, che-gateway, che-host service, ca-certs-merged, self-signed-certificate exist
#
# Usage: ./provision-che-server-manually.sh --kubeconfig <path> [--namespace <ns>] [--server-image <tag>]
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG_FILE=""
NAMESPACE="eclipse-che"
REGISTRY="virthost.ostest.test.metalkube.org:5000"
SERVER_IMAGE="pr-951"

while [[ $# -gt 0 ]]; do
    case $1 in
        --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --server-image) SERVER_IMAGE="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [ -z "$KUBECONFIG_FILE" ] || [ ! -f "$KUBECONFIG_FILE" ]; then
    echo "Usage: $0 --kubeconfig <path> [--namespace eclipse-che] [--server-image pr-951]"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG_FILE"
NS="$NAMESPACE"

# Auto-detect CHE_HOST from route 'che' in namespace
if [ -z "${CHE_HOST:-}" ]; then
    CHE_HOST=$(oc get route che -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
fi
CHE_HOST="${CHE_HOST:-eclipse-che.apps.ostest.test.metalkube.org}"

echo "Provisioning che-server in $NS (CHE_HOST=$CHE_HOST)"

# Skip if che-server already deployed
if oc get deploy che -n "$NS" &>/dev/null && [ "$(oc get deploy che -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ]; then
    echo "che-server already running. Skipping."
    exit 0
fi

# Ensure che ServiceAccount exists
oc create serviceaccount che -n "$NS" 2>/dev/null || true

# Create che ConfigMap with minimal required env for che-server
oc create configmap che -n "$NS" --from-literal="CHE_HOST=${CHE_HOST}" \
    --from-literal="CHE_PORT=8080" \
    --from-literal="CHE_API=https://${CHE_HOST}/api" \
    --from-literal="CHE_API_INTERNAL=http://che-host.${NS}.svc:8080/api" \
    --from-literal="CHE_WEBSOCKET_ENDPOINT=wss://${CHE_HOST}/api/websocket" \
    --from-literal="CHE_WEBSOCKET_INTERNAL_ENDPOINT=ws://che-host.${NS}.svc:8080/api/websocket" \
    --from-literal="CHE_MULTIUSER=true" \
    --from-literal="CHE_INFRASTRUCTURE_ACTIVE=openshift" \
    --from-literal="CHE_INFRA_OPENSHIFT_OAUTH__IDENTITY__PROVIDER=openshift-v4" \
    --from-literal="CHE_INFRA_KUBERNETES_NAMESPACE_DEFAULT=<username>-che" \
    --from-literal="CHE_INFRA_KUBERNETES_NAMESPACE_CREATION__ALLOWED=true" \
    --from-literal="CHE_INFRA_KUBERNETES_PVC_STRATEGY=per-user" \
    --from-literal="CHE_INFRA_OPENSHIFT_TLS__ENABLED=true" \
    --from-literal="CHE_INFRA_KUBERNETES_TRUST__CERTS=true" \
    --from-literal="CHE_LOG_LEVEL=INFO" \
    --from-literal="CHE_WORKSPACE_PLUGIN__REGISTRY__URL=https://open-vsx.org" \
    --from-literal="CHE_TRUSTED__CA__BUNDLES__CONFIGMAP=ca-certs-merged" \
    --from-literal="CHE_INFRA_KUBERNETES_SERVER__STRATEGY=single-host" \
    --from-literal="CHE_INFRA_KUBERNETES_SINGLEHOST_WORKSPACE_EXPOSURE=gateway" \
    --from-literal="CHE_INFRA_KUBERNETES_SINGLEHOST_GATEWAY_CONFIGMAP__LABELS=app=che,component=che-gateway-config" \
    --from-literal="CHE_DEVWORKSPACES_ENABLED=true" \
    --from-literal="HTTP2_DISABLE=true" \
    --from-literal="CHE_AUTH_NATIVEUSER=true" \
    --dry-run=client -o yaml | oc apply -f -

# Create che (che-server) Deployment
CHE_IMAGE="${REGISTRY}/eclipse-che/eclipse/che-server:${SERVER_IMAGE}"
oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: che
  namespace: ${NS}
  labels:
    app: che
    app.kubernetes.io/component: che
    app.kubernetes.io/instance: che
    app.kubernetes.io/managed-by: che-operator
    app.kubernetes.io/name: che
    app.kubernetes.io/part-of: che.eclipse.org
    component: che
spec:
  replicas: 1
  selector:
    matchLabels:
      app: che
      component: che
  template:
    metadata:
      labels:
        app: che
        app.kubernetes.io/component: che
        app.kubernetes.io/instance: che
        app.kubernetes.io/managed-by: che-operator
        app.kubernetes.io/name: che
        app.kubernetes.io/part-of: che.eclipse.org
        component: che
    spec:
      serviceAccountName: che
      volumes:
      - name: che-public-certs
        configMap:
          name: ca-certs-merged
      - name: che-self-signed-cert
        secret:
          secretName: self-signed-certificate
      containers:
      - name: che-server
        image: ${CHE_IMAGE}
        imagePullPolicy: Always
        ports:
        - name: http
          containerPort: 8080
        - name: http-debug
          containerPort: 8000
        - name: jgroups-ping
          containerPort: 8888
        env:
        - name: KUBERNETES_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: CHE_AUTH_NATIVEUSER
          value: "true"
        envFrom:
        - configMapRef:
            name: che
        volumeMounts:
        - name: che-public-certs
          mountPath: /public-certs
        - name: che-self-signed-cert
          mountPath: /self-signed-cert
        readinessProbe:
          httpGet:
            path: /api/system/state
            port: 8080
          initialDelaySeconds: 25
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /api/system/state
            port: 8080
          initialDelaySeconds: 140
          periodSeconds: 15
EOF

echo "Waiting for che-server pod..."
oc rollout status deployment/che -n "$NS" --timeout=120s

echo "Done. che-server should now serve POST /api/kubernetes/namespace/provision"
