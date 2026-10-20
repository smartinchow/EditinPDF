# ADR 0002: How edits, undo and saving fit together (M2–M3)

- Status: accepted
- Date: 2026-10-21
- Context: M2 and M3 of the design spec turn the viewer into an editor: page organizing, markup, forms and
  signing, with Undo and Redo and an autosave that must never damage the user's file. Spec:
  `docs/superpowers/specs/2026-10-15-editinpdf-ios-design.md` (section "M2–M3 scope update"). Plan:
  `docs/superpowers/plans/2026-10-18-m2-m3-editor.md`.

## Context

Three things pull against each other.

- **SwiftUI's document scene wants a simple contract.** `DocumentGroup` with a `ReferenceFileDocument` asks for a
  snapshot, then writes it with `fileWrapper`, and autosaves when the undo manager says the document changed. It
  has no idea that the real document lives in a Rust engine behind a lock.
- **The engine keeps its own history.** `PdfDocument.undo()` and `redo()` (`core/editinpdf-core/src/document.rs`)
  take no argument: they move the engine's stack, whatever is on top. The app's undo manager has to stay in
  step with it.
- **Edits name their target by position.** An edit says "page 3" or "the comment at place 2 of page 1", and
  points are in view space (page rotation applied). Any change in between can make those mean something else.
  The reader can tap faster than the engine answers, and the engine's save holds the document's lock for the
  whole write, so nothing on the main thread may call the engine.

## Decision

### 1. One queue, and the undo manager is told first

All changes, undos and redos go through one `EditQueue` (`ios/EditinPDF/Document/EditQueue.swift`). It is a
chain: `submit` links a job behind the last one at once, so jobs run in the order of the calls. Each job runs on
the main actor, sends its engine calls off the main actor (`offMain`), and **publishes the result on the main
actor inside the same job** (`DocumentModel.refresh`). The next job starts only after that, so what a job reads
(the revision, the page list, the "shift" revisions of section 6) is what the jobs before it left, and the
reader's screen is never behind the engine by more than the job in flight. `DocumentModel.loadState` uses the
queue too, so the first read of a document comes before any change handed over meanwhile.

### 2. The undo-token protocol

`DocumentModel.enqueue` (`ios/EditinPDF/Document/DocumentModel.swift`) does this for every change:

1. It makes an `EditToken` (`applied = false`, the pages the change touches).
2. It **registers the undo manager entry right then**, on the main actor, with the token as the entry's target
   (`registerStep`). The undo manager's stack and the engine's history therefore get the changes in the same
   order, however fast the reader taps, and the registration is what makes `DocumentGroup` autosave.
3. It hands the edit to the queue. When its turn comes, `apply` asks the engine. On success it sets
   `token.applied = true` and publishes. On refusal it shows an `EditFailure` and **takes the entry off again**
   with `removeAllActions(withTarget: token)`.

Running an undo manager entry does two things at once: it registers the opposite entry (so an undo can be redone,
and that redo undone), and it hands `move(step, token)` to the queue, behind everything handed over before it. An
undo tapped while its edit is still waiting therefore undoes that edit once it has been made, never an older one.
When `move` runs, it does nothing if `token.applied` is false (the engine refused the change). If the engine fails to undo or redo, the two histories no longer match: every live
token's entries are taken off the undo manager (`liveChanges`, a weak table) and the reader is told.

The engine's undo has no identity, only order. The token's job is to make sure that the undo manager never holds
an entry the engine has no step for, and that the order of entries is the order of steps.

`EngineHandle.editWillStart` and `editDidFinish` count the jobs handed over and not finished, so that a save can
wait for them (section 3).

### 3. The snapshot is the engine object, and the bytes are written off the main thread

`PDFFileDocument.Snapshot` is `PdfDocument` itself (`ios/EditinPDF/Document/PDFFileDocument.swift`).
`snapshot(contentType:)` returns it, so taking a snapshot costs nothing and the file's bytes are held once, by the
engine. Copying them at snapshot time would be a full save, and the bridge's `save` holds the state lock for the whole
write (`document.rs`).

The write is `fileWrapper(snapshot:configuration:)`, which calls `save(mode: .incremental)` on SwiftUI's
background queue. The bridge's lock means the write sees whole edits. A snapshot is therefore a live reference,
not a frozen copy: a save writes the document as it is when the write runs. That is what an autosave should
write. To make a save taken just after a change (the strokes added as the back button goes down) include it,
`savedBytes(of:)` waits, off the main thread only, for up to 2 s for the jobs counted by `EngineHandle`, and logs a
warning if it gave up. A file that is locked or could not be read has no engine document in the handle, and its
snapshot is refused with our own message, so it is never written.

`EngineHandle` (`ios/EditinPDF/Document/EngineHandle.swift`) is what the file document and the model share: a
lock-guarded slot for the document and the counter. The model fills the slot when the file opens and on `unlock`.

### 4. There is no `markSaved`

The design spec listed `markSaved()`. The engine has the equivalent (`Session::mark_saved`, which reopens the
engine's working file from the saved bytes, clears the dirty flag and rebases the next save on them), and the
bridge deliberately does not expose it. `PdfDocument.save` says so: it "does not mark the document as saved", and
`is_dirty` stays true after a save.

So **every save is the file as it was opened plus one appended update holding every change made since**
(`Session::save_bytes`, "an incremental update of the file as opened/last saved"; an unchanged document comes
back exactly as opened). The user's original bytes are a prefix of what is written, which is what makes autosave
safe for files the app did not make. The other consequence is the safety property: nothing ever tells the engine
that a write succeeded, so a write that failed, or that the system could not finish, can never leave the engine
believing the file holds changes it does not. The next save simply writes all of them again. The cost is that an
update holds the whole session's changes rather than only the newest, which is small next to rewriting the file
(`SaveMode.full` exists in the bridge for a later "optimized copy", and refuses a signed document; the app does
not use it yet).

### 5. What `apply_all` refuses to mix

`apply` makes one change. `apply_all(label, edits, base_revision)` makes several, in order, as one engine step
(`Edit::Batch`): all or none, one revision, one undo step (`document.rs`, `edit.rs`). It refuses, as `Invalid`:

- more than 10,000 edits (`MAX_STEP_EDITS`);
- **a page-structure edit with an edit that carries a point or a box** (`is_page_structure` with `has_geometry`).
  Every edit of a step is converted from view space to the file's space against the document **as it is before the
  step** (`to_engine` is given that one document). After a turn, a delete, a move or an insert, a later edit's
  "view space" would be a different place. So the app cannot turn a page and draw on it in one step;
- **an edit that renumbers pages with an edit that addresses a comment** (`renumbers_pages` with
  `addresses_annotation`: delete, move or change the text of a comment). Those name the comment by page number and
  place, read before the step. A turn does not renumber, so a turn with a change of a comment's text is allowed;
  a turn with a move is already refused by the previous rule, because a move has a distance in view space;
- **`DeleteAnnotations` with any other edit that addresses a comment of the same page by its place**
  (`annotation_places_check`), for the reason in section 7. Adding a comment (it goes at the end of the list),
  changes to other pages and form fills are fine.

Filling a form field is addressed by the field's name (`FormField.name`), which no change to pages or comments
alters, so `SetFieldValue` mixes with anything. Names are checked against the fields as they are before the step
(`field_check`), so a field that pages inserted by the same step bring in can be filled from the next step on.

The app stays inside these rules by construction: a multi-page delete is one `deletePages` with a list, an
eraser stroke is one `deleteAnnotations`, and a long Pencil drawing that exceeds the bridge's ink caps becomes
several `addInk` edits of one step (`ios/EditinPDF/Markup/InkGeometry.swift`). The rules exist so that a mistake
in the app is refused with `Invalid` instead of changing the wrong thing.

### 6. Revisions, `Stale`, and the rebase rule

`PdfDocument.revision()` is 0 on open and goes up by one after every edit, undo or redo that succeeds (and after
a `Failed`, which may have changed the document: the apps are told to read it again). `apply` and `apply_all` take
the revision the edit was worked out for: under the lock, `mutate` compares it with the current one and, if they
differ, does nothing and returns `EditError::Stale { current }`.

The app does not want every second tap to fail just because the first has not been published yet, so
`DocumentModel.apply` decides, when the change's turn comes, whether it may be **rebased**: sent with the current
revision instead of the one it was worked out at. `canRebase` says yes when nothing since could have made it
mean something else:

- `lastIndexShift` is the revision made by the last change that can renumber pages or comments: deleting, moving
  or inserting pages, deleting or moving a comment, and any undo or redo (`shift(of:)`, and `.index` for undo and
  redo in `move`).
- `lastGeometryShift` is the later of that and the last rotation of a page.
- An edit worked out at revision `base` is rebased when `base >= lastIndexShift` and either
  `base >= lastGeometryShift` or the edit has no point or box in view space (`hasViewSpaceGeometry`). A form fill
  is always rebased, being addressed by name.
- Otherwise it keeps its own revision and the engine refuses it as `Stale`. The reader sees "the document changed,
  try again" (`EditFailure`, `Strings.documentChangedTryAgain`) and the change leaves nothing on the undo manager.

Adding a comment appends it to its page's list, so it shifts nothing and edits worked out before it still apply.
Strokes drawn and not yet added are worked out against the revision they were drawn on (`workedOutAt`), so ink
drawn before a rotation is refused rather than placed turned. Undo and redo take no revision: they move the
engine's stack, and the queue keeps that in order.

### 7. Comments are addressed by position, and `DeleteAnnotations` deletes by object

`AnnotationInfo.index` is the comment's **position in its page's `/Annots` list**
(`core/editinpdf-core/src/annotations.rs`), because that is how the engine addresses a comment
(`DeleteAnnotation { page, index }`). The list the app sees skips replies, is sorted by page, then top to bottom,
and the `index` of each is not that order. A position moves when an earlier comment on the page is deleted, and with
every undo and redo, so the app reads all comments again after every revision (`EngineState.read`,
`AnnotationIndex`) and any edit that names a position is only good for the revision it was worked out at: section 6.

Deleting several comments by position is the one case where this breaks down inside a single step. The engine's
delete takes out the comment together with its pop-up and its replies, wherever they are listed, and those have
places of their own that can come before the comment. So deleting the highest place first is not safe, and no
order of "delete place N" edits is sure to remove the comments meant. `Edit::DeleteAnnotations { page, indices }`
(`annotations::deletes`) therefore follows each comment **as the object it is**:

1. It reads the page's `/Annots` from the working file, as the engine does, refuses a place the list does not have
   and any comment the file locks (the whole change, as the engine would refuse a locked delete), sorts the places
   and drops duplicates.
2. It keeps a copy of the list, entries tagged with their place before the step and the object they point at.
   For each target, in order: if an earlier delete already took it out as a pop-up or reply, skip it; otherwise
   emit the engine's `DeleteAnnotation` at the entry's **current** position in the copy, then remove from the copy
   what the engine will remove (the target, every entry that replies to or is the pop-up of one removed, and the
   pop-up chain of each).
3. The deletes go as one engine `Batch`: one revision, one undo step.

Because the places are read against the list before the step, no other edit in the step may address a comment of
that page by its place (section 5). The eraser (`DocumentModel.eraseEdit`) sends a single `deleteAnnotations`; the
Comments list and the delete button send a single `deleteAnnotation`, which is fine on its own.

## Consequences

- Undo, redo and autosave stay consistent however fast the reader taps, and a refused change is never on the undo
  stack. The price is a protocol with several moving parts (token, entry, queue, counter) that has to be kept
  whole: a new kind of change goes through `enqueue`, never straight to the engine. A failure of the engine's own
  undo empties the undo manager's stack rather than guessing, so the reader loses their Undo history there.
- Nothing calls the engine on the main actor, so a long autosave never freezes the screen. A change is published
  only after the jobs before it, so the screen can lag behind the reader's taps by the queue's length.
- The user's file keeps its original bytes, and a failed write loses nothing. A long session's autosaves each write
  the original plus the whole update; shrinking it would take a full save, which the app does not offer yet.
- Every addressed edit is right for exactly one revision. Most are rebased and a few are refused as `Stale`, the
  alert being the price for never editing the wrong page or comment. The rebase rule is a list of what can shift
  an index or a point: **a new `Edit` must be added to `shift(of:)`, `hasViewSpaceGeometry` and the bridge's
  predicates** (the Swift `switch`es and `edit.rs` are exhaustive, so the compiler says where).
- Because the engine has no stable comment identity, `DeleteAnnotations` re-derives the engine's delete in the
  bridge. It depends on how the pinned PdfCraft release treats pop-ups and replies (`pdfcraft_annot::delete_annotation`);
  `core/editinpdf-core/tests/delete_annotations.rs` pins the cases (pop-ups and replies listed before the comment,
locked comments, encrypted files), and `make update-upstream` re-runs it.
- A snapshot is live, not a copy. SwiftUI can ask for one, and write it a little later, while a change is on its
  way. The wait in `savedBytes` covers the changes the app knows about; one that arrives after the wait is in the
  next autosave.
