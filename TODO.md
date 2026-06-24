# TODO

## Update Quick Start to pin workflow ref and image at first release

The Quick Start and GitHub Actions examples in README.md currently use `@main`
and `sinanozel/k3s-anywhere:latest`. Once `v0.1.0` is tagged these should
become `@v0.1.0` and `image: sinanozel/k3s-anywhere:0.1.0`. This is covered
by the release checklist in CLAUDE.md and will be handled automatically when
cutting the first release.
