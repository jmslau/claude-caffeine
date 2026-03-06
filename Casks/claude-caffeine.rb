cask "claude-caffeine" do
  version "1.2.0"
  sha256 "c0261e543c62a030c7917688b3d28c31dabf878592543df17cbe0fe5d04a79ce"

  url "https://github.com/jmslau/claude-caffeine/releases/download/v#{version}/ClaudeCaffeine.app.zip",
      verified: "github.com/jmslau/claude-caffeine/"
  name "ClaudeCaffeine"
  desc "Keeps your Mac awake while Claude Code is working"
  homepage "https://github.com/jmslau/claude-caffeine"

  depends_on macos: ">= :ventura"

  app "ClaudeCaffeine.app"

  caveats <<~EOS
    ClaudeCaffeine can optionally install a privileged helper to prevent
    sleep when the lid is closed. On first launch, the app will prompt you
    to install this helper (requires an admin password).

    If the app is quit unexpectedly and your Mac never sleeps, run:
      sudo pmset -a disablesleep 0
  EOS
end
