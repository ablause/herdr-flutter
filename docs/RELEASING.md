# Releasing

Releases are prepared by release-please and cut by merging its pull request.
Nothing is bumped or tagged by hand.

## The flow

1. Land work on `main` with conventional commits. The type decides the bump:
   `feat` moves the minor, `fix` and `perf` the patch, and while the version is
   below 1.0 a breaking change moves the minor rather than the major.
2. release-please keeps a pull request open titled `chore(main): release x.y.z`.
   It holds the changelog for everything since the last tag and the version bump
   in the three files that carry it:
   - `pubspec.yaml`, from the dart release type
   - `herdr-plugin.toml` and `bin/herdr_flutter.dart`, from the
     `x-release-please-version` marker on their version line
3. Read the changelog in that pull request. It is the release notes, so edit the
   commit subjects that read badly before merging.
4. Merge it. release-please tags `vx.y.z`, creates the GitHub Release, and the
   same workflow then calls the release build.

Do not push a `v*` tag by hand unless you are redoing a release that failed: the
manifest in `.release-please-manifest.json` is the source of truth for the last
released version, and a hand-made tag leaves it stale.

## Why the build is called rather than triggered

A tag pushed with a workflow's own `GITHUB_TOKEN` does not start another
workflow. The release job therefore calls `release.yml` through `workflow_call`
instead of relying on the tag push being noticed. The same workflow still runs on
a hand-pushed tag, and still accepts a manual run for an existing tag.

## The assets

| asset | built on |
| --- | --- |
| `herdr-flutter-aarch64-apple-darwin.tar.gz` | macos-latest |
| `herdr-flutter-x86_64-apple-darwin.tar.gz` | macos-15-intel |
| `herdr-flutter-x86_64-unknown-linux-gnu.tar.gz` | ubuntu-latest |
| `herdr-flutter-aarch64-unknown-linux-gnu.tar.gz` | emulated arm64 container |

Dart cannot cross compile, which is why there is one runner per target and why
the arm64 Linux build runs under QEMU in a `dart:stable` container.

## Check it

```sh
gh run watch                                   # the release workflow
gh release view v0.2.0 --repo ablause/herdr-flutter
bash herdr/install.sh --prebuilt               # what a user gets
./bin/herdr-flutter --version
```

If a target failed on a runner outage, rerun its build for the existing tag
without moving anything:

```sh
gh workflow run release.yml -f tag=v0.2.0
```

## While the repository is private

Release assets are not served to an anonymous download, so `curl` gets a 404.
`install.sh` falls back to `gh release download`, which uses your existing
authentication, so a local install still works. A user who has no access to the
repository cannot install it at all until the repository is public.
