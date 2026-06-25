# k3s-anywhere — Claude instructions

## Cutting a release

When the user asks to cut or prepare a release (e.g. "release v0.2.0"), do all
of the following before committing and tagging:

1. **Update the `image` default in `cluster.yaml`** to the new version:
   ```
   default: "sinanozel/k3s-anywhere:X.Y.Z"
   ```

2. **Update every `sinanozel/k3s-anywhere:` reference in README.md** from the
   old pinned version (or `:latest`) to the new one. Find them with:
   ```
   grep -n "sinanozel/k3s-anywhere:" README.md
   ```
   Use `replace_all: true` to update all occurrences in one edit. Leave the
   `X.Y.Z` placeholder in the "Releasing the image" section unchanged.

3. **Commit** with message: `Release vX.Y.Z`

4. **Tag**: `git tag vX.Y.Z && git push origin main && git push origin vX.Y.Z`

The build workflow treats release tags as write-once — if the tag already exists
on Docker Hub it will fail. Always cut a new version rather than re-tagging.

## General rules

- `ACTION=setup` and `ACTION=decommission` are operator-only, never in CI.
- Admin credentials are passed at invocation; they are never stored or committed.
- The `MANAGED_POLICIES` array in `setup.sh` must stay in sync with `decommission.sh`.
- Dev builds (`0.1.x-dev.N`) never move `:latest`; only stable releases do.
