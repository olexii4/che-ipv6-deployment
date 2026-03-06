#!/bin/bash
#
# Monitor mirror process, check cluster every 5 min, restart mirror if cluster was down.
# When mirror finishes, run deploy-che-from-bundles.sh.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/ostest-kubeconfig.yaml}"
CHECK_INTERVAL=300  # 5 minutes

log() { echo "[$(date +%H:%M:%S)] $*"; }

mirror_running() { pgrep -f "mirror-images-to-registry.sh" >/dev/null 2>&1; }
cluster_ok() { KUBECONFIG="$KUBECONFIG" oc get nodes >/dev/null 2>&1; }

restart_mirror() {
  log "Restarting mirror..."
  cd "$REPO_DIR"
  ./scripts/mirror-images-to-registry.sh \
    --kubeconfig "$KUBECONFIG" \
    --dashboard-image pr-1442 \
    --server-image pr-951 \
    --mode full \
    --parallel 4 &
  MIRROR_PID=$!
  log "Mirror restarted (PID $MIRROR_PID)"
}

run_deploy() {
  log "Mirror finished. Running deploy..."
  cd "$REPO_DIR"
  exec ./scripts/deploy-che-from-bundles.sh \
    --kubeconfig "$KUBECONFIG" \
    --dashboard-image pr-1442 \
    --server-image pr-951 \
    --airgap-samples \
    --deploy-devfile-server \
    --namespace eclipse-che
}

log "Starting monitor (check every ${CHECK_INTERVAL}s)"
log "Will run deploy when mirror completes"

LAST_CLUSTER_OK=true
while true; do
  if mirror_running; then
    if cluster_ok; then
      LAST_CLUSTER_OK=true
      log "Cluster OK, mirror running"
    else
      log "Cluster unreachable (proxy timeout?)"
      LAST_CLUSTER_OK=false
    fi
    sleep "$CHECK_INTERVAL"
  else
    # Mirror stopped
    if ! $LAST_CLUSTER_OK; then
      log "Mirror stopped but cluster was down - restarting mirror"
      restart_mirror
      sleep 60
      continue
    fi
    log "Mirror process ended"
    run_deploy
    exit 0
  fi
done
