# Changelog

Notable changes to Plume. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The user-facing version is `CFBundleShortVersionString`. `CFBundleVersion` is a separate,
monotonic build number stamped from the commit count at build time — it is not a release number
and does not appear here.

## [Unreleased]

Nothing yet.

## [0.1.0] — 2026-08-16

First public release. Local-only macOS meeting recorder: everything but the summary model download
stays on the machine.

### Added

- **Recording.** Menu-bar toggle or ⌥⌘R from anywhere. Two tracks captured separately — microphone
  via `AVAudioEngine`, system audio via a CoreAudio process tap — so your voice and the far end can
  be told apart without guessing.
- **Transcription.** On-device Parakeet ASR, with offline diarization attributing far-end speech to
  distinct speakers and an echo filter dropping mic-side duplicates of system audio. **Audio is
  deleted once the transcript is written**, by design.
- **`meeting.md` per meeting**, with `notes` / `summary` / `transcript` regions delimited by HTML
  comments. Regeneration replaces a single region and fails loudly rather than duplicating one, so
  generated content can live in a file you also edit by hand.
- **Notes panel** — a floating pill during the call that expands for typing, and a wrap-up window
  afterwards for the thoughts you only have once it's over. ⌘T inserts a timestamp.
- **Summaries** through a local Ollama model, driven by markdown templates in a folder you can edit.
  A global `Vocabulary.md` glossary fixes the spelling of names and jargon in the summary.
- **Meetings window** for going back to anything: re-read, edit notes, rename or merge speakers,
  switch template, regenerate. Delete moves to the Trash.
- **Derived titles and speaker names.** Titles rename the folder; a title you set yourself is never
  overwritten. Inferred speaker names wait for a click before they are applied — a wrong name puts
  words in a real person's mouth.
- **Setup & Checks window** that downloads the speech models with progress, and grants *and
  verifies* both audio permissions by capturing a tone. An unauthorized system-audio tap reports
  success and records silence, so capturing is the only check that tells the truth.
- **A recording disclosure.** The recording panel's **Disclosure** button copies a one-line
  "I'm recording this" notice to paste into the meeting chat, overridable with `disclosure_text` —
  the sufficient wording is jurisdictional, and notice alone is not consent everywhere. Plume never
  posts it for you; it is not a participant in the call.
- **Optional extras**: launch at login, and camera-triggered "you aren't recording" notifications
  whose button starts a recording. Both off unless you turn them on; detection never starts a
  recording by itself.
- **On-disk format versions** for `meeting.md` (the frontmatter `plume:` key) and
  `.plume/state.json` (a `version` field). Both tolerate older and missing values and refuse to
  act on newer ones: Plume will not rewrite a document, or transcribe a session, written by a
  version it does not understand. With the audio deleted after transcription, a bad rewrite has
  nothing to recover from.
- An app icon.
- Developer ID-signed, notarized and stapled release build, with `CFBundleVersion` stamped as a
  monotonic build number from the commit count. It is not the release number and does not track
  this file.

[Unreleased]: https://github.com/sylvainlafitte/Plume/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/sylvainlafitte/Plume/releases/tag/v0.1.0
