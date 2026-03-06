#!/bin/bash
#
# Patch CheCluster with cheServer.proxy from kubeconfig so factory resolver
# can reach external devfile URLs (fixes "Could not reach devfile at Network is unreachable").
# In-cluster devfile server (devfile-server.che-test.svc) is in nonProxyHosts.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE=""
NAMESPACE="eclipse-che"

while [[ $# -gt 0 ]]; do
    case $1 in
        --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        *) echo "Usage: $0 --kubeconfig <path> [--namespace eclipse-che]"; exit 1 ;;
    esac
done

if [ -z "$KUBECONFIG_FILE" ] || [ ! -f "$KUBECONFIG_FILE" ]; then
    echo "Usage: $0 --kubeconfig <path> [--namespace eclipse-che]"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG_FILE"

# Get proxy from cluster first, then kubeconfig
PROXY_URL=$(oc get proxy cluster -o jsonpath='{.spec.httpProxy}' 2>/dev/null || oc get proxy cluster -o jsonpath='{.spec.httpsProxy}' 2>/dev/null || true)
if [ -z "$PROXY_URL" ]; then
    PROXY_URL=$(grep -m1 'proxy-url:' "$KUBECONFIG_FILE" 2>/dev/null | awk '{print $2}' | sed 's|/$||' || true)
fi

if [ -z "$PROXY_URL" ]; then
    echo "No proxy found in cluster Proxy CR or kubeconfig"
    exit 1
fi

PROXY_URL="${PROXY_URL%/}"
PROXY_BASE=$(echo "$PROXY_URL" | sed -E 's|^https?://||' | sed -E 's/:([0-9]+)\/?$//')
PROXY_PORT=$(echo "$PROXY_URL" | sed -En 's/.*:([0-9]+)\/?$/\1/p')
[ -z "$PROXY_PORT" ] && PROXY_PORT="8213"

PATCH_FILE=$(mktemp)
cat > "$PATCH_FILE" << EOF
spec:
  components:
    cheServer:
      proxy:
        url: ${PROXY_BASE}
        port: "${PROXY_PORT}"
        nonProxyHosts:
          - localhost
          - "127.0.0.1"
          - ".cluster.local"
          - ".svc"
          - ".metalkube.org"
          - "virthost.ostest.test.metalkube.org"
          - "fd02::/112"
          - "devfile-server.che-test.svc"
EOF

echo "Patching CheCluster with cheServer.proxy: ${PROXY_BASE}:${PROXY_PORT}"
oc patch checluster eclipse-che -n "$NAMESPACE" --type=merge --patch-file="$PATCH_FILE"
rm -f "$PATCH_FILE"

echo "Restarting che-server to pick up proxy..."
if oc get deploy che -n "$NAMESPACE" &>/dev/null; then
    oc rollout restart deploy/che -n "$NAMESPACE"
else
    oc delete pod -n "$NAMESPACE" -l 'app.kubernetes.io/name=che' --ignore-not-found=true --wait=false 2>/dev/null || true
fi

echo ""
echo "Done. For in-cluster devfile server, use:"
echo "  http://devfile-server.che-test.svc.cluster.local:8080/nodejs/devfile.yaml"
echo "  http://devfile-server.che-test.svc.cluster.local:8080/python/devfile.yaml"
