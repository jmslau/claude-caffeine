#!/usr/bin/env bash
set -euo pipefail

# Release script for ClaudeCaffeine
# Usage: ./scripts/release.sh <version>
# Example: ./scripts/release.sh 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CASK_FILE="$PROJECT_DIR/Casks/claude-caffeine.rb"

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

echo "==> Building ClaudeCaffeine v${VERSION}"

# --- Build release binary ---

cd "$PROJECT_DIR"
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
echo "==> SHA256: $SHA256"

# --- Update cask formula ---

echo "==> Updating cask formula"
sed -i '' "s/version \".*\"/version \"${VERSION}\"/" "$CASK_FILE"
sed -i '' "s/sha256 \".*\"/sha256 \"${SHA256}\"/" "$CASK_FILE"

echo ""
echo "==> Release v${VERSION} prepared successfully"
echo ""
echo "Artifacts:"
echo "  $ZIP_PATH"
echo "  $CASK_FILE"
echo ""
echo "Next steps:"
echo "  1. Commit the updated cask formula"
echo "  2. Create a GitHub release:"
echo ""
echo "     git tag v${VERSION}"
echo "     git push origin v${VERSION}"
echo "     gh release create v${VERSION} '$ZIP_PATH' \\"
echo "       --title 'v${VERSION}' \\"
echo "       --notes 'ClaudeCaffeine v${VERSION}'"
echo ""
echo "  3. To publish the cask, submit the formula to a Homebrew tap"
