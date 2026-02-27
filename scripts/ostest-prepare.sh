#!/bin/bash
#
# Copyright (c) 2025-2026 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Prepare ostest cluster access: hosts, Chrome command, credentials reference.
# Run manually; hosts helper requires sudo.
#
# Usage:
#   ./scripts/ostest-prepare.sh [--kubeconfig ~/ostest-kubeconfig.yaml]
#
set -e

KUBECONFIG_FILE="${KUBECONFIG:-$HOME/ostest-kubeconfig.yaml}"
CONSOLE_URL="https://console-openshift-console.apps.ostest.test.metalkube.org"
CHE_URL="https://eclipse-che-eclipse-che.apps.ostest.test.metalkube.org"
USER="kubeadmin"
PASS="${OSTEST_PASS:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
    --password)   PASS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  echo "Error: kubeconfig not found: $KUBECONFIG_FILE"
  exit 1
fi

PROXY_URL=$(grep -m1 'proxy-url:' "$KUBECONFIG_FILE" 2>/dev/null | awk '{print $2}' || true)
if [ -z "$PROXY_URL" ]; then
  echo "Error: No proxy-url in kubeconfig"
  exit 1
fi
PROXY_HOSTPORT=$(echo "$PROXY_URL" | sed -E 's|^https?://||' | sed 's|/$||' | tr -d '\r')

echo "=========================================="
echo " ostest cluster access"
echo "=========================================="
echo ""
echo "Step 1: Launch Chrome for Console:"
echo "  /Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome \\"
echo "    --proxy-server=\"$PROXY_HOSTPORT\" \\"
echo "    --ignore-certificate-errors \\"
echo "    --user-data-dir=\"/tmp/chrome-ostest-\$(date +%s)\" \\"
echo "    --no-first-run \\"
echo "    \"$CONSOLE_URL\" 2>/dev/null"
echo ""
echo "Console: $CONSOLE_URL"
echo "Che:     $CHE_URL/dashboard/"
echo "User:    $USER"
[ -n "$PASS" ] && echo "Pass:    $PASS" || echo "Pass:    (set OSTEST_PASS or use --password)"
echo ""
echo "Credentials saved to: $HOME/ostest-access.txt"
echo ""

# Save to home (do not commit)
{
  echo "ostest cluster access"
  echo "===================="
  echo ""
  echo "Console: $CONSOLE_URL"
  echo "Che:     $CHE_URL/dashboard/"
  echo ""
  echo "Login: $USER"
  [ -n "$PASS" ] && echo "Password: $PASS" || echo "Password: (add manually)"
  echo ""
  echo "Chrome one-liner:"
  echo 'PROXY=$(grep -m1 "proxy-url:" '"$KUBECONFIG_FILE"' | awk '"'"'{print $2}'"'"' | sed '"'"'s|https\?://||;s|/$||'"'"')'
  echo '/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \'
  echo '  --proxy-server="$PROXY" \'
  echo '  --ignore-certificate-errors \'
  echo '  --user-data-dir="/tmp/chrome-ostest-$(date +%s)" \'
  echo '  --no-first-run \'
  echo "  \"$CONSOLE_URL\" 2>/dev/null"
  echo ""
  echo "Kubeconfig: $KUBECONFIG_FILE"
} > "$HOME/ostest-access.txt"
