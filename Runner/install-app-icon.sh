#!/bin/sh
# Xcode puts UI-test assets in the .xctest bundle, not its generated host app.
# Run after the build so Xcode has finished creating the host's Info.plist.
set -eu

test_bundle="$(cd "${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}" && pwd -P)"
runner_app="$(dirname "$(dirname "$test_bundle")")"
icon_info="${TARGET_TEMP_DIR}/assetcatalog_generated_info.plist"
runner_info="${runner_app}/Info.plist"

case "$test_bundle" in
    *.app/PlugIns/*.xctest) ;;
    *) echo "error: Unexpected UI-test bundle path: $test_bundle" >&2; exit 1 ;;
esac
test -f "$runner_info"
test -f "$icon_info"
test -f "$test_bundle/Assets.car"

# Preserve an existing development signature after changing the host resources.
signed=NO
signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ] && /usr/bin/codesign -d "$runner_app" >/dev/null 2>&1; then
    signed=YES
    # Scheme post-actions may omit EXPANDED_CODE_SIGN_IDENTITY. Reuse the
    # certificate that Xcode actually signed with, rather than choosing a key.
    if [ -z "$signing_identity" ]; then
        certificate_dir="$(mktemp -d)"
        trap 'rm -rf "$certificate_dir"' EXIT
        /usr/bin/codesign -d --extract-certificates="$certificate_dir/cert" "$runner_app"
        signing_identity="$(/usr/bin/shasum -a 1 "$certificate_dir/cert0" | /usr/bin/cut -d ' ' -f 1)"
    fi
fi

cp "$test_bundle/Assets.car" "$runner_app/Assets.car"
for icon in "$test_bundle"/AppIcon*.png; do
    cp "$icon" "$runner_app/"
done
for key in CFBundleIcons 'CFBundleIcons~ipad'; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$runner_info" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Delete :$key" "$runner_info"
    fi
done
/usr/libexec/PlistBuddy -c "Merge '$icon_info'" "$runner_info"
# Match the release package's Home Screen name in source builds as well.
/usr/bin/plutil -replace CFBundleDisplayName -string "iPhone-use" "$runner_info"

if [ "$signed" = YES ]; then
    /usr/bin/codesign --force --sign "$signing_identity" \
        --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$runner_app"
    /usr/bin/codesign --verify --strict "$runner_app"
fi
echo "Installed Soma App Icon in $runner_app"
