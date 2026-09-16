# Kaizen 0.13 frontend font hotfix manual

**Status:** retired.

Do not use the former copy-and-paste image mutation procedure. It reused an
existing release tag and replaced image content inside a Kind node.

Use the immutable release procedure in [README.md](README.md). Build a new
frontend image, publish a new digest, and reference that digest from a reviewed
Kaizen release artifact.
