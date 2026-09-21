#!/bin/sh
# Read-only prerequisites. Device setup and connection remain explicit operations.
set -eu

source_workflow=false
case "${1-}" in
  '') ;;
  --source) source_workflow=true ;;
  *) echo 'Usage: preflight.sh [--source]' >&2; exit 64 ;;
esac
if [ "$#" -gt 1 ]; then
  echo 'Usage: preflight.sh [--source]' >&2
  exit 64
fi
if [ "$(uname -s)" != Darwin ]; then
  echo 'iPhone-use requires a Mac. Run this plugin on the Mac connected to the iPhone.' >&2
  exit 1
fi
if ! command -v iphone-use >/dev/null 2>&1; then
  echo 'iPhone-use CLI is missing from PATH. Install: brew install HughLee824/tap/iphone-use' >&2
  echo 'Restart your client after changing PATH; installing the plugin alone does not install the CLI.' >&2
  exit 1
fi
if ! version=$(iphone-use --version); then
  echo 'iPhone-use could not start. Check the complete CLI/Runner installation.' >&2
  exit 1
fi
if [ "$version" = development ] && [ "$source_workflow" = true ]; then
  echo 'Unversioned source CLI: use the explicitly supplied signed .xctestrun; verify command help.'
elif ! printf '%s\n' "$version" | awk -F. '
  /^[0-9]+\.[0-9]+\.[0-9]+$/ {
    if ($1 > 0 || ($1 == 0 && $2 >= 1)) valid = 1
  }
  END {exit !(valid && NR == 1)}'; then
  echo "Unsupported CLI version: $version. Install stable iPhone-use 0.1.0 or later." >&2
  exit 1
fi
if ! developer_dir=$(xcode-select -p) || [ ! -d "$developer_dir/Platforms/iPhoneOS.platform" ]; then
  echo 'Select full Xcode in Xcode Settings → Locations. Command Line Tools alone are insufficient.' >&2
  exit 1
fi
printf 'iPhone-use CLI: %s\nCLI path: %s\nXcode: %s\n' "$version" "$(command -v iphone-use)" "$developer_dir"
if iphone-use tap --help | grep -q -- '--observe'; then
  echo 'Action --observe: available. Read action outcome and observation separately.'
else
  echo 'Action --observe: unavailable. Use separate action, completion, and observe calls.'
fi
echo 'Next: iphone-use devices. A successful preflight does not validate device trust or signing.'
