cask "forge" do
  version "1.0.15"
  sha256 "c4a397b49e79318287f32d6c641d50bb34d10ead9e1c71f3e3fd47e6b6b0ac80"

  url "https://github.com/iknahar/forge-app-source-code/releases/download/v#{version}/Forge-#{version}.dmg"
  name "Forge"
  desc "Native macOS menu-bar productivity toolkit (calendar, clipboard, window snap, eye-care, screen tools)"
  homepage "https://forge-toolkit.vercel.app/"

  app "Forge.app"

  # Forge is not yet signed with an Apple Developer ID nor notarized.
  # macOS 14+ Gatekeeper will block first launch with the dialog
  # "Apple could not verify Forge is free of malware". Users should
  # approve it once under System Settings -> Privacy & Security ->
  # "Open Anyway", or strip the quarantine flag manually:
  #
  #   xattr -dr com.apple.quarantine /Applications/Forge.app
  #
  # Once signed + notarized in a future release this caveat goes away.
  caveats <<~EOS
    Forge is not yet notarized by Apple. On first launch macOS will
    block it with "Apple could not verify Forge is free of malware".

    Approve it once:
      System Settings -> Privacy & Security ->
      "Forge was blocked..." -> Open Anyway

    Or strip the quarantine flag from Terminal:
      xattr -dr com.apple.quarantine /Applications/Forge.app
  EOS

  zap trash: [
    "~/Library/Preferences/com.toolkit.forge.plist",
    "~/Library/Application Support/Forge",
    "~/Library/Caches/com.toolkit.forge",
    "~/Library/Saved Application State/com.toolkit.forge.savedState",
    "~/Library/HTTPStorages/com.toolkit.forge",
  ]
end
