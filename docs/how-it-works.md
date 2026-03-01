# Deployment Method

## Manual Operator Installation

The deployment script extracts operator manifests directly from OLM bundle images and applies them manually. This approach:

- ✅ **Bypasses OLM catalog networking issues** common in IPv6-only clusters
- ✅ **Works on clusters with broken IPv6 ClusterIP connectivity**
- ✅ **Uses official OLM bundle images** (same as OLM would use)
- ✅ **Provides direct control** over operator versions
- ✅ **Compatible with image mirroring** for disconnected environments

## How it works

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
