cask "claude-caffeine" do
  version "1.3.5"
  sha256 "1a7c279fab9c1635477b52ddae50bc77d270222a527c09c61528d5d4ae780c8c"

  url "https://github.com/jmslau/claude-caffeine/releases/download/v#{version}/Claude-Caffeine.app.zip",
      verified: "github.com/jmslau/claude-caffeine/"
  name "Claude Caffeine"
  desc "Keeps your Mac awake while Claude Code is working"
  homepage "https://github.com/jmslau/claude-caffeine"

  depends_on macos: ">= :ventura"

  app "Claude Caffeine.app"

  caveats <<~EOS
    Claude Caffeine can optionally install a privileged helper to prevent
    sleep when the lid is closed. On first launch, the app will prompt you
    to install this helper (requires an admin password).

    If the app is quit unexpectedly and your Mac never sleeps, run:
      sudo pmset -a disablesleep 0
  EOS
end
