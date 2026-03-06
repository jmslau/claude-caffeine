#!/usr/bin/env bash
set -euo pipefail

# Release script for ClaudeCaffeine
# Usage: ./scripts/release.sh <version>
# Example: ./scripts/release.sh 1.0.0
#
# This script handles the full release lifecycle:
#   1. Build release binary and app bundle
#   2. Create zip archive and compute SHA256
#   3. Update cask formula with new version and hash
#   4. Commit, tag, and push to source repo
#   5. Create GitHub Release with zip attached
#   6. Update homebrew-tap repo with new cask formula

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CASK_FILE="$PROJECT_DIR/Casks/claude-caffeine.rb"
TAP_REPO="jmslau/homebrew-tap"
SOURCE_REPO="jmslau/claude-caffeine"

# --- Validate arguments ---

if [ $# -ne 1 ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 1.0.0"
  exit 1
fi

VERSION="$1"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Version must be in semver format (e.g., 1.0.0)"
  exit 1
fi

# --- Preflight checks ---

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is required. Install with: brew install gh"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: Not authenticated with GitHub CLI. Run: gh auth login"
  exit 1
fi

cd "$PROJECT_DIR"

if [ -n "$(git status --porcelain -- ':!Casks/')" ]; then
  echo "Error: Working tree has uncommitted changes (outside Casks/). Commit or stash first."
  exit 1
fi

if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
  echo "Error: Tag v${VERSION} already exists"
  exit 1
fi

echo "==> Releasing ClaudeCaffeine v${VERSION}"

# --- Run tests ---

echo "==> Running tests"
swift test --quiet

# --- Build release binary ---

echo "==> Building release binary"
swift build -c release

# --- Create app bundle ---

echo "==> Creating app bundle"
APP_VERSION="$VERSION" "$SCRIPT_DIR/make-app-bundle.sh"

# --- Create zip archive ---

echo "==> Creating zip archive"
DIST_DIR="$PROJECT_DIR/dist"
ZIP_PATH="$DIST_DIR/ClaudeCaffeine.app.zip"

rm -f "$ZIP_PATH"
cd "$DIST_DIR"
ditto -c -k --keepParent "ClaudeCaffeine.app" "ClaudeCaffeine.app.zip"
cd "$PROJECT_DIR"

# --- Compute SHA256 ---

SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{ print $1 }')
echo "    SHA256: $SHA256"

# --- Update cask formula ---

echo "==> Updating cask formula"
sed -i '' "s/version \".*\"/version \"${VERSION}\"/" "$CASK_FILE"
sed -i '' "s/sha256 \".*\"/sha256 \"${SHA256}\"/" "$CASK_FILE"

# --- Commit and tag ---

echo "==> Committing and tagging"
git add Casks/claude-caffeine.rb
git commit -m "chore: release v${VERSION}" --allow-empty
git tag "v${VERSION}"

# --- Push ---

echo "==> Pushing to origin"
git push origin main "v${VERSION}"

# --- Create GitHub Release ---

echo "==> Creating GitHub Release"
gh release create "v${VERSION}" "$ZIP_PATH" \
  --repo "$SOURCE_REPO" \
  --title "v${VERSION}" \
  --notes "ClaudeCaffeine v${VERSION}

Install:
\`\`\`
brew install --cask jmslau/tap/claude-caffeine
\`\`\`

Or download \`ClaudeCaffeine.app.zip\` below."

# --- Update homebrew-tap ---

echo "==> Updating homebrew-tap"
TAP_DIR=$(mktemp -d)
trap 'rm -rf "$TAP_DIR"' EXIT
git clone --depth 1 "https://github.com/${TAP_REPO}.git" "$TAP_DIR"
cp "$CASK_FILE" "$TAP_DIR/Casks/claude-caffeine.rb"
cd "$TAP_DIR"
git add Casks/claude-caffeine.rb
git commit -m "chore: update claude-caffeine to v${VERSION}"
git push
cd "$PROJECT_DIR"

echo ""
echo "==> Released ClaudeCaffeine v${VERSION}"
echo "    https://github.com/${SOURCE_REPO}/releases/tag/v${VERSION}"
echo ""
echo "    Users can install with:"
echo "    brew install --cask jmslau/tap/claude-caffeine"
