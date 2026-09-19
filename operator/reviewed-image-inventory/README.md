# Apply a reviewed image inventory

Use the image inventory shipped with a Kamiwaza release to create auditable
`KamiwazaPlatform.spec.images.pinned` intent. This workflow works for every
qualified image variant because the platform API records image digests, not a
compliance mode.

**Tags:** #operator #images #supply-chain #fips

This example does not decide whether an image is approved or FIPS-qualified.
That decision belongs to signed release evidence. The helper validates selected
inventory entries and refuses tags, duplicate roles, unknown capabilities, and
non-resolving placeholder digests.

## Prerequisites

- The [operator quickstart](../quickstart/) files copied to local working files.
- Python 3 and `kubectl`.
- The signed operator release artifact for the selected Kamiwaza release.
- Registry access for every digest in that release.

Extract `dist/compatibility.json` from the signed release artifact. Verify the
artifact and its provenance with the procedure shipped in the same release
before using the inventory. A file copied from another release, a pull-request
artifact, or an image tag is not release evidence.

From the repository root:

```bash
cd operator/reviewed-image-inventory
export RELEASE_METADATA=/absolute/path/to/dist/compatibility.json
python3 -m json.tool "${RELEASE_METADATA}" >/dev/null
```

## 1. Select enabled capabilities

Pass each capability enabled by the platform manifest. The quickstart uses:

| Capability          | Include when                                          |
| ------------------- | ----------------------------------------------------- |
| `durableData`       | Always for the quickstart                             |
| `identityAndAccess` | `spec.components.identityAndAccess.enabled` is `true` |
| `relationshipStore` | ReBAC is enabled                                      |
| `applicationAPI`    | Always for the quickstart                             |
| `webInterface`      | Always for the quickstart                             |
| `objectStorage`     | Always for the quickstart                             |
| `metadataCatalog`   | `spec.components.metadataCatalog.enabled` is `true`   |
| `protocolDataPlane` | `spec.components.protocolDataPlane.enabled` is `true` |

Do not select `platformTransport`. The certificate signer, workload identity
agent, and pinned transport proxy belong to the installed operator release.
They are not platform image intent.

Generate a JSON Merge Patch for the quickstart capabilities:

```bash
./render-platform-images.py "${RELEASE_METADATA}" \
  --capability durableData \
  --capability identityAndAccess \
  --capability relationshipStore \
  --capability applicationAPI \
  --capability webInterface \
  --capability objectStorage \
  --capability protocolDataPlane \
  >kamiwaza-images.patch.json

python3 -m json.tool kamiwaza-images.patch.json
```

Add `--capability metadataCatalog` only after enabling that component in the
platform manifest.

## 2. Render local platform intent

Apply the patch locally. This changes only `spec.version` and
`spec.images.pinned`; it does not contact the cluster.

```bash
kubectl patch --local --type=merge \
  --filename ../quickstart/kamiwaza-platform.local.yaml \
  --patch-file kamiwaza-images.patch.json \
  --output=yaml \
  >kamiwaza-platform.reviewed.yaml
```

Review the exact change before applying it:

```bash
diff -u ../quickstart/kamiwaza-platform.local.yaml \
  kamiwaza-platform.reviewed.yaml

kubectl diff --server-side \
  --field-manager=platform-operator-user \
  --filename kamiwaza-platform.reviewed.yaml
```

A missing required role is refused by platform preflight. A repository outside
administrator policy is reported as blocked. Do not bypass either result by
adding a tag or widening repository policy without review.

## 3. Apply and verify

Continue at quickstart step 5 with the rendered file:

```bash
kubectl apply --server-side \
  --field-manager=platform-operator-user \
  --filename kamiwaza-platform.reviewed.yaml

kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .spec.images.pinned[*]}{.capability}{"/"}{.role}{"\t"}{.reference}{"\n"}{end}'

kubectl -n kamiwaza-examples get pods \
  --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' \
  | sort -u
```

Compare declared pins, active operator-managed Pod images, and signed release
inventory. Every observed platform image must identify its reviewed digest. A
pin for an on-demand role need not appear until its workload exists. External
prerequisites and completed migration Jobs are outside this active set; retain
their release evidence separately.

For a FIPS-qualified release, retain the release's exact-image scan,
attestation, and runtime evidence with the installation record. The operator
uses the same platform API and workload contract for standard and qualified
images. It does not infer or advertise FIPS status from an image name.

## Update procedure

Do not edit one digest in place. Obtain the next signed release metadata,
regenerate the patch and platform manifest, inspect the full diff, then follow
the release's upgrade procedure. This keeps related application and migration
roles on the set tested together.

## Local helper verification

The focused checks exercise capability filtering, exact-digest refusal, and a
real `kubectl patch --local` against the quickstart manifest:

```bash
python3 -m unittest discover -s . -p 'test_render_platform_images.py'
```

## Cleanup

The generated patch and rendered manifest are local installation records. Keep
them in the approved deployment system or remove them from this checkout. Do
not commit organization-specific registries or release artifacts to this public
examples repository.
