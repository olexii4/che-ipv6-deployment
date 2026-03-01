# Troubleshooting

**Quick fix:** If deploy completed but login or workspace creation fails, run:
```bash
./scripts/ensure-deployment-ready.sh --kubeconfig ~/ostest-kubeconfig.yaml
```
This re-applies OAuth and webhook fixes and verifies readiness.

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

2. If still failing, run `provision-che-server-manually.sh`:
   ```bash
   ./scripts/provision-che-server-manually.sh --kubeconfig ~/ostest-kubeconfig.yaml \
     --server-image pr-951
   ```

3. If che-gateway is missing, run `provision-che-gateway-manually.sh`:
   ```bash
   ./scripts/provision-che-gateway-manually.sh --kubeconfig ~/ostest-kubeconfig.yaml
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

**Solution:** Re-run `provision-che-gateway-manually.sh` (recent versions include the header-rewrite plugin). Ensure you access the dashboard via the main Che URL and complete OAuth login before calling the API.

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

## Issue: "User system:serviceaccount:eclipse-che:che cannot create resource projectrequests" (403 on namespace provision)

**Cause:** The `che` ServiceAccount lacks cluster-scoped permission to create OpenShift projects (projectrequests). This happens when the Che operator never fully reconciled (e.g. InstallOrUpdateFailed) and the manual provisioning scripts were used.

**Solution:** Re-run `provision-che-server-manually.sh` (recent versions create the ClusterRole and ClusterRoleBinding for che SA). Or apply manually:
```bash
export NAMESPACE=eclipse-che
envsubst < manifests/che/che-sa-project-permissions.yaml | oc apply -f -
```
