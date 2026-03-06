cask "claude-caffeine" do
  version "1.2.1"
  sha256 "2b44acb5af74a6a6bcc9b01ebc290656141250bb9b9087e5277ac38aa6f755ed"

  url "https://github.com/jmslau/claude-caffeine/releases/download/v#{version}/Claude%20Caffeine.app.zip",
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
