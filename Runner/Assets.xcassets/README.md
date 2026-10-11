# Runner App Icon

`AppIcon.appiconset/AppIcon.png` is the 1024 × 1024 opaque, white-background
iphone-use phone/swipe symbol copied from [the shared brand asset](../../assets/brand/iphone-use-app-icon.png).
Its original proportions and clear space are preserved. Xcode generates the
iPhone and iPad sizes from this image. The brand export script updates
this App Icon copy automatically; see the [brand asset guide](../../assets/brand/README.md).

Build with the shared `IPhoneUseRunner` scheme. UI-test asset catalogs normally
belong to the `.xctest` bundle; the scheme's `install-app-icon.sh` post-action
copies the compiled icons and icon metadata to the generated Runner app and
sets its Home Screen name to `iPhone-use`, matching release packages. It
refreshes its signature when signed. This also applies to CLI source builds
and release packaging, which use the same scheme.
