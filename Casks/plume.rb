# Homebrew cask for Plume.
#
# This file is the source of truth, but Homebrew does NOT read it from here: a tap
# must be a repository named homebrew-<something>, so releasing copies this file to
# sylvainlafitte/homebrew-tap as Casks/plume.rb. `./release-cask.sh` does that copy
# and computes the sha256 from the published asset — never from the local dist/ zip,
# which is the same "trust the file you happen to have" mistake that shipped a stale
# binary once already (docs/PROGRESS.md, 2026-08-16).
#
# Stanza order is enforced by `brew style`, so keep new stanzas where it wants them
# rather than where they read best.
cask "plume" do
  version "0.1.0"
  sha256 "cb7d24b4516c8f1e0249af8dde3acc7126680097d6432b3078cea960a0cee028"

  url "https://github.com/sylvainlafitte/Plume/releases/download/v#{version}/Plume-#{version}.zip"
  name "Plume"
  desc "Local-only meeting recorder, transcriber and summarizer for the menu bar"
  homepage "https://github.com/sylvainlafitte/Plume"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Plume never updates itself: `brew upgrade` is the mechanism, and the in-app
  # check only ever points at the release page.
  auto_updates false
  # A bare symbol is the minimum-version form (the ">= :sequoia" string spelling is
  # deprecated). Apple silicon only — the on-device models run on the ANE.
  depends_on macos: :sequoia
  depends_on arch: :arm64

  app "Plume.app"

  zap trash: [
    "~/.config/plume",
    "~/Library/Application Support/Plume",
    "~/Library/Logs/Plume",
  ]

  caveats <<~EOS
    Plume needs Microphone and Screen & System Audio Recording permission, and
    downloads about 700 MB of on-device speech models on first launch. Summaries
    additionally need Ollama:

      brew install --cask ollama
      ollama pull gemma4

    Your meetings are NOT removed by `brew uninstall --zap`: ~/Meetings holds the
    only copy of each meeting.md, and the audio it came from is already deleted.
    Remove that folder yourself if you really mean to.

    The FluidAudio model cache in ~/Library/Application Support/FluidAudio is also
    left alone — it is not Plume's namespace and another app may share it.
  EOS
end
