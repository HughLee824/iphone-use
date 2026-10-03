#!/bin/sh
# Read-only prerequisites. Device setup and connection remain explicit operations.
set -eu

source_workflow=false
candidate_workflow=false
cli=${IPHONE_USE_CLI:-iphone-use}
case "${1-}" in
  '') ;;
  --source) source_workflow=true ;;
  --candidate) candidate_workflow=true ;;
  *) echo 'Usage: preflight.sh [--source|--candidate]' >&2; exit 64 ;;
esac
if [ "$#" -gt 1 ]; then
  echo 'Usage: preflight.sh [--source|--candidate]' >&2
  exit 64
fi
if [ "$(uname -s)" != Darwin ]; then
  echo 'iPhone-use requires a Mac. Run this plugin on the Mac connected to the iPhone.' >&2
  exit 1
fi
if ! command -v "$cli" >/dev/null 2>&1; then
  echo 'iPhone-use CLI is missing from PATH. Install: brew install HughLee824/tap/iphone-use' >&2
  echo 'Restart your client after changing PATH; installing the plugin alone does not install the CLI.' >&2
  exit 1
fi
if ! version=$("$cli" --version); then
  echo 'iPhone-use could not start. Check the complete CLI/Runner installation.' >&2
  exit 1
fi
if [ "$version" = development ] && [ "$source_workflow" = true ]; then
  echo 'Unversioned source CLI: standard needs no Runner; runner requires a supplied signed .xctestrun or setup.'
elif [ "$candidate_workflow" = true ] && printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z][0-9A-Za-z.-]*$'; then
  echo 'Explicit local candidate: no published-release or device-readiness claim.'
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
printf 'iPhone-use CLI: %s\nCLI path: %s\nXcode: %s\n' "$version" "$(command -v "$cli")" "$developer_dir"
tap_help=$("$cli" tap --help)
if printf '%s\n' "$tap_help" | grep -q -- '--observe'; then
  echo 'Action --observe: available. Read action outcome and observation separately.'
else
  echo 'Action --observe: unavailable. Use separate action, completion, and observe calls.'
fi
if printf '%s\n' "$tap_help" | grep -q -- '--agent-output'; then
  echo 'Agent output: available. Use --agent-output for actions and native text preparation/finish; full receipt saved locally.'
fi
if text_help=$("$cli" text-prepare --help 2>/dev/null) && printf '%s\n' "$text_help" | grep -q -- '--field-rect'; then
  echo 'Scoped text preparation: available. Use text-prepare --field-rect for a visible complete field; inspect its stable media or Apple PNG baseline before input.'
fi
connect_help=$("$cli" connect --help)
if printf '%s\n' "$connect_help" | grep -q -- '--mode'; then
  echo 'Control modes: available. Honor saved mode unless the user explicitly selects standard or runner.'
fi
echo 'Next: iphone-use devices. A successful preflight does not validate device trust or signing.'
