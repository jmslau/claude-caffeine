cask "claude-caffeine" do
  version "1.3.4"
  sha256 "7ee8706af3e71b1181dd078d4f3ba399ef282f6a41d81aad7d5ad232e900fb9a"

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
