# Meeting titles and folder lifecycle

Planned repository copy: `docs/meeting-titles-plan.md` (first change after plan approval).

## Goal

Let someone name a meeting before, during, or after wrap-up without creating separate rename
implementations or moving a session folder while transcription or summarization still owns its
path. Keep readable `<timestamp>-<slug>` folders, make deletion operate on the whole session
folder, and preserve Plume's document and provenance invariants.

## Accepted UX

- The title is editable during recording, in wrap-up, and in Meetings.
- All three surfaces use one reusable inline heading control.
- An unnamed heading says **Add title** in muted styling.
- A small pencil is always visible; the whole heading starts editing.
- Return or blur commits once. Escape cancels. Clearing the field and committing keeps the
  previous title.
- Notes keep initial focus when the recording panel opens.
- There is no visible title-length limit. Pasted line breaks are flattened to spaces. Only the
  folder slug is truncated, using a UTF-8-byte-safe limit.
- A human title writes `title:` and `title_source: user`; summary regeneration never replaces it.
- The Meetings list shows muted **Add title** for unnamed rows, with date/time below.
- The existing Meetings **Rename...** dialog and menu item are removed.
- In the recording panel, participant count moves to the footer. The clock inserts a timestamp;
  at rest it shows the red dot, and on hover the dot becomes a plus and the time gains a subtle
  underline without reflow. `Command-T` remains.
- Delete moves the entire session folder, including `meeting.md` and `.plume`, to the Trash.
- Delete is disabled for queued/actively transcribing sessions and explains why. A failed,
  permission-blocked, or cancelled `.recorded` session is not stranded and may be deleted.

## Current code facts

- `RecordingSession.stop()` is the sole initial writer of `.plume/meta.json`.
- `TranscriptionCoordinator` currently reads metadata once at job start, writes
  `title: <folder-name>` unconditionally, writes `meeting.md`, deletes audio, and advances state.
- `SummaryEngine` currently writes derived titles and moves folders itself.
- `MeetingAdmin.rename` writes human provenance and moves immediately.
- `MeetingAdmin.trash` already receives `MeetingEntry.url` and calls `trashItem` on that session
  URL. The reported orphan-folder behavior must be reproduced or guarded with a regression test;
  do not add a second delete path.
- `MeetingPanelController` and `HistoryModel` can reference the same session simultaneously, so a
  folder move must update both before either can autosave to an obsolete URL.
- `docs/DECISIONS.md` is already modified in the user-owned worktree. Preserve that working-tree
  content and edit it surgically only when documenting the shipped result.

## On-disk contract

### Human title before `meeting.md`

Add one optional `user_title` string to `.plume/meta.json`.

- `RecordingSession` holds the recording-time draft and includes `user_title` in its one full
  metadata write at Stop.
- After Stop, title changes use one read-modify-write helper that preserves every unknown metadata
  key and writes atomically. It must never re-encode only `SessionMeta`'s current subset.
- Post-Stop metadata mutations are serialized by `MeetingLifecycleCoordinator`; transcription is
  a reader and therefore observes either the complete old file or complete new file.
- The optional key is backward-compatible and does not require a state/document format bump.

### Untitled convention and migration

- New untitled meetings have no `user_title` in metadata and no `title` key in frontmatter.
- Transcription must stop writing the folder name as a title when no human title exists.
- A derived summary title writes `title` without `title_source: user`.
- A human title writes `title` plus `title_source: user`.
- For pre-change documents, `title` is treated as a legacy fallback—not a real title—when it has
  no `title_source` and exactly equals the session folder's last path component. This converts old
  unsummarized timestamp titles to the new unnamed presentation without misclassifying derived
  titles, whose human-readable frontmatter value differs from their slugged folder name.
- `MeetingEntry` gains an explicit optional/untitled title representation. The folder name remains
  identity and fallback diagnostics, not display title.
- Delete confirmations for untitled meetings use the formatted meeting date/time, not the literal
  **Add title** prompt.

### Title normalization and folder slug

- Trim surrounding whitespace.
- Replace every newline sequence with one space; collapse the whitespace introduced by that
  replacement so pasted multiline text cannot inject frontmatter or `---`.
- An empty normalized edit is a no-op.
- Keep the complete normalized title in metadata/frontmatter.
- Make `MeetingIdentityDeriver.slug` enforce its filename budget by UTF-8 bytes, reserving room for
  the 15-character timestamp, separator, and collision suffix. Keep collision disambiguation.

## Concrete coordination design

Add one process-wide `MeetingLifecycleCoordinator` actor under `Meeting/`. It is the only component
that coordinates title-driven folder moves and Trash against active work.

### Responsibilities

1. Resolve an old session URL through an in-process alias map after a move.
2. Track work tokens/counts for queued transcription jobs and active summary jobs.
3. Persist post-Stop human titles to metadata.
4. Update existing `meeting.md` frontmatter through `MeetingDocument.updateFrontmatter`.
5. Apply derived titles without overwriting `title_source: user`.
6. Defer folder moves while work count is nonzero.
7. At a successful safe boundary, move once using the latest document title and return the final
   URL.
8. Refuse Trash while a work token exists; otherwise Trash the session directory.
9. Publish every path change so all in-process models adopt the new URL.

Use an explicit token API rather than inferring "busy" from `state.json`; `.recorded` includes
queued, active, and failed sessions, while `.transcribed` does not reveal an active summary.
A suitable contract is:

```swift
let token = await lifecycle.beginWork(on: session, kind: .transcription)
// perform work against token.session
let final = await lifecycle.finishWork(token, successful: true)
```

`finishWork(..., successful: false)` releases ownership without moving. Human title data already
written to metadata/frontmatter remains valid; a lagging folder name is tolerated and can be
reconciled on the next successful operation.

### Atomic UI path replacement

`AppController` registers an async move callback with the lifecycle actor. When a safe move is
requested, the callback runs one uninterrupted `MainActor` operation that:

1. flushes pending notes for any panel/history model referencing the old URL;
2. calls the existing collision-safe `MeetingAdmin.renameFolder`;
3. updates both `MeetingPanelController.session` and `HistoryModel.selection`/entries if they
   referenced the old URL;
4. reloads their content from the new URL;
5. returns the final URL to the actor/caller.

This prevents a debounce from recreating the old folder after a move. The lifecycle actor records
the old-to-new alias before accepting subsequent operations. In CLI contexts without UI models,
the coordinator may call `MeetingAdmin.renameFolder` directly.

## Pipeline sequence

### Recording and Stop

1. `MeetingTitleEditor` commits to `MeetingPanelController`.
2. While recording, `AppController` copies the normalized title to
   `RecordingSession.userTitle`; no file or folder move occurs.
3. `RecordingSession.stop()` atomically writes full `meta.json`, including `user_title`.
4. Enqueueing/resuming transcription obtains a lifecycle work token immediately, so queued
   sessions are protected from Trash and title-driven moves.

### Transcription

1. Read normal track metadata and process the original session URL.
2. Immediately before rendering, re-read the latest optional `user_title`.
3. Render frontmatter with:
   - human title plus `title_source: user`, or
   - no `title` key when untitled.
4. Write `meeting.md`, then delete audio exactly as today.
5. Ask the lifecycle actor to reconcile `user_title` once more. Because the work token is still
   held, this may update frontmatter but cannot move the folder. This closes the race where the
   user commits after step 2.
6. Advance state to `.transcribed` at the current URL.
7. Finish the work token successfully. The actor moves the folder if needed, publishes the path
   replacement, and returns the final URL.
8. On failure, block the original/current session as today and finish the token unsuccessfully;
   no folder move occurs.

### Summary

1. `SummaryEngine.summarize` obtains a lifecycle work token before its first document read.
2. Summary region writes remain unchanged and continue to re-read the document before replacement.
3. Derived identity application goes through the lifecycle actor:
   - skip the derived title when frontmatter says `title_source: user`;
   - otherwise update `title`, but do not move while the summary token is held.
4. Advance state to `.summarized` at the current URL.
5. Finish successfully, allowing one deferred move and returning the final URL.
6. On generation failure, finish unsuccessfully before rethrowing. No path changes, so the
   existing caller can reload the previous good summary from its current URL.
7. Work counts support the same session being opened in both surfaces; a move happens only after
   the last successful owner releases it.

### Completed idle meeting

A title commit updates metadata and frontmatter through the lifecycle actor. With no work token,
the actor requests an immediate atomic UI move and returns the new URL. Both surfaces are updated,
not only the one that initiated the edit.

## UI implementation

### Reusable title control

Add `UI/MeetingTitleEditor.swift` with compact and detail styles.

- Display state: title or muted **Add title**, always-visible pencil, whole-heading tap target.
- Editing state: borderless single-line `TextField`.
- Keep one local draft and one editing flag so Return followed by blur cannot double-commit.
- `onSubmit` and focus loss commit; `onExitCommand` cancels and restores the prior value.
- Empty normalization cancels.
- Display state may carry `WindowDragGesture`; editing state must not, so selection works.
- Supply keyboard focus, accessibility button/text-field traits, label, value, and edit hint.
- No counter or UI length cap.

### Model contract

Extend `MeetingDetailModel` (or a small title-specific protocol used by all three surfaces) with:

- optional actual title, separate from fallback display text;
- title commit action;
- title edit availability/error state;
- current session URL adoption after lifecycle notifications.

Source rules:

- before `meeting.md`: read `user_title` from metadata;
- after `meeting.md`: read frontmatter title/provenance;
- while a title commit is in flight: retain the optimistic local title, then adopt the returned
  URL or surface the error without discarding the prior durable value.

### Recording panel

- Header order: panel controls, title editor (capped near 46% of available width), explicit drag
  gutter, clock target.
- Preserve a usable drag region at the 340-point minimum.
- Move `ParticipantsMenu` to the footer.
- Replace the visible **Add timestamp** button with the clock interaction selected above.
- The clock target is not a `Button`; combine tap and drag without turning a drag into a click.
- Reserve stable clock geometry through the hour rollover and hover icon swap.
- `insertStamp()` must always mutate `controller.notes`, never the focused field; title focus must
  not receive timestamp text.
- Keep `Command-T`, help text, keyboard activation, and VoiceOver announcement.
- Keep Notes focused on first expansion.

### Wrap-up and Meetings

- Reuse the title editor in both headers; keep `MeetingDetailView` for the shared Notes/Summary body.
- History keeps the formatted date/duration subtitle and action menu, minus **Rename...**.
- `MeetingEntry` row renders actual title normally or muted **Add title** when nil.
- Update list, selection, panel session, notes autosave target, and content after every published
  path change.

## Deletion

- Route UI deletion through `MeetingLifecycleCoordinator.trash`.
- `MeetingAdmin.trash` remains the one filesystem primitive and receives a validated session
  directory, never `meeting.md`.
- Disable the action when `stage == .recorded && blocker == nil`; this covers queued/active normal
  transcription. Allow failed, permission-blocked, and cancelled sessions once no work token
  remains.
- The actor independently refuses deletion while any work token exists, guarding stale UI state.
- Flush relevant notes before Trash, preserve neighbour selection afterward, and surface failures
  without optimistically removing the row.
- Add a narrow test seam around the Trash move so a temp session can be moved to a temp "Trash"
  destination. Assert the destination contains both `meeting.md` and `.plume/state.json`, and the
  original session directory no longer exists.

## File map

| Area | Files |
|---|---|
| New lifecycle/title logic | `Sources/PlumeKit/Meeting/MeetingLifecycleCoordinator.swift` |
| Metadata/title parsing | `RecordingSession.swift`, `Transcription/TranscriptionCoordinator.swift`, `Meeting/MeetingContent.swift`, `Meeting/MeetingLibrary.swift` |
| Folder/title admin | `Meeting/MeetingAdmin.swift`, `Summary/MeetingIdentity.swift`, `Summary/SummaryEngine.swift` |
| App wiring/path notifications | `App.swift`, `UI/MeetingPanelController.swift`, `UI/HistoryWindow.swift` |
| Shared title UI/layout | new `UI/MeetingTitleEditor.swift`, `UI/MeetingPanelViews.swift`, `UI/MeetingDetailView.swift` as needed for the model contract |
| Tests | existing `MeetingAdminTests.swift`, `MeetingLibraryTests.swift`, summary/session metadata tests, plus a focused lifecycle/title test file |
| Docs | `README.md`, `AGENTS.md`, surgical reconciliation of the existing `docs/DECISIONS.md` edit |

## Test and acceptance matrix

### Persistence and provenance

- Title entered during recording appears in `meta.json` at Stop.
- Title edited while queued/transcribing: latest commit wins in frontmatter.
- Human title writes `title_source: user` and survives first summary and Regenerate.
- Untitled transcription omits `title`; Meetings shows muted **Add title**.
- Legacy `title == folder-name` without user provenance is presented as untitled.
- Newer unsupported document formats refuse title writes through the existing loud error path.
- Multiline paste becomes one safe line; long Unicode titles remain complete in the document and
  produce a valid bounded folder component.

### Work and URL safety

- No folder move while a transcription or summary token exists.
- Successful transcription/summary moves once and returns/publishes the exact final URL.
- Failed summary does not move and the old URL remains usable.
- Same-minute collisions produce distinct `-2` folders and no prefix search is used.
- With wrap-up and Meetings open on the same session, a move updates both and later notes autosave
  does not recreate the old directory.

### UI behavior

- All three surfaces show the same title and use the same editor behavior.
- Return/blur commits once; Escape and empty edit preserve the prior title.
- Pencil is always visible; **Add title** is muted when empty.
- Notes receive initial typing, not the title.
- Title text can be selected while editing; display-state drag still moves the window.
- Clock hover does not reflow; tap and `Command-T` insert into Notes even when title has focus.
- Participant selection still reaches the one-session metadata override from its new footer.

### Deletion

- Queued/active normal transcription disables Delete with an explanation.
- Failed/permission-blocked/cancelled recordings can be deleted when no token is active.
- Completed deletion moves the entire session folder to Trash and selects the expected neighbor.
- A Trash failure leaves the row and reports the error.

## Documentation and worktree handling

- Copy this file to `docs/meeting-titles-plan.md` before implementation; this is the explicit
  user-requested handoff artifact and the exception to the repository's normal avoidance of plan
  registries.
- Update `README.md` for naming during/after recording, readable folder names, inline Meetings title
  editing, the clock timestamp action, and whole-folder Trash behavior.
- Update `AGENTS.md` in the same change: title lifecycle, safe move ownership, returned-URL
  notifications, participant-menu placement, clickable-clock constraints, shared title control,
  and review date.
- `docs/DECISIONS.md` is user-owned and already modified. Diff against the working-tree copy and
  change only stale "not built"/"still open" wording once behavior ships; retain its rationale,
  risks, and unrelated edits.

## Execution order

1. Copy this reviewed plan to `docs/meeting-titles-plan.md`.
2. Add metadata helpers, untitled parsing/migration, and lifecycle actor with isolated unit tests.
3. Wire recording, transcription, summary work tokens, safe completion, and path notifications.
4. Add shared title model state and `MeetingTitleEditor`.
5. Rework recording header/footer and timestamp clock.
6. Harden/decorate deletion behavior and tests.
7. Update documentation.
8. Run focused tests, then `swift test` and `swift build`.

