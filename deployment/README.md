# Deployment scenarios index

Deployment scenarios: each folder documents a concrete deployment topology, expected feature toggles, and verification steps.

| Scenario | Path | Focus |
| --- | --- | --- |
| Environment profile matrix | [env-profile-matrix](env-profile-matrix) | Lite/full/dev/dev-full topology and expected behavior |
| Local S3 with bundled SeaweedFS | [local-s3-seaweedfs](local-s3-seaweedfs) | In-cluster S3 backend for Skills Library / context object storage when no managed S3 endpoint is available |
