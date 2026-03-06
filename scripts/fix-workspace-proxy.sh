#!/bin/bash
#
# Patch DevWorkspaceOperatorConfig (devworkspace-config) with proxyConfig from kubeconfig.
# Workspace pods need HTTP_PROXY to reach open-vsx.org (fixes FailedPostStartHook).
# Che operator overwrites this; run periodically or after creating a new workspace.
#
set -e

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

PROXY_URL=$(oc get proxy cluster -o jsonpath='{.spec.httpProxy}' 2>/dev/null || true)
[ -z "$PROXY_URL" ] && PROXY_URL=$(grep -m1 'proxy-url:' "$KUBECONFIG_FILE" 2>/dev/null | awk '{print $2}' | sed 's|/$||' || true)

if [ -z "$PROXY_URL" ]; then
    echo "No proxy found. Set cluster Proxy or add proxy-url to kubeconfig."
    exit 1
fi

PROXY_URL="${PROXY_URL%/}"
NO_PROXY="localhost,127.0.0.1,.cluster.local,.svc,.metalkube.org,virthost.ostest.test.metalkube.org,fd02::/112"

echo "Patching devworkspace-config with proxyConfig: $PROXY_URL"
oc patch devworkspaceoperatorconfig devworkspace-config -n "$NAMESPACE" --type=merge -p "{
  \"config\": {
    \"routing\": {
      \"proxyConfig\": {
        \"httpProxy\": \"${PROXY_URL}/\",
        \"httpsProxy\": \"${PROXY_URL}/\",
        \"noProxy\": \"${NO_PROXY}\"
      }
    }
  }
}" 2>/dev/null && echo "Done. Delete failed workspace and create new one." || echo "Patch failed (Che may have reverted)."
