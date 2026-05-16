# Contributing to voxline

Thanks for your interest in voxline. Bug reports, feature ideas, and pull
requests are all welcome. File issues at
https://github.com/tfredricks/voxline/issues.

Please review and follow the project's [Code of Conduct](CODE_OF_CONDUCT.md)
when participating in the community.

## Building locally

voxline is a native macOS app built with Xcode. See the
[Requirements](README.md#requirements) section of the README for the
supported platform.

The simplest path is the existing build script, which builds Release and
installs the app to `/Applications`:

```bash
./scripts/build-local.sh
```

Add `--debug` to build the Debug configuration, or `--no-install` to
build only and skip installation.

To work in Xcode directly:

```bash
open voxline.xcodeproj
```

Then build and run with `⌘R`.

> Heads up: `CFBundleVersion` and `GitCommit` are stamped from git by the
> wrapper scripts (`scripts/build-local.sh` and CI). Building straight
> from the Xcode IDE skips that, so dev builds will show
> `CFBundleVersion = 1` and an empty `GitCommit`. That's fine for
> day-to-day work — use `./scripts/build-local.sh` when you need a
> realistically-versioned bundle.

## Running tests

```bash
xcodebuild test \
    -project voxline.xcodeproj \
    -scheme voxline \
    -destination 'platform=macOS'
```

## Submitting changes

1. Branch from `main`.
2. Keep changes focused — one logical change per pull request.
3. Follow the existing commit-message style. Recent history uses
   conventional commits (`feat(scope): …`, `fix(scope): …`,
   `docs(scope): …`, `refactor(scope): …`). Match what's already in
   `git log`.
4. Include a test plan in the PR description — what you ran, what you
   verified by hand.
5. Sign off your commits (see below).

## Developer Certificate of Origin (DCO)

voxline uses the Developer Certificate of Origin to keep contribution
provenance clean. Every commit must include a `Signed-off-by` trailer:

```
Signed-off-by: Your Name <your.email@example.com>
```

The easiest way is to pass `-s` when committing:

```bash
git commit -s -m "feat(thing): do the thing"
```

You can also add the trailer to an existing commit:

```bash
git commit --amend -s --no-edit
```

By signing off, you assert that you have the right to submit the
contribution under the project's license. The full text of the DCO is at
https://developercertificate.org.

Pull requests with unsigned commits will be asked to add the trailer
before they can merge.

## License

By contributing, you agree that your contributions will be licensed
under the [Apache License, Version 2.0](LICENSE).
