# Feather Kira — GitHub Actions

This repository is prepared to build the iOS IPA automatically on GitHub Actions.

## Automatic build

- Every push to any branch runs **Build Feather IPA**.
- The resulting `Feather.ipa` is uploaded as a workflow artifact.
- Pushing a tag beginning with `v` runs **Release Feather IPA** and publishes a GitHub Release.
- The Release workflow can also be started manually with **Run workflow**.

## Local Swift package dependencies

If `Zsign` or `IDeviceKitten` are missing because the project was uploaded from a ZIP instead of a recursive Git clone, `.github/scripts/prepare-local-packages.sh` fetches them automatically before Xcode builds the project.

## Version handling

The app `Info.plist` now explicitly contains `CFBundleShortVersionString` and `CFBundleVersion`. The Release workflow also has a fallback that reads `FEATHER_PROJECT_VERSION` from `Feather.xcconfig`, so a missing generated plist version no longer causes the `Extract Version` / `PlistBuddy` failure.

## Expected output

The iOS build produces:

`packages/Feather.ipa`

## Pinned local package commits

CI intentionally checks out the same local package revisions used by upstream Feather instead of tracking the latest branch tips:

- Zsign: `6ffe703df73ef9069adacdbb19d571f11a69a801`
- IDeviceKit: `837cf1e14d4875771dd5ee1b754a4c86215c5db3`

This is required because Feather's LicensePlist configuration reads `Zsign/LICENSE_LC` during the build, and that file is present in the pinned Zsign revision.
