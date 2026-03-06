# Troubleshooting

**Quick fix:** If deploy completed but login or workspace creation fails, run:
```bash
./scripts/ensure-deployment-ready.sh --kubeconfig ~/ostest-kubeconfig.yaml
```
This re-applies OAuth and webhook fixes and verifies readiness.

## Issue: "no persistent volumes available for this claim and no storage class is set"

**Symptom:** Workspace stays in Starting; PVC `claim-devworkspace` is Pending.

**Cause:** Cluster has no StorageClass and no available PVs. ostest metal clusters often lack storage provisioning.

**Solution:** Switch Che to ephemeral storage (no PVC needed):

```bash
oc patch checluster eclipse-che -n eclipse-che --type=merge -p '{"spec":{"devEnvironments":{"storage":{"pvcStrategy":"ephemeral"}}}}'
```

Then delete the stuck workspace in the dashboard and create a new one. Ephemeral workspaces use emptyDir; data is lost when the workspace stops.

**Note:** The deploy template (`manifests/che/checluster.yaml`) now includes this by default for clusters without storage.

## Issue: "Application is not available" at Che URL

**Symptom:** The route URL (e.g. https://eclipse-che.apps.ostest.test.metalkube.org/dashboard/) returns "Application is not available".

**Cause:** The route points to `che-gateway` service, but che-gateway was never deployed (operator stuck in Pending). No pods back the route.

**Solution:** Run the gateway provision script:
```bash
./scripts/helpers/provision-che-gateway-manually.sh --kubeconfig ~/ostest-kubeconfig.yaml
```
Then retry. The deploy script now triggers this fallback automatically after ~3 minutes if che-gateway is missing.

## Issue: "Could not reach devfile at Network is unreachable" (POST /api/factory/resolver 500)

**Symptom:** Factory resolver returns 500 with `{"message":"Could not reach devfile at Network is unreachable"}` when creating a workspace from a devfile URL.

**Cause:** che-server runs in an IPv6-only cluster and cannot reach external URLs (GitHub, registry.devfile.io, raw.githubusercontent.com) without a proxy.

**Solution 1 – Add proxy:** Run the fix script to patch CheCluster with cheServer.proxy from kubeconfig:
```bash
./scripts/fix-che-server-proxy.sh --kubeconfig ~/ostest-kubeconfig.yaml
```
Then restart che-server: `oc delete pod -n eclipse-che -l app.kubernetes.io/name=che-server`

**Solution 2 – Use in-cluster devfile server:** For the devfile server deployed by `test-ipv6-validation.sh`, use the **Kubernetes DNS URL** (not the IPv6 literal) so che-server can reach it without proxy:
```
http://devfile-server.che-test.svc.cluster.local:8080/nodejs/devfile.yaml
http://devfile-server.che-test.svc.cluster.local:8080/python/devfile.yaml
```
The IPv6 literal `http://[fd02::...]:8080/...` may fail; the DNS name works from any pod in the cluster.

## Issue: Cannot access Che dashboard

**Solution:** Use HTTP proxy as described in the README (Step 4: Access Eclipse Che Dashboard). Launch Chrome with the proxy from the deployment output.

The cluster is only accessible via the proxy URL from your kubeconfig. Launch Chrome with the proxy configuration shown in the deployment output.

Port-forward access does not work for Che login due to OAuth redirect URI mismatch.

## Issue: OAuth login fails with "invalid_request" / "malformed" / "missing required parameter"

**Symptom:** After clicking login, you see:
```json
{"error":"invalid_request","error_description":"The request is missing a required parameter...","state":"..."}
```

**Cause:** Redirect URI mismatch. The Che operator may configure oauth-proxy with a different host (e.g. `che-eclipse-che.apps...`) than the actual route (`eclipse-che.apps...`). OpenShift OAuth requires exact `redirect_uri` match.

**Solution:** Run the OAuth fix script (also runs automatically during deploy):
```bash
./scripts/fix-oauth-redirect.sh --kubeconfig ~/ostest-kubeconfig.yaml
```
Then restart Chrome and retry login. If the operator overwrites the fix, run it again after deploy completes.

## Issue: Deployment fails with "cannot connect to catalog"

**Solution:** Use the manual deployment script `deploy-che-from-bundles.sh` which bypasses OLM catalog networking.

## Issue: "Route POST:/api/kubernetes/namespace/provision not found"

**Cause:** The `POST /api/kubernetes/namespace/provision` endpoint is provided by **che-server**, not the dashboard. This error appears when che-server is not deployed (CheCluster status `InstallOrUpdateFailed`). On IPv6 clusters, che-server often fails due to image pull issues (quay.io unreachable) or operator reconciliation conflicts (air-gap secret key order).

**Prevention:** The deploy script automatically runs `fix-image-pulls.sh` after creating the CheCluster, and if che-server is still not deployed after ~5 minutes, runs `provision-che-server-manually.sh` as a fallback.

**Manual fix (if deploy did not recover):**

1. Run `fix-image-pulls.sh` to patch CheCluster and deployments:
   ```bash
   ./scripts/fix-image-pulls.sh --kubeconfig ~/ostest-kubeconfig.yaml \
     --server-image pr-951 --dashboard-image pr-1442
   ```

2. If still failing, run:
   ```bash
   ./scripts/helpers/provision-che-server-manually.sh --kubeconfig ~/ostest-kubeconfig.yaml \
     --server-image pr-951
   ```

3. If che-gateway is missing ("Application is not available"), run:
   ```bash
   ./scripts/helpers/provision-che-gateway-manually.sh --kubeconfig ~/ostest-kubeconfig.yaml
   ```

## Issue: "403 Forbidden" on POST /api/kubernetes/namespace/provision

**Cause:** The request reaches che-server but is rejected due to authentication or authorization. Common reasons:
- User is not logged in (OAuth flow not completed)
- User's OpenShift token lacks permission to create namespaces
- OAuth session expired or cookie not sent

**Solutions:**

1. **Complete OAuth login:** Access the dashboard via the main Che URL (not port-forward). Ensure you complete the OpenShift login flow and are redirected back to the dashboard. Use Chrome with the proxy configuration from the deployment output.

2. **Use kubeadmin:** On ostest clusters, log in with `kubeadmin` (credentials from cluster-bot). kubeadmin has cluster-admin and can create namespaces.

3. **Grant namespace creation:** If using a different user, ensure they can create namespaces:
   ```bash
   oc adm policy add-cluster-role-to-user self-provisioner <username>
   ```

4. **Clear cookies and retry:** Stale or corrupted OAuth cookies can cause 403. Clear site data for the Che host and log in again.

## Issue: "User \"system:anonymous\" cannot get resource \"users\"" (403 on /api, /swagger)

**Cause:** The manual gateway was missing the header-rewrite middleware. The OpenShift API requires `Authorization: Bearer`; oauth-proxy sends `X-Forwarded-Access-Token`. The forwardAuth call failed because the token was in the wrong header.

**Solution:** Re-run `./scripts/helpers/provision-che-gateway-manually.sh` (includes the header-rewrite plugin). Ensure you access the dashboard via the main Che URL and complete OAuth login before calling the API.

## Issue: "no endpoints available for service devworkspace-webhookserver" (500 on workspace create)

**Symptom:** When creating a workspace, you get:
```
failed calling webhook "mutate.devworkspace-controller.svc": no endpoints available for service "devworkspace-webhookserver"
```

**Cause:** The devworkspace-webhook-server pods have ImagePullBackOff (IPv6 cluster cannot pull from quay.io). The webhook service has no backing pods.

**Solution:** Run fix-image-pulls to patch the webhook to use the local registry and restart pods:
```bash
./scripts/fix-image-pulls.sh --kubeconfig ~/ostest-kubeconfig.yaml
```
Then retry workspace creation. The deploy script runs this automatically and retries during the wait loop.

## Issue: "Failed to open the workspace" / pods forbidden by Security Context Constraint (SCC)

**Symptom:** When creating a workspace, you see:
```
Error creating DevWorkspace deployment: FailedCreate pods "workspace...-" is forbidden: unable to validate against any security context constraint:
provider "anyuid": Forbidden: not usable by user or serviceaccount
provider restricted-v2: .containers[0].capabilities.add: Invalid value: "SETGID"...
```

**Cause:** Workspace pods require `SETGID`, `SETUID`, and `allowPrivilegeEscalation` for dev containers. The default `restricted-v2` SCC denies these. The workspace ServiceAccount must be allowed to use the `anyuid` SCC.

**Solution:** Run `ensure-deployment-ready` (applies the SCC fix automatically):
```bash
./scripts/ensure-deployment-ready.sh --kubeconfig ~/ostest-kubeconfig.yaml
```

Or apply manually (both required on ostest clusters):
```bash
# 1. Allow workspace service accounts to use anyuid
oc patch scc anyuid --type=json -p='[{"op":"add","path":"/groups/-","value":"system:serviceaccounts"}]'

# 2. Allow SETGID/SETUID capabilities (workspace devfiles require these)
oc patch scc anyuid --type=merge -p '{"allowedCapabilities":["SETGID","SETUID"]}'
```

Then delete the failed workspace in the dashboard and create a new one.

**Note:** The deploy script runs `ensure-deployment-ready` at the end, which now applies this SCC fix. On freshly provisioned clusters, the fix is applied during deploy.

## Issue: "User system:serviceaccount:eclipse-che:che cannot create resource projectrequests" (403 on namespace provision)

**Cause:** The `che` ServiceAccount lacks cluster-scoped permission to create OpenShift projects (projectrequests). This happens when the Che operator never fully reconciled (e.g. InstallOrUpdateFailed) and the manual provisioning scripts were used.

**Solution:** Re-run `./scripts/helpers/provision-che-server-manually.sh` (creates ClusterRole/ClusterRoleBinding for che SA). Or apply manually:
```bash
export NAMESPACE=eclipse-che
envsubst < manifests/che/che-sa-project-permissions.yaml | oc apply -f -
```

## Issue: InstallOrUpdateFailed + "Waiting for DevWorkspaceRouting controller to be ready"

**Symptom:** CheCluster status is `InstallOrUpdateFailed`. Workspaces stay in "Starting" with message "Waiting for DevWorkspaceRouting controller to be ready". Operator logs show: `Operation cannot be fulfilled on deployments.apps "che-dashboard": the object has been modified`.

**Cause:** The `che-dashboard-airgap` secret can cause the Che operator to enter a reconcile loop. The operator iterates over secret keys in non-deterministic order (Go map), producing different volume mount order each reconcile → deployment spec drift → update conflicts.

**Mitigation:** The deploy script now adds air-gap samples **after** Che is deployed (Step 6b). Algorithm: deploy Che first with ConfigMap (GitHub URLs), then add the Secret once Che is ready. This avoids the reconcile loop during initial deploy.

**Solution (if you deployed with older script or manual secret):**

1. **Delete the secret and redeploy:**
   ```bash
   oc delete secret che-dashboard-airgap -n eclipse-che
   oc delete pod -n eclipse-che -l app.kubernetes.io/name=che-operator --force --grace-period=0
   ```

2. **Or deploy fresh with --airgap-samples** (script now defers secret until after Che is ready):
   ```bash
   ./scripts/deploy-che-from-bundles.sh --kubeconfig ~/ostest-kubeconfig.yaml --airgap-samples
   ```

## Issue: Workspace pod ImagePullBackOff for che-code (quay.io/che-incubator/che-code:latest)

**Symptom:** Workspace pod fails with:
```
Failed to pull image "quay.io/che-incubator/che-code:latest": ... network is unreachable
Mirrors also failed: [virthost.../eclipse-che/che-incubator/che-code:latest: manifest unknown]
```

**Cause:** The cluster cannot reach quay.io (IPv6-only / air-gap). The ICSP redirects pulls to the local registry, but `che-code` was never mirrored there.

**Solution:** Re-run the mirror script with `--mode full` so che-code is included and pushed to the registry. Run from a host that can reach both quay.io and the cluster registry:
```bash
./scripts/mirror-images-to-registry.sh --kubeconfig ~/ostest-kubeconfig.yaml --mode full
```
Then delete the failed workspace in the dashboard and create a new one. The mirror script now includes `quay.io/che-incubator/che-code:latest` in full mode.

## Issue: Workspace fails with "Init Container project-clone has state ImagePullBackOff" or devworkspace-webhook ImagePullBackOff

**Symptom:** Workspace shows "Error creating DevWorkspace deployment: Init Container project-clone has state ImagePullBackOff", or devworkspace-webhook-server pods fail with:
```
Failed to pull image "quay.io/devfile/devworkspace-controller:sha-4410b61": manifest unknown
Failed to pull image "quay.io/devfile/project-clone:sha-4410b61": manifest unknown
```

**Cause:** The DevWorkspace Operator pins both `devworkspace-controller` and `project-clone` to commit-based tags (e.g. `sha-4410b61`). When DWO updates, the sha changes. The cluster cannot reach quay.io (IPv6-only). The ImageTagMirrorSet redirects to the local registry, but these tags must be mirrored.

**Prevention:** Run `ensure-deployment-ready.sh` (runs at deploy end). It pins **project-clone** via DevWorkspaceOperatorConfig to `quay.io/devfile/project-clone:sha-4410b61`, so workspace init containers always use a mirrored tag regardless of DWO updates. The devworkspace-webhook (controller) image still comes from the DWO bundle; to pin it, use `--devworkspace-bundle quay.io/devfile/devworkspace-operator-bundle@sha256:...` when deploying.

**Solution (if project-clone still fails):** Re-run the mirror script with `--mode full`. The mirror script includes `devworkspace-controller:sha-*` and `project-clone:sha-*` (sha-9b46583, sha-4410b61, sha-9415b15). When DWO updates, add the new sha for both images in `scripts/mirror-images-to-registry.sh` and re-mirror. Run from a host that can reach both quay.io and the cluster registry (use kubeconfig proxy):
```bash
./scripts/mirror-images-to-registry.sh --kubeconfig ~/ostest-kubeconfig.yaml --mode full
```
The script also auto-discovers images from cluster events (`Failed` with "manifest unknown") when KUBECONFIG is set. You can also use `--mirror-from-namespace devworkspace-controller` to discover sha-* images from pods.
Then delete the failed workspace in the dashboard and create a new one.

## Issue: Node.js/Python devfile server workspaces fail with ImagePullBackOff (registry.access.redhat.com/ubi8)

**Symptom:** Workspace created from `http://[fd02::3823]:8080/nodejs/devfile.yaml` or `/python/devfile.yaml` fails with ImagePullBackOff for `registry.access.redhat.com/ubi8/nodejs-18` or `ubi8/python-39`.

**Cause:** IPv6-only cluster cannot reach registry.access.redhat.com. The ImageTagMirrorSet redirects to the local registry, but these images were never mirrored.

**Solution:** Run the mirror script with `--mode full` (extracts test-infrastructure devfile images):
```bash
./scripts/mirror-images-to-registry.sh --kubeconfig ~/ostest-kubeconfig.yaml --mode full
```
The mirror script extracts `ubi8/nodejs-18:latest` and `ubi8/python-39:latest` from `manifests/test-infrastructure/`. Then delete the failed workspace and create a new one.

## Issue: "FailedPostStartHook" / "postStart hook failed with an unknown error"

**Symptom:** Workspace fails with:
```
Error creating DevWorkspace deployment: Detected unrecoverable event FailedPostStartHook: [postStart hook] failed with an unknown error
```

**Cause:** The che-code editor or UDI runs a postStart hook (e.g. fetching extensions from open-vsx.org). On IPv6-only clusters, workspace pods cannot reach external URLs without a proxy.

**Solution 1 – Cluster proxy (persists):** Patch the cluster Proxy CR so workspace pods get HTTP_PROXY automatically:
```bash
PROXY=$(grep -m1 'proxy-url:' ~/ostest-kubeconfig.yaml | awk '{print $2}' | sed 's|/$||')
oc patch proxy cluster --type=merge -p "{\"spec\":{\"httpProxy\":\"${PROXY}/\",\"httpsProxy\":\"${PROXY}/\",\"noProxy\":\"localhost,127.0.0.1,.cluster.local,.svc,.metalkube.org,virthost.ostest.test.metalkube.org,fd02::/112\"}}"
```

**Solution 2 – DevWorkspaceOperatorConfig (Che may revert):** Run the fix script, then delete the failed workspace and create a new one:
```bash
./scripts/fix-workspace-proxy.sh --kubeconfig ~/ostest-kubeconfig.yaml
```
If FailedPostStartHook returns, run this again right before creating a workspace.

**Debug:** Add `controller.devfile.io/debug-start: "true"` to the DevWorkspace to leave failed pod resources; then `oc logs <pod> -c <container>` or check `/tmp/poststart-stderr.txt` in the container.

## Issue: "container has runAsNonRoot and image will run as root" (che-gateway in workspace pod)

**Symptom:** Workspace pod fails with:
```
Error: container has runAsNonRoot and image will run as root (pod: "workspace...", container: che-gateway)
```

**Cause:** Workspace pods include a che-gateway (Traefik) sidecar injected by Che's routing controller. That sidecar is configured with `runAsNonRoot: true` but the Traefik image runs as root (UID 0). Namespace pod-security labels and DevWorkspaceOperatorConfig do not override the Che routing controller's hardcoded security context for the gateway.

**Solution:** Run `ensure-deployment-ready` (applied automatically at deploy end; also run after creating a new workspace if needed):
```bash
./scripts/ensure-deployment-ready.sh --kubeconfig ~/ostest-kubeconfig.yaml
```
For a quick fix without other steps, use `--gateway-patch-only`:
```bash
./scripts/ensure-deployment-ready.sh --kubeconfig ~/ostest-kubeconfig.yaml --gateway-patch-only
```
The deploy script deploys a **CronJob** (`che-gateway-patcher`) that runs every 1 minute to re-apply the patch when the Che routing controller overwrites it. On IPv6-only clusters, mirror `registry.redhat.io/openshift4/ose-cli` first or the CronJob pod will fail to start. To deploy the CronJob manually:
```bash
kubectl apply -f manifests/che/che-gateway-patcher-cronjob.yaml -n eclipse-che
```
