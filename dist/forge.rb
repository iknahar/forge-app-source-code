cask "forge" do
  version "1.0.9"
  sha256 "12519552adbe8485ba0d3f161ef04a5e39d2c3aaf19d3411fc97cbd6c4153d23"

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
