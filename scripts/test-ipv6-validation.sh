#!/bin/bash
#
# Copyright (c) 2025-2026 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# IPv6 Test Infrastructure - Devfile Server
#
# Deploys a devfile HTTP server on IPv6-only OpenShift clusters to validate
# Eclipse Che Dashboard IPv6 URL support (POST /dashboard/api/data/resolver).
#
# Serves Node.js and Python devfiles at http://[IPv6]:8080/nodejs/devfile.yaml
# and http://[IPv6]:8080/python/devfile.yaml
#
# Prerequisites:
# - OpenShift cluster with IPv6 networking
# - oc CLI configured with cluster access
# - Eclipse Che deployed with dashboard
#
# Usage:
#   ./test-ipv6-validation.sh [options]
#
# Options:
#   --kubeconfig <file>   Path to kubeconfig file
#   --namespace <ns>     Test namespace (default: che-test)
#   --che-namespace <ns> Che namespace (default: eclipse-che)
#   --cleanup            Remove test infrastructure
#   --help               Show this help message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="che-test"
CHE_NAMESPACE="eclipse-che"
CLEANUP=false
KUBECONFIG_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --kubeconfig)
            KUBECONFIG_FILE="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --che-namespace)
            CHE_NAMESPACE="$2"
            shift 2
            ;;
        --cleanup)
            CLEANUP=true
            shift
            ;;
        --help)
            grep '^#' "$0" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [ -n "$KUBECONFIG_FILE" ]; then
    if [ ! -f "$KUBECONFIG_FILE" ]; then
        echo -e "${RED}Error: Kubeconfig file not found: $KUBECONFIG_FILE${NC}"
        exit 1
    fi
    export KUBECONFIG="$KUBECONFIG_FILE"
    echo -e "${GREEN}✓ Using kubeconfig: $KUBECONFIG_FILE${NC}"
    echo ""
fi

if [ "$CLEANUP" == "true" ]; then
    echo -e "${YELLOW}Cleaning up test infrastructure...${NC}"
    oc delete namespace ${NAMESPACE} --ignore-not-found=true
    echo -e "${GREEN}✓ Test infrastructure removed${NC}"
    exit 0
fi

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║    Deploying IPv6 Devfile Server for Che Dashboard        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}Step 1: Checking prerequisites${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
if ! command -v oc &> /dev/null; then
    echo -e "${RED}Error: oc command not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓ oc CLI found${NC}"
if ! oc whoami &> /dev/null; then
    echo -e "${RED}Error: Not logged into OpenShift cluster${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Logged into cluster as $(oc whoami)${NC}"
SERVICE_NETS_RAW="$(oc get network.config.openshift.io cluster -o jsonpath='{.status.serviceNetwork[*]}' 2>/dev/null || echo "")"
IPV6_SERVICE="$(echo "${SERVICE_NETS_RAW}" | tr ' ' '\n' | grep ':' | head -1 || true)"
if [ -z "$IPV6_SERVICE" ]; then
    echo -e "${YELLOW}⚠ Warning: Cluster may not have IPv6 networking${NC}"
else
    echo -e "${GREEN}✓ Cluster has IPv6: ${IPV6_SERVICE}${NC}"
fi
echo ""

echo -e "${YELLOW}Step 2: Creating test namespace${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
oc create namespace ${NAMESPACE} --dry-run=client -o yaml | oc apply -f -
echo -e "${GREEN}✓ Namespace ${NAMESPACE} ready${NC}"
echo ""

echo -e "${YELLOW}Step 3: Creating sample devfiles${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
export NAMESPACE
envsubst '${NAMESPACE}' < "${MANIFEST_DIR}/test-infrastructure/devfile-configmaps.yaml" | oc apply -f -
echo -e "${GREEN}✓ Sample devfiles created${NC}"
echo ""

echo -e "${YELLOW}Step 4: Deploying devfile HTTP server${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
export DEVFILE_URL=""
# Use mirrored image on IPv6 clusters (nodes may not have applied redirect yet)
LOCAL_REGISTRY=$(oc get imagetagmirrorset -o jsonpath='{.items[0].spec.imageTagMirrors[0].mirrors[0]}' 2>/dev/null | sed 's|/.*||' || oc get imagecontentsourcepolicy -o jsonpath='{.items[0].spec.repositoryDigestMirrors[0].mirrors[0]}' 2>/dev/null | sed 's|/.*||' || true)
if [ -n "$LOCAL_REGISTRY" ]; then
    export DEVFILE_SERVER_IMAGE="${LOCAL_REGISTRY}/eclipse-che/library/python:3.11-alpine"
    echo -e "${GREEN}Using mirrored image: ${DEVFILE_SERVER_IMAGE}${NC}"
else
    export DEVFILE_SERVER_IMAGE="docker.io/library/python:3.11-alpine"
fi
envsubst '${NAMESPACE} ${DEVFILE_URL} ${DEVFILE_SERVER_IMAGE}' < "${MANIFEST_DIR}/test-infrastructure/devfile-server.yaml" | oc apply -f -
echo -e "${GREEN}✓ Devfile server deployed${NC}"
echo ""

echo -e "${YELLOW}Step 5: Waiting for devfile server${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
if ! oc rollout status deployment/devfile-server -n ${NAMESPACE} --timeout=120s 2>&1; then
    echo -e "${RED}Devfile server deployment failed${NC}"
    oc get pods -n ${NAMESPACE} -l app=devfile-server -o wide 2>/dev/null || true
    exit 1
fi
echo -e "${GREEN}✓ Devfile server ready${NC}"
echo ""

echo -e "${YELLOW}Step 6: Retrieving service info${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
DEVFILE_IPV6=$(oc get service devfile-server -n ${NAMESPACE} -o jsonpath='{.spec.clusterIPs[0]}')
DEVFILE_DNS="http://devfile-server.${NAMESPACE}.svc.cluster.local:8080"
echo -e "${BLUE}Devfile Server:${NC}"
echo "  Node.js: ${DEVFILE_DNS}/nodejs/devfile.yaml"
echo "  Python:  ${DEVFILE_DNS}/python/devfile.yaml"
echo ""
echo -e "${YELLOW}For factory resolver (che-server fetches devfile): use Kubernetes DNS (not IPv6 literal):${NC}"
echo "  {\"url\": \"${DEVFILE_DNS}/nodejs/devfile.yaml\"}"
echo ""
echo -e "${BLUE}IPv6 literal (browser/dashboard from outside):${NC}"
echo "  http://[${DEVFILE_IPV6}]:8080/nodejs/devfile.yaml"
echo ""

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Devfile Server Deployed Successfully!                 ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Factory resolver (POST /api/factory/resolver): use DNS URL${NC}"
echo "  {\"url\": \"${DEVFILE_DNS}/nodejs/devfile.yaml\"}"
echo ""
echo -e "${BLUE}Cleanup:${NC} ./scripts/test-ipv6-validation.sh --kubeconfig \$KUBECONFIG --cleanup"
echo ""
echo -e "${GREEN}✓ Ready for IPv6 testing${NC}"
