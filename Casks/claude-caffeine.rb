cask "claude-caffeine" do
  version "1.3.0"
  sha256 "2a99bf5e830f4ad25b725c107add0a6efca85d227337ca9600464c83acc79c16"

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
