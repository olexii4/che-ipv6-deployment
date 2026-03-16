<!--
Copyright (c) 2025-2026 Red Hat, Inc.
This program and the accompanying materials are made
available under the terms of the Eclipse Public License 2.0
which is available at https://www.eclipse.org/legal/epl-2.0/

SPDX-License-Identifier: EPL-2.0
-->

# Deploy Eclipse Che with IPv6 Support

This repository contains scripts for deploying Eclipse Che on IPv6-only OpenShift clusters.

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
- In `--mode full`, mirrors images from air-gap samples (`manifests/che/air-gap-samples.json`); run `prepare-airgap-from-samples.sh` first if `build/air-gap/` is missing
- Detects the local registry from cluster (`virthost.ostest.test.metalkube.org:5000`)
- Automatically extracts gateway (traefik) image from Che operator bundle
- Pulls all Che images locally (uses cache for faster re-runs)
- Pushes images to the cluster's local registry via proxy
- Applies ImageTagMirrorSet / ImageDigestMirrorSet (OCP 4.12+) plus legacy ICSP for backward compatibility, redirecting image pulls from:
  - quay.io/eclipse → local registry
  - quay.io/devfile → local registry
  - quay.io/che-incubator → local registry
  - docker.io/library → local registry (for test infrastructure)
  - docker.io/alpine → local registry (for test infrastructure)
  - registry.access.redhat.com → local registry (Node.js, Python devfiles in test-infrastructure)
- Each `skopeo copy` is guarded by a per-image timeout (`SKOPEO_TIMEOUT_SECONDS`, default 900s) to avoid hangs
- **Waits for cluster nodes to reboot** (~10-15 minutes)

**Options:**
```
--kubeconfig <path>         Path to kubeconfig file (required unless --prefetch-only)
--dashboard-image <image>   Dashboard image (shortcuts: pr-XXXX, next, latest)
--server-image <image>      Che server image (shortcuts: pr-XXXX, next, latest)
--mode <minimal|full>       Image set: minimal (Che only) or full (includes DevWorkspace)
--parallel <N>              Concurrent image copies (default: 1, recommended: 4)
--prefetch-only             Populate local OCI cache only, no cluster access needed
--dry-run                   Show what would be mirrored without executing
--registry <host:port>      Override local registry (default: auto-detect from cluster)
```

**After mirroring completes:**
- All images are available in the local registry
- Cluster nodes are configured to pull from the mirror (via ITMS/IDMS + ICSP)
- You can proceed to the next step

**Note:** The cluster is accessible only via the HTTP proxy specified in the kubeconfig (`proxy-url` field). All `oc`/`kubectl` commands automatically use it.

### 3. Deploy Eclipse Che

**Deploy using manual operator installation (bypasses OLM catalog networking issues):**

```bash
# Deploy Eclipse Che (with air-gap samples and devfile HTTP server)
./scripts/deploy-che-from-bundles.sh \
  --kubeconfig ~/ostest-kubeconfig.yaml \
  --dashboard-image pr-1442 \
  --server-image pr-951 \
  --airgap-samples \
  --deploy-devfile-server \
  --namespace eclipse-che
```

**What the script does:**
- Extracts manifests directly from OLM bundle images (bypasses catalog networking)
- Deploys DevWorkspace Operator with all required CRDs
- Generates webhook TLS certificates for operator security
- Creates leader election RBAC for high availability
- Deploys Che Operator with all required resources
- Creates CheCluster custom resource with custom dashboard image
- Deploys Eclipse Che first (with ConfigMap/GitHub URLs for samples)
- Patches images for local registry (fix-image-pulls) - prevents ImagePullBackOff
- Fixes OAuth redirect URI mismatch (fix-oauth-redirect) - prevents login errors
- Re-patches DevWorkspace webhook after delay - ensures workspace creation works
- Runs `ensure-deployment-ready` — patches workspace SCC (anyuid), `DevWorkspaceOperatorConfig` (`runAsNonRoot: false`), and workspace Deployments (`che-gateway runAsNonRoot: false` since Traefik runs as root); verifies login and workspace creation will work
- Adds air-gap samples Secret **after** Che is ready (`--airgap-samples`) - avoids reconcile loop during deploy
- Optionally deploys devfile HTTP server (`--deploy-devfile-server`) - serves Node.js and Python devfiles over IPv6
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
--airgap-samples                 Enable air-gap samples (added after Che deploys)
--no-airgap-samples              Disable air-gap samples (default, matches chectl behavior)
--deploy-devfile-server         Deploy devfile HTTP server for IPv6 testing (Node.js, Python)
```

**Air-gap samples:** Disabled by default (`--no-airgap-samples`). Use `--airgap-samples` to enable—samples are added **after** Che deploys (avoids reconcile loop). Algorithm: deploy Che first with ConfigMap (GitHub URLs), then add air-gap Secret once Che is ready; samples run without proxy.

**After deployment completes, the script will show:**
- ✅ Che URL (e.g., `https://eclipse-che-eclipse-che.apps.ostest...`)
- ✅ Proxy information extracted from kubeconfig (`proxy-url` key)
- ✅ Chrome launch commands for macOS and Linux
- ✅ Step-by-step instructions to access the dashboard

### 4. Access Eclipse Che Dashboard

**The deployment script automatically shows you what to do next!**

When deployment completes successfully, you'll see output like this:

```
=== Eclipse Che Deployed Successfully ===
Che URL: https://eclipse-che.apps.ostest.test.metalkube.org

=== Next Steps: Access the Dashboard ===

The cluster is only accessible via proxy from the kubeconfig.
Run this in your terminal (replace ~/ostest-kubeconfig.yaml with your kubeconfig path):

  macOS:
    PROXY=$(grep -m1 "proxy-url:" ~/ostest-kubeconfig.yaml | awk '{print $2}' | sed -E 's|^https?://||;s|/$||')
    /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
      --proxy-server="$PROXY" \
      --ignore-certificate-errors \
      --user-data-dir="/tmp/chrome-ostest-$(date +%s)" \
      --no-first-run \
      "https://eclipse-che.apps.ostest.test.metalkube.org/dashboard/" 2>/dev/null

  Linux:
    PROXY=$(grep -m1 "proxy-url:" ~/ostest-kubeconfig.yaml | awk '{print $2}' | sed -E 's|^https?://||;s|/$||')
    google-chrome \
      --proxy-server="$PROXY" \
      --ignore-certificate-errors \
      --user-data-dir="/tmp/chrome-ostest-$(date +%s)" \
      --no-first-run \
      "https://eclipse-che.apps.ostest.test.metalkube.org/dashboard/" 2>/dev/null

Step 2: Login with OpenShift credentials
  (Use the kubeadmin credentials from cluster-bot)
```

**Note:** The Che URL may vary (e.g. `eclipse-che-eclipse-che.apps...` on some installs). Use the exact URL from the deployment output.

**Simply copy and paste the commands shown in the output!**

The script automatically:
- ✅ Extracts the proxy from your kubeconfig
- ✅ Shows the correct Chrome launch command for your OS
- ✅ Provides the exact Che URL to open
- ✅ Gives you step-by-step instructions

### 5. Test Devfiles (IPv6)

Deploy the devfile HTTP server to test Che Dashboard's IPv6 URL support (POST `/dashboard/api/data/resolver`). Devfiles are pre-saved in `manifests/test-infrastructure/` and their images are mirrored in `--mode full`.

```bash
# Deploy devfile server (serves Node.js and Python devfiles over IPv6)
./scripts/test-ipv6-validation.sh --kubeconfig ~/ostest-kubeconfig.yaml
```

After deployment, the script prints the test URLs. Test via Swagger (POST `/dashboard/api/data/resolver`):

```
Test Node.js devfile:
{"url": "http://[fd02::3823]:8080/nodejs/devfile.yaml"}

Test Python devfile:
{"url": "http://[fd02::3823]:8080/python/devfile.yaml"}
```

**Note:** The IPv6 address is the devfile-server ClusterIP in `che-test` namespace. Get it with:
`oc get svc devfile-server -n che-test -o jsonpath='{.spec.clusterIPs[0]}'`

**Images:** Node.js and Python devfiles use `registry.access.redhat.com/ubi8/nodejs-18` and `ubi8/python-39`. On IPv6-only clusters, mirror them first:
```bash
./scripts/mirror-images-to-registry.sh --kubeconfig ~/ostest-kubeconfig.yaml --mode full
```

**Cleanup:** `./scripts/test-ipv6-validation.sh --kubeconfig ~/ostest-kubeconfig.yaml --cleanup`

## Test Scenarios

### Served air-gap files

The dashboard serves these sample files at `/public/dashboard/devfile-registry/air-gap/`:

- `index.json` — sample catalog
- `*-devfile.yaml` — devfiles (e.g. `python-hello-world-devfile.yaml`, `web-nodejs-sample-devfile.yaml`, `php-hello-world-devfile.yaml`, `dotnet-web-simple-devfile.yaml`, `golang-health-check-devfile.yaml`, `lombok-project-sample-devfile.yaml`, `ansible-devspaces-demo-devfile.yaml`)
- `*.zip` — project archives

### Test with Air-Gap Samples

Air-gap samples are served by the dashboard and work without network access. Use the Getting Started page to create workspaces.

## Documentation

- [How it works](docs/how-it-works.md) - Deployment method and bundle flow
- [Repository contents](docs/repository-contents.md) - Scripts reference
- [Troubleshooting](docs/troubleshooting.md) - Common issues and fixes

## Expected Results

- ✅ Deployment succeeds; Che dashboard and che-server are ready
- ✅ Air-gap samples work via Getting Started
- ✅ Workspaces can be created from served devfiles:
  - Air-gap samples at `/dashboard/api/airgap-sample/*`
  - IPv6 devfile server: `http://[fd02::3823]:8080/nodejs/devfile.yaml` and `http://[fd02::3823]:8080/python/devfile.yaml` (deploy with `./scripts/test-ipv6-validation.sh`; get IP via `oc get svc devfile-server -n che-test -o jsonpath='{.spec.clusterIPs[0]}'`)

## License

This project is licensed under the Eclipse Public License 2.0. See [LICENSE](LICENSE) for details.
