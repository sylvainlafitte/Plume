# Plume

Plume is a lightweight meeting transcriber for macOS. It lives in the menu bar, turns your
meeting into a transcript, and combines it with the notes you write to generate a summary.
Choose the Markdown template that fits the meeting — 1:1, stand-up, hiring, or your own.

Your meeting files are plain Markdown, so you can open and edit them in any text editor.

## Local by default

Recordings, transcripts, notes and summaries stay on your Mac. Plume has no account, analytics or
cloud service. It uses Ollama on `127.0.0.1` for summaries. The only network access is the initial
download of the speech models.

Audio is deleted after transcription. The transcript and your notes remain in `meeting.md`.

## Features

- Menu bar recording, with `⌥⌘R` as a global shortcut
- Separate microphone and system-audio capture
- On-device transcription and speaker separation
- A small notes panel for notes during and after the meeting
- Summaries generated from your notes, transcript and chosen template
- Editable Markdown templates and meeting files
- Meetings window for browsing, renaming speakers, regenerating summaries and opening files
- Optional login item and camera-on reminder

## Requirements

- macOS 15 or later
- Apple silicon Mac
- [Ollama](https://ollama.com) for summaries
- About 700 MB for the speech models, plus your Ollama model

## Install

Download the latest release from [Releases](https://github.com/sylvainlafitte/Plume/releases), unzip
it, and move **Plume.app** to `/Applications`.

To build from source:

```bash
git clone https://github.com/sylvainlafitte/Plume.git
cd Plume
./build-app.sh release run
```

## First run

1. Launch Plume from `/Applications`.
2. Download the speech models when Setup & Checks appears.
3. Allow Microphone and Screen & System Audio Recording access. Run the capture check before your
   first real meeting.
4. For summaries, install Ollama and pull a model:

   ```bash
   ollama pull gemma4
   ```

## Use it

Start a recording from the menu bar or press `⌥⌘R`. Click the pill to expand it and write notes.

Stop the recording, add any final thoughts, choose a template, and press **Summarise**. Plume
transcribes the meeting and writes the notes, summary and transcript to:

```text
~/Meetings/<meeting>/meeting.md
```

Open the Meetings window later to edit notes, change a template, rename speakers or regenerate a
summary. The files are yours to move, edit and keep.

## Privacy

Plume processes meeting data locally and sends nothing to a remote service. Ollama runs locally on
your Mac. Tell participants when you are recording and follow the laws that apply where you are.

## License

MIT. See [LICENSE](LICENSE).
