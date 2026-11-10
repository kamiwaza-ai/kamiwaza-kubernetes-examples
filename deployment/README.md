# Deployment scenarios index

Deployment scenarios: each folder documents a concrete deployment topology, expected feature toggles, and verification steps.

| Scenario | Path | Focus |
| --- | --- | --- |
| Environment profile matrix | [env-profile-matrix](env-profile-matrix) | Lite/full/dev/dev-full topology and expected behavior |
| Offline bundle download (Keygen) | [offline-bundle-download](offline-bundle-download) | Download, verify, and reassemble a split offline release bundle from Keygen |
| Offline model import | [offline-model-import](offline-model-import) | Import a Hugging Face model into an air-gapped install from a weights image (`core.offlineModelImports`, 1.4.1+) |
| Offline bundle → AWS EKS (ECR) | [eks-offline-bundle](eks-offline-bundle) | Relocate an offline release bundle to Amazon ECR and deploy the offline Helmfile onto an existing EKS cluster |
