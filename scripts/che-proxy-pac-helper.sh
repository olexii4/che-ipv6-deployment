#!/bin/bash
#
# Copyright (c) 2025-2026 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Generate PAC file and Chrome launch command for ostest cluster access.
# PAC proxies only cluster hostnames (*.ostest.test.metalkube.org), so
# Chrome's Google traffic (GCM, sync) goes DIRECT and doesn't fail.
#
# Usage:
#   ./scripts/che-proxy-pac-helper.sh [--kubeconfig ~/ostest-kubeconfig.yaml]
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

KUBECONFIG_FILE="${KUBECONFIG:-$HOME/ostest-kubeconfig.yaml}"
while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ ! -f "$KUBECONFIG_FILE" ]; then
  echo "Error: kubeconfig not found: $KUBECONFIG_FILE"
  exit 1
fi

PROXY_URL=$(grep -m1 'proxy-url:' "$KUBECONFIG_FILE" 2>/dev/null | awk '{print $2}' || true)
if [ -z "$PROXY_URL" ]; then
  echo "Error: No proxy-url in kubeconfig"
  exit 1
fi

# Remove trailing slash
PROXY_URL="${PROXY_URL%/}"
# Extract host:port for PAC (PAC format is "PROXY host:port")
PROXY_HOSTPORT=$(echo "$PROXY_URL" | sed 's|http://||' | sed 's|https://||' | sed 's|/$||')

PAC_FILE="/tmp/che-proxy.pac"
cat > "$PAC_FILE" << PAC
function FindProxyForURL(url, host) {
  // Proxy only cluster hostnames; everything else (including Google) goes DIRECT
  if (shExpMatch(host, "*.ostest.test.metalkube.org") || host == "ostest.test.metalkube.org") {
    return "PROXY ${PROXY_HOSTPORT}";
  }
  return "DIRECT";
}
PAC

echo "Created PAC file: $PAC_FILE"
echo ""
echo "Step 1: Launch Chrome with proxy (2>/dev/null suppresses stderr noise):"
echo "  (--ignore-certificate-errors required for ostest self-signed cert)"
echo ""
echo "  /Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome \\"
echo "    --proxy-server=\"$PROXY_HOSTPORT\" \\"
echo "    --ignore-certificate-errors \\"
echo "    --user-data-dir=\"/tmp/chrome-che-\$(date +%s)\" \\"
echo "    --no-first-run \\"
echo "    \"\${CHE_URL:-https://eclipse-che.apps.ostest.test.metalkube.org}/dashboard/\" 2>/dev/null"
echo ""
echo "Or use PAC (proxy only for cluster): --proxy-pac-url=\"file://$PAC_FILE\""
echo ""
echo "Proxy: $PROXY_URL"
echo ""
