# Deployment scenarios index

Deployment scenarios: each folder documents a concrete deployment topology, expected feature toggles, and verification steps.

| Scenario | Path | Focus |
| --- | --- | --- |
| Environment profile matrix | [env-profile-matrix](env-profile-matrix) | Lite/full/dev/dev-full topology and expected behavior |
| Offline bundle → AWS EKS (ECR) | [eks-offline-bundle](eks-offline-bundle) | Relocate an offline release bundle to Amazon ECR and deploy the offline Helmfile onto an existing EKS cluster |
