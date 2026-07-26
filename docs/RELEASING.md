# Releasing

The release tag drives the install: `herdr/install.sh` reads the version from
`herdr-plugin.toml` and downloads the assets from the matching `v<version>` tag.
So the version has to be bumped before the tag, never after.

## Cut a release

1. Bump the version in the three places CI checks:
   - `herdr-plugin.toml` (`version = "…"`)
   - `pubspec.yaml` (`version: …`)
   - `bin/herdr_flutter.dart` (`const _version = '…'`)
2. `dart analyze && dart test`
3. Commit: `chore(release): 0.2.0`
4. Tag and push:

   ```sh
   git tag v0.2.0
   git push origin main --follow-tags
   ```

The `release` workflow then creates the GitHub Release for the tag and attaches
four archives with a checksum sidecar each:

| asset | built on |
| --- | --- |
| `herdr-flutter-aarch64-apple-darwin.tar.gz` | macos-latest |
| `herdr-flutter-x86_64-apple-darwin.tar.gz` | macos-13 |
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

## While the repository is private

Release assets are not served to an anonymous download, so `curl` gets a 404.
`install.sh` falls back to `gh release download`, which uses your existing
authentication, so a local install still works. A user who has no access to the
repository cannot install it at all until the repository is public.
