<!--
Copyright (c) 2025-2026 Red Hat, Inc.
This program and the accompanying materials are made
available under the terms of the Eclipse Public License 2.0
which is available at https://www.eclipse.org/legal/epl-2.0/

SPDX-License-Identifier: EPL-2.0
-->

# Deploy Eclipse Che with IPv6 Support

This repository contains scripts for deploying Eclipse Che on IPv6-only OpenShift clusters. Testing uses **devfile samples** (air-gap).

### 1. Provision OpenShift Cluster with IPv6

Use the OpenShift CI cluster bot to provision an IPv6-enabled cluster:

```bash
launch 4.20.2 metal,ipv6
```

Save the kubeconfig provided by cluster bot:

```bash
# Save kubeconfig to file
cat > ~/ostest-kubeconfig.yaml << 'EOF'
# Paste the kubeconfig content from cluster bot here
EOF
```

### 2. Mirror Images to Local Registry

**IMPORTANT:** IPv6-only clusters cannot pull images from external registries. You must mirror all required images to the cluster's local registry first.

```bash
# Clone this repository
git clone https://github.com/olexii4/che-ipv6-deployment.git
cd che-ipv6-deployment

# Preload images to local cache (optional, no cluster access needed)
./scripts/mirror-images-to-registry.sh \
  --dashboard-image pr-1442 \
  --server-image pr-951 \
  --mode full \
  --prefetch-only \
  --parallel 4

# Mirror all Eclipse Che images to local registry
./scripts/mirror-images-to-registry.sh \
  --kubeconfig ~/ostest-kubeconfig.yaml \
  --dashboard-image pr-1442 \
  --server-image pr-951 \
  --mode full \
  --parallel 4
```

**What the mirror script does:**
- Detects the local registry from cluster (`virthost.ostest.test.metalkube.org:5000`)
- Automatically extracts gateway (traefik) image from Che operator bundle
- Pulls all Che images locally (uses cache for faster re-runs)
- Pushes images to the cluster's local registry via proxy
- Creates ImageContentSourcePolicy to redirect image pulls from:
  - quay.io/eclipse → local registry
  - quay.io/devfile → local registry
  - quay.io/che-incubator → local registry
  - docker.io/library → local registry (for test infrastructure)
  - docker.io/alpine → local registry (for test infrastructure)
- **Waits for cluster nodes to reboot** (~10-15 minutes)

**Options:**
```
--kubeconfig <path>         Path to kubeconfig file (required)
--dashboard-image <image>   Dashboard image (shortcuts: pr-XXXX, next, latest)
--server-image <image>      Che server image (shortcuts: pr-XXXX, next, latest)
--mode <minimal|full>       Image set: minimal (Che only) or full (includes DevWorkspace)
--parallel <N>              Concurrent image copies (default: 1, recommended: 4)
```

**After mirroring completes:**
- All images are available in the local registry
- Cluster nodes are configured to pull from the mirror
- You can proceed to the next step

### 3. Deploy Eclipse Che

**Deploy using manual operator installation (bypasses OLM catalog networking issues):**

```bash
# Deploy Eclipse Che
./scripts/deploy-che-from-bundles.sh \
  --kubeconfig ~/ostest-kubeconfig.yaml \
  --dashboard-image pr-1442 \
  --server-image pr-951 \
  --namespace eclipse-che
```

**What the script does:**
- Extracts manifests directly from OLM bundle images (bypasses catalog networking)
- Deploys DevWorkspace Operator with all required CRDs
- Generates webhook TLS certificates for operator security
- Creates leader election RBAC for high availability
- Deploys Che Operator with all required resources
- Creates CheCluster custom resource with custom dashboard image
- Waits for all components to be ready

**Options:**
```
--kubeconfig <path>              Path to kubeconfig file (required)
--namespace <name>               Namespace for Eclipse Che (default: eclipse-che)
--dashboard-image <image>        Dashboard image (shortcuts: pr-XXXX, next, latest)
--server-image <image>           Che server container image (shortcuts: pr-XXXX, next, latest)
--che-server-image <image>       Same as --server-image
--skip-devworkspace              Skip DevWorkspace Operator installation
--devworkspace-bundle <image>    DevWorkspace bundle image
--che-bundle <image>             Che bundle image
```

**Air-gap samples (default):** The deploy script prepares samples (index, devfiles, \*.zip) and mounts them into the dashboard via a Secret. Samples then run **without proxy**—the dashboard serves them from `/dashboard/api/airgap-sample/*`. Requires network during deploy (for git clone). Disable with `--no-airgap-samples`.

**After deployment completes, the script will show:**
- ✅ Che URL (e.g., `https://eclipse-che-eclipse-che.apps.ostest...`)
- ✅ Proxy information extracted from kubeconfig (`proxy-url` key)
- ✅ Chrome launch commands for macOS and Linux
- ✅ Step-by-step instructions to access the dashboard

### 4. Access Eclipse Che Dashboard

**The deployment script automatically shows you what to do next!**

When deployment completes successfully, you'll see output like this (proxy IP:port and Che URL come from your kubeconfig and cluster):

```
=== Eclipse Che Deployed Successfully ===
Che URL: https://eclipse-che-eclipse-che.apps.ostest.test.metalkube.org

=== Next Steps: Access the Dashboard ===

The cluster is only accessible via proxy from the kubeconfig:
  Proxy: http://<proxy-host>:<proxy-port>

Step 1: Launch Google Chrome with proxy (ostest uses self-signed cert, so --ignore-certificate-errors is required)

  macOS:
    /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
      --proxy-server="<proxy-host>:<proxy-port>" \
      --ignore-certificate-errors \
      --user-data-dir="/tmp/chrome-che-$(date +%s)" \
      --no-first-run

  Linux:
    google-chrome \
      --proxy-server="<proxy-host>:<proxy-port>" \
      --ignore-certificate-errors \
      --user-data-dir="/tmp/chrome-che-$(date +%s)" \
      --no-first-run

Step 2: Open Che Dashboard in the proxied Chrome:
  <CHE_URL>/dashboard/

Step 3: Login with OpenShift credentials
  (Use the kubeadmin credentials from cluster-bot)
```

**Simply copy and paste the commands shown in the output!**

The script automatically:
- ✅ Extracts the proxy from your kubeconfig
- ✅ Shows the correct Chrome launch command for your OS
- ✅ Provides the exact Che URL to open
- ✅ Gives you step-by-step instructions

**Alternative: Manual proxy configuration**

If you prefer to use a browser extension instead:

1. Install "Proxy Switcher and Manager" extension in Chrome
2. Configure HTTP proxy using the IP and port shown in the deployment output
   - Example: `<proxy-host>:<proxy-port>` (from `proxy-url` in kubeconfig)
3. Enable the proxy
4. Navigate to the Che URL shown in the output

**Note:** Some Chrome versions (e.g. 145+) may have issues with `--proxy-server`. If the proxy does not work, try configuring the proxy in **macOS System Settings → Network → Wi‑Fi → Details → Proxies** instead.

### 5. Test Infrastructure (Removed)

Use air-gap samples from the Che dashboard Getting Started for validation.

To remove the `che-test` namespace if it was deployed previously:

```bash
./scripts/test-ipv6-validation.sh --kubeconfig ~/ostest-kubeconfig.yaml --cleanup
```

## Test Scenarios

### Served air-gap files

The dashboard serves these sample files at `/public/dashboard/devfile-registry/air-gap/`:

- `index.json` — sample catalog
- `*-devfile.yaml` — devfiles (e.g. `python-hello-world-devfile.yaml`, `web-nodejs-sample-devfile.yaml`, `php-hello-world-devfile.yaml`, `dotnet-web-simple-devfile.yaml`, `golang-health-check-devfile.yaml`, `lombok-project-sample-devfile.yaml`, `ansible-devspaces-demo-devfile.yaml`)
- `*.zip` — project archives

### Factory URL Testing

```bash
# Test factory URL with IPv6 repository
https://che-host/#http://[fd00::1]:8080/repo.git

# Test with devfile
https://che-host/#http://[fd00::1]:8080/repo.git?df=devfile.yaml
```

### Test with Air-Gap Samples

Air-gap samples are served by the dashboard and work without network access. Use the Getting Started page to create workspaces.

## Deployment Method

### Manual Operator Installation

The deployment script extracts operator manifests directly from OLM bundle images and applies them manually. This approach:

- ✅ **Bypasses OLM catalog networking issues** common in IPv6-only clusters
- ✅ **Works on clusters with broken IPv6 ClusterIP connectivity**
- ✅ **Uses official OLM bundle images** (same as OLM would use)
- ✅ **Provides direct control** over operator versions
- ✅ **Compatible with image mirroring** for disconnected environments

**How it works:**

```
1. Pull DevWorkspace Operator bundle image using podman
2. Extract manifests from bundle (/manifests directory)
3. Apply CRDs, RBAC, and Deployment directly
4. Pull Che Operator bundle image
5. Extract and apply Che Operator manifests
6. Create CheCluster CR with custom configuration
7. Wait for all components to be ready
```

**Bundle images used:**
- DevWorkspace: `quay.io/devfile/devworkspace-operator-bundle:next`
- Eclipse Che: `quay.io/eclipse/eclipse-che-openshift-opm-bundles:next`

## Repository Contents

### Scripts

- **[scripts/mirror-images-to-registry.sh](./scripts/mirror-images-to-registry.sh)** - Mirror Che images to cluster local registry
- **[scripts/deploy-che-from-bundles.sh](./scripts/deploy-che-from-bundles.sh)** - Manual operator deployment from OLM bundles (runs fix-image-pulls and provision fallback automatically)
- **[scripts/fix-image-pulls.sh](./scripts/fix-image-pulls.sh)** - Patch CheCluster and deployments to use local registry (prevents InstallOrUpdateFailed)
- **[scripts/provision-che-server-manually.sh](./scripts/provision-che-server-manually.sh)** - Fallback: provision che-server when operator fails (fixes "Route POST:/api/kubernetes/namespace/provision not found")
- **[scripts/test-ipv6-validation.sh](./scripts/test-ipv6-validation.sh)** - Cleanup test namespace
- **[scripts/che-proxy-pac-helper.sh](./scripts/che-proxy-pac-helper.sh)** - Generate PAC file and Chrome proxy command for ostest

## Troubleshooting

### Issue: Cannot access Che dashboard

**Solution:** Use HTTP proxy as described in step 5 above.

The cluster is only accessible via the proxy URL from your kubeconfig. Launch Chrome with the proxy configuration shown in the deployment output.

Port-forward access does not work for Che login due to OAuth redirect URI mismatch.

### Issue: Deployment fails with "cannot connect to catalog"

**Solution:** Use the manual deployment script `deploy-che-from-bundles.sh` which bypasses OLM catalog networking.

### Issue: "Route POST:/api/kubernetes/namespace/provision not found"

**Cause:** The `POST /api/kubernetes/namespace/provision` endpoint is provided by **che-server**, not the dashboard. This error appears when che-server is not deployed (CheCluster status `InstallOrUpdateFailed`). On IPv6 clusters, che-server often fails due to image pull issues (quay.io unreachable) or operator reconciliation conflicts (air-gap secret key order).

**Prevention:** The deploy script automatically runs `fix-image-pulls.sh` after creating the CheCluster, and if che-server is still not deployed after ~5 minutes, runs `provision-che-server-manually.sh` as a fallback.

**Manual fix (if deploy did not recover):**

1. Run `fix-image-pulls.sh` to patch CheCluster and deployments:
   ```bash
   ./scripts/fix-image-pulls.sh --kubeconfig ~/ostest-kubeconfig.yaml \
     --server-image pr-951 --dashboard-image pr-1442
   ```

2. If still failing, run `provision-che-server-manually.sh`:
   ```bash
   ./scripts/provision-che-server-manually.sh --kubeconfig ~/ostest-kubeconfig.yaml \
     --server-image pr-951
   ```

## Expected Results

- ✅ Dashboard correctly parses IPv6 URLs with square brackets
- ✅ Factory flow creates workspace from IPv6 repository URLs
- ✅ Git clone works over IPv6 network
- ✅ Workspace starts successfully with IPv6-hosted devfiles
- ✅ No URL validation errors for RFC-compliant IPv6 URLs

## Manual Testing

After deployment, you can manually test IPv6 URLs:

1. Access the Che dashboard using HTTP proxy (Chrome with --proxy-server flag)
2. Navigate to factory URL:
   ```
   https://<che-host>/#http://[fd00::1]:8080/your-repo.git
   ```
3. Verify workspace creation succeeds

## License

This project is licensed under the Eclipse Public License 2.0. See [LICENSE](LICENSE) for details.
