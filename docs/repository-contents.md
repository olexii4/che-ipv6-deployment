# Repository Contents

## Scripts

- **[scripts/mirror-images-to-registry.sh](../scripts/mirror-images-to-registry.sh)** - Mirror Che images to cluster local registry
- **[scripts/deploy-che-from-bundles.sh](../scripts/deploy-che-from-bundles.sh)** - Manual operator deployment from OLM bundles (runs all fixes automatically)
- **[scripts/ensure-deployment-ready.sh](../scripts/ensure-deployment-ready.sh)** - Post-deploy verification: runs fix-image-pulls + fix-oauth-redirect + SCC fix (anyuid) + DevWorkspaceOperatorConfig runAsNonRoot + patches workspace Deployments (che-gateway runAsNonRoot:false), waits for webhook (run if login or workspace create fails; use `--gateway-patch-only` for quick che-gateway fix)
- **[scripts/fix-image-pulls.sh](../scripts/fix-image-pulls.sh)** - Patch CheCluster and deployments to use local registry (prevents InstallOrUpdateFailed, workspace webhook)
- **[scripts/fix-oauth-redirect.sh](../scripts/fix-oauth-redirect.sh)** - Fix OAuth redirect URI mismatch (prevents login "invalid_request" error)
- **[scripts/helpers/provision-che-gateway-manually.sh](../scripts/helpers/provision-che-gateway-manually.sh)** - Provision che-gateway when operator fails (fixes "Application is not available")
- **[scripts/helpers/provision-che-server-manually.sh](../scripts/helpers/provision-che-server-manually.sh)** - Provision che-server when operator fails (fixes "Route POST:/api/kubernetes/namespace/provision not found")
- **[scripts/test-ipv6-validation.sh](../scripts/test-ipv6-validation.sh)** - Deploy devfile server for IPv6 testing; `--cleanup` removes test namespace
- **[scripts/che-proxy-pac-helper.sh](../scripts/che-proxy-pac-helper.sh)** - Generate PAC file and Chrome proxy command for ostest
- **[scripts/helpers/fix-namespace-provision-403.sh](../scripts/helpers/fix-namespace-provision-403.sh)** - Grant self-provisioner to user (fixes 403 on namespace provision)
- **[scripts/helpers/test-airgap-samples.sh](../scripts/helpers/test-airgap-samples.sh)** - Validate air-gap samples API
