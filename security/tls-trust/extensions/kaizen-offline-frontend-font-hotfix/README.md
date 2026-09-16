# Kaizen 0.13 frontend font hotfix

**Status:** unsupported historical procedure. Do not run it on an
operator-managed platform.

Tags: #kaizen #historical #unsupported

## Why this procedure is retired

The original procedure modified a bundled `frontend:1.8.13` image tar. It then
reused the same mutable tag and replaced that tag inside a Kind node.

That approach breaks current release guarantees:

- Current Kaizen releases use a different frontend image and version.
- Current release images are pinned by digest.
- The current reference environment uses k0s, not a Kind node.
- Reusing a tag hides changed image content from review and provenance checks.
- Replacing a node image bypasses the operator and release inventory.
- A later pull, node replacement, or bundle reinstall can remove the patch.

The `frontend:1.8.13` tar and exact `release/0.13.0` bundle are not part of the
current validation target.

## Current release path

Fix offline font loading in Kaizen source. Bundle local font files or use system
fonts. Build and test a new frontend image with network access disabled.

Publish the new image with its own immutable digest. Add that digest to the
reviewed Kaizen release artifact. Apply a new release version through the
extension release workflow.

Verify these results before release:

1. Start the frontend with container networking disabled.
2. Require the runtime rebuild to complete.
3. Confirm that no request targets `fonts.googleapis.com` or
   `fonts.gstatic.com`.
4. Confirm that the operator deploys the reviewed digest.
5. Open the Kaizen UI and check the rendered font fallback.

Do not retag a changed image as an existing release. Do not import a replacement
under an existing digest or tag.

## Historical evidence

Git history retains the former `release/0.13.0` image-tar procedure. It is not a
current runbook and was not validated against the operator-managed topology.

A legacy installation that cannot upgrade needs a separate reviewed image and
bundle. Give that image a new digest and record it in the legacy release
inventory before deployment.
