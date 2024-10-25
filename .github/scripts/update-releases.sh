#!/usr/bin/env bash
set -euo pipefail

# Get the latest release version from GitHub API directly
latest_version=$(curl -s https://api.github.com/repos/effekt-lang/effekt/releases/latest | jq -r .tag_name | sed 's/^v//')

# Read current releases.json
if jq -e --arg v "$latest_version" '.[$v]' releases.json >/dev/null; then
    echo "Latest version $latest_version is already in releases.json"
    echo "updated=false" >> "$GITHUB_OUTPUT"
    exit 0
fi

# Download release and compute hash using Nix
url="https://github.com/effekt-lang/effekt/releases/download/v${latest_version}/effekt.tgz"
hash=$(nix-prefetch-url "$url" --type sha256)
base64=$(nix hash to-base64 --type sha256 "$hash")

# Update releases.json
jq --arg v "$latest_version" --arg h "$base64" '. + {($v): $h}' releases.json > releases.json.new
mv releases.json.new releases.json

# Set outputs for the GitHub Action
echo "updated=true" >> "$GITHUB_OUTPUT"
echo "version=$latest_version" >> "$GITHUB_OUTPUT"
