cask "forge" do
  version "1.0.17"
  sha256 "f24942d686a476e95350b0d69f2cabfb05147a977d4c6f90d69c7f2be6011824"

  url "https://github.com/iknahar/forge-app-source-code/releases/download/v#{version}/Forge-#{version}.dmg"
  name "Forge"
  desc "Native macOS menu-bar productivity toolkit (calendar, clipboard, window snap, eye-care, screen tools, per-app PIN lock)"
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
