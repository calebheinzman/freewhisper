# Source of truth for the cask published at github.com/calebheinzman/homebrew-tap.
#
# The tap already exists with this file at `Casks/freewhisper.rb`. The
# `bump-cask` job in .github/workflows/release.yml rewrites the version and
# sha256 lines there on every release, so edit this file for anything structural
# and copy it across.
#
# A personal tap rather than homebrew-cask proper: core requires notability a
# brand-new project cannot meet, and a tap updates the same minute a release
# lands instead of waiting on a review queue.
cask "freewhisper" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/calebheinzman/freewhisper/releases/download/v#{version}/FreeWhisper-#{version}.dmg",
      verified: "github.com/calebheinzman/freewhisper/"
  name "FreeWhisper"
  desc "Local-first meeting transcription and dictation menu bar app"
  homepage "https://github.com/calebheinzman/freewhisper"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  # The models run on the Neural Engine. An Intel Mac would technically launch
  # and then transcribe unusably slowly, so refuse up front instead.
  depends_on arch: :arm64

  app "FreeWhisper.app"

  # fwctl ships inside the bundle so it inherits the app's TCC grants rather than
  # the terminal's. This only puts it on PATH.
  binary "#{appdir}/FreeWhisper.app/Contents/MacOS/fwctl"

  uninstall quit: "dev.freewhisper.FreeWhisper"

  # One directory holds the meetings and every model the app manages, which is
  # what makes this a short list.
  zap trash: [
    "~/Library/Application Support/FreeWhisper",
    "~/Library/Caches/dev.freewhisper.FreeWhisper",
    "~/Library/HTTPStorages/dev.freewhisper.FreeWhisper",
    "~/Library/Preferences/dev.freewhisper.FreeWhisper.plist",
    "~/Library/Saved Application State/dev.freewhisper.FreeWhisper.savedState",
  ]

  caveats <<~EOS
    FreeWhisper will ask for Microphone and System Audio Recording permission,
    plus Accessibility if you use the ⌘⎋ dictation hotkey and Screen Recording
    if you turn on meeting screenshots.

    Parakeet's weights live in a cache shared with any other app built on
    FluidAudio, so `brew uninstall --zap` leaves them alone:

      ~/Library/Application Support/FluidAudio/Models/

    Delete that by hand if nothing else on your Mac needs it.

    Your own API keys, if you set any, are in the login keychain and are not
    removed by zap either.
  EOS
end
