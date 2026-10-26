# ADR 0002: How edits, undo and saving fit together (M2–M3)

- Status: accepted
- Date: 2026-10-21 (section 3 revised 2026-10-24: saving is the reader's choice, no autosave)
- Context: M2 and M3 of the design spec turn the viewer into an editor: page organizing, markup, forms and
  signing, with Undo and Redo and a save that must never damage the user's file. Spec:
  `docs/superpowers/specs/2026-10-15-editinpdf-ios-design.md` (section "M2–M3 scope update"). Plan:
  `docs/superpowers/plans/2026-10-18-m2-m3-editor.md`.

## Context

Three things pull against each other.

- **SwiftUI's document scene wants a simple contract.** `DocumentGroup` with a `ReferenceFileDocument` asks for a
  snapshot, then writes it with `fileWrapper`, and autosaves (on a timer, as the document closes, as the app goes
  to the background) whenever its undo manager says the document changed. It has no idea that the real document
  lives in a Rust engine behind a lock. The owner wants no autosave at all: the file changes only when the reader
  chooses Save (section 3).
- **The engine keeps its own history.** `PdfDocument.undo()` and `redo()` (`core/editinpdf-core/src/document.rs`)
  take no argument: they move the engine's stack, whatever is on top. The app's undo manager has to stay in
  step with it.
- **Edits name their target by position.** An edit says "page 3" or "the comment at place 2 of page 1", and
  points are in view space (page rotation applied). Any change in between can make those mean something else.
  The reader can tap faster than the engine answers, and the engine's save holds the document's lock for the
  whole write, so changes, undos, redos and saves must not call the engine on the main thread (the few quick
  reads made there are listed under Consequences).

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
   order, however fast the reader taps. The undo manager is the model's own, not the scene's, so the
   registration does **not** make `DocumentGroup` autosave (section 3).
3. It hands the edit to the queue. When its turn comes, `apply` asks the engine. On success it sets
   `token.applied = true` and publishes. On refusal it shows an `EditFailure` and **takes the entry off again**
   with `removeAllActions(withTarget: token)`.

Running an undo manager entry does two things at once: it registers the opposite entry (so an undo can be redone,
and that redo undone), and it hands `move(step, token)` to the queue, behind everything handed over before it. An
undo tapped while its edit is still waiting therefore undoes that edit once it has been made, never an older one.
When `move` runs, it does nothing if `token.applied` is false (the engine refused the change). If the engine fails
to undo or redo, the two histories no longer match: every live token's entries are taken off the undo manager
(`liveChanges`, a weak table) and the reader is told. The same goes for a change the engine fails half way
(`EditError.Failed` from `apply`, which may have changed the document and moved the revision on): `apply` takes
every live token's entries off, not only its own.

The engine keeps only the last 100 changes (`MAX_UNDO` in the pinned PdfCraft release; `PdfDocument.undo` says
so), and the model tells the undo manager to keep as many (`levelsOfUndo`, `DocumentModel.undoLimit`), so that
Undo is off past them rather than a tap that does nothing. A group of the undo manager can hold more than one
change, though: typing in a form field and then tapping a checkbox in the same turn of the run loop are one undo
step, which is accepted. So the undo manager can still hold a change the engine has no step for. An undo past the
engine's history finds `NothingToUndo` (and a redo, `NothingToRedo`): that is no mismatch, only a change the
engine has no step for any more, so `move` takes that token's entries off, quietly, with no alert, and the rest of
the history (what can be redone, above all) stays.

**The ways to the undo manager.** Strokes, or text typed in a text box or a form field, waiting to be added are
not on the undo manager, so whatever undoes must add them first, or the undo moves the engine's history under
them and they are refused as stale when they come. The toolbar's Undo and Redo and the Edit menu's (the iPad's
menu bar, and ⌘Z and ⇧⌘Z on a hardware keyboard: `UndoRedoCommands`, in place of the system's group, which acted
on the scene's undo manager directly, ⇧⌘Z even while the toolbar's Redo was off) go through `DocumentModel.undo`
and `redo`, which add what waits first, under one rule (`UndoAvailability`). While a stroke is being drawn they do
nothing: what waits cannot be added before the stroke is over without cutting it, so an undo then would take back the
change before the strokes, and the strokes, added a moment later, would clear Redo; adding them at once, as the
closing paths do, would cut the stroke being drawn and undo the drawing under the pen. The menu names the change each makes, as
the system's did ("Undo Add Markup"), by the same rule: what waits, when something does, else the undo manager's
last change (`undoTitle`, `redoTitle`). The commands find the document through
`FrontDocument`: SwiftUI's focused values never reached them from a document scene's view. Each screen says which
scene it is shown in, and the document in front is the one shown in the key window's scene, found again as a
window becomes key and as a command runs; not the scene that became active last (two side by side on an iPad are
both active, and only the key window takes the keyboard's commands), and none when the key window shows the
document browser. While a field outside the pages is typed in (the search, a
note), they are that field's, as in any field. Shake to undo and the three-finger undo gesture act on the first
responder's undo manager. On the iOS 26.5 simulator that was never the scene's: a shake with strokes waiting and a
change to undo brought no alert, and the first responder, logged every two seconds, was none (on an iPhone and an
iPad), but for the text box and form field editors, whose undo managers are their own. An undo that reaches the
scene's undo manager some other way meets what section 6 does with strokes and text refused as stale.

The engine's undo has no identity, only order. The token's job is to make sure that the undo manager never holds
an entry the engine has no step for, and that the order of entries is the order of steps.

`EngineHandle.editWillStart` and `editDidFinish` count the jobs handed over and not finished, so that a save can
wait for them (section 3).

### 3. Saving is the reader's choice: Save, Save As or Discard

Nothing is written to the user's file but by **Save** (the More menu, ⌘S). Back with unsaved changes asks
"Save changes to “name”?" with **Save** (the default, Return: write, then close), **Save As…** (the exporter the
More menu's Save As… puts up; once the copy is saved the document closes and its file is as it was; cancelled, the
document stays open), **Discard Changes** (close; the file is as it was at the last Save) and **Cancel**. Back with
nothing to save closes at once. The File menu's Close (⌘W, `AppDelegate.buildMenu` replaces the system's
`performClose:`, which would close at once) and VoiceOver's escape on the pages
(`PageScrollViewController.accessibilityPerformEscape`) go through the same question; elsewhere VoiceOver's
escape reaches the navigation controller, whose back action is ours. "Edited" under the document's name says a
Save is needed: SwiftUI's `navigationSubtitle` (iOS 26), set again by `DocumentHost` whenever the document's view
controller resets its navigation item; beside the page indicator before iOS 26. The File menu's Save is added
after the system's items (`CommandGroup(after: .saveItem)`): replacing them took Close away. Duplicate, Rename
and Move (the document's title menu) are the system's: **Duplicate copies the file as last saved**, without the
unsaved changes.

**What counts as unsaved.** `DocumentModel.historyPosition` moves +1 for each change and redo the engine makes
and -1 for each undo; `savedPosition` is where it was at the last Save (0 when opened). Unsaved means the two
differ, so undoing back to the saved state counts as no change. A new change made over undone ones drops the saved
state when it was among them (`savedPosition = nil`: it cannot come back), and so does a step that failed half
way and moved the revision on (`refreshIfMoved`) or a recovery copy restored. `needsSave` adds what waits to be
added (strokes, typed text): Back and Save add it first (`commitPendingInk(closing: true)`, then
`addEverythingWaiting`, shared with Save As), so Save, Save As and the recovery copy include it.

**The mechanism, and why.** `DocumentGroup`'s `UIDocument` (`FileWrapperPlatformDocument`, observed on the iOS
26.5 and 27.0 simulators) saves whenever its change count says it is edited, and that count is fed by its undo
manager, which is the scene's `@Environment(\.undoManager)`. Three ways were weighed:

- (a) keep the scene's undo manager, and have every write the user did not ask for return the last-saved bytes.
  The system would still rewrite the file (a new modification date, a sync of the same bytes to the file's
  provider, a coordinated write while the reader works), and the last-saved bytes would have to be held in
  memory or read back.
- (b) **chosen:** the model registers its changes with an undo manager of its own (`DocumentModel.undoManager`,
  `ownUndoManager`), so the scene's document never counts an edit, never looks edited, and never saves on its own:
  not on its timer, not as the document closes, not in the background. Save asks it to write
  (`SceneDocumentWriter`: `UIDocument.save(to:for: .forOverwriting)`). The toolbar's Undo and Redo and the Edit
  menu's (⌘Z, ⇧⌘Z, `UndoRedoCommands`) already went through the model; the screen now reads the model's undo
  manager for their state. Lost: the system's own undo gestures (shake, three-finger swipe), which act on the
  responder chain's undo manager; they never went through the model's rule for what waits anyway.
- Where that cannot work, saving is the system's, as before (`SavingMode.automatic`, decided once by
  `DocumentHost.decide` as the screen first appears): when no `UIDocumentViewController`, document or back action
  is found (a system that shows documents otherwise; only iOS 26.5 and 27.0 were available to test), the model
  registers with the scene's undo manager (`DocumentModel.adopt`), every write writes the changes
  (`EngineHandle.writesAutomatically`), Back is the system's and 05aaefc's `countChangeNow` tells the document of
  what Back hands over; no "Edited", no Save item, no recovery copy. A reader is never left unable to save.
- (a) is kept as a second line of defence: the snapshot carries whether Save asked for the write
  (`EngineHandle.beginExplicitSave`, read in `snapshot(contentType:)`), and `fileWrapper` hands any other write
  the existing file as it is (`PDFFileDocument.bytesToWrite`, `leavesTheFile`). Only a file not written yet (a
  new document's first write) gets the engine's bytes without Save.

**Back.** The navigation bar's back button is the system's (look, name, `BackButton` identifier, reach by
VoiceOver and keyboards are unchanged). Its action is taken over: `DocumentHost` finds the
`UIDocumentViewController` up the responder chain, keeps its `navigationItem.backAction` and puts one of its own
in its place (taken over again whenever SwiftUI sets a new one); once the reader has chosen, the system's action is
run with `UIControl.sendAction(_:)` and closes the document the system's way. The document's controller is the
only one in its navigation stack, so no edge swipe pops it past the question. The back action is looked at again
whenever the toolbar changes (`DocumentHostAnchor.toolbarState`) and whenever the item's back action is set (KVO).
Where no such action is found, the document is saved the system's way (above). For an explicitly saved document
05aaefc's `countChangeNow` is not needed (there is no close-time autosave, and Back adds what waits before it
asks); it is kept for the automatic case.

**The write.** The snapshot is the engine document (`PDFFileDocument.Snapshot.document`), so taking it costs
nothing; the write, `save(mode: .incremental)`, runs in `fileWrapper`, which SwiftUI calls on a background queue
(observed off the main thread on the iOS 26.5 simulator). The bridge's lock means the write sees whole edits. Save
adds what waits and waits for the queue (`settle`) first; `savedBytes(of:)` still waits, off the main thread only,
up to 10 s for jobs counted by `EngineHandle` that arrive as the write starts, and logs a warning if it gave up.
Changes made while Save writes stay unsaved (Save marks the position it settled at). A failed write leaves
everything unsaved and says so (`Strings.saveFailedTitle`). A file that is locked or could not be read has no
engine document in the handle, and its snapshot is refused with our own message, so it is never written.

**Recovery.** iOS can end the app in the background, and a scene can be closed from the app switcher or a
window's close button with no prompt, so unsaved changes are also kept in a recovery copy (`RecoveryStore`):
`Application Support/Recovery/<SHA-256 of the file's path>.pdf`, the engine's incremental save (a protected
file's copy keeps its password), with file protection complete unless open (a write begun before the device locks
can finish), excluded from backup. It is written after five seconds without a change, undo or redo (the write
holds the engine's lock, a while on a big file), as the scene goes inactive, and as it goes to the background or
off the screen (what waits added first, the note being written too, in a background task); never with nothing
unsaved. When the same file opens again and a copy is there (`findRecoveredChanges`), it is never dropped without
the reader's word: if it was written after the file last changed **and starts with the file's bytes** (every save
appends to them), the app asks "Restore unsaved changes?": **Restore** opens the copy (with the password the file
was opened with) in place of the document, every change unsaved, the file still unwritten (a copy that cannot be
opened says so); **Discard** deletes it. Otherwise (the file changed on disk since, or was rewritten in full) the
app says "Unsaved changes from an earlier version of this file were kept" and offers **Save As…** (the copy as it
is, through the exporter) or **Discard**. Put away with the system's Cancel, either offer keeps the copy
(`recoveryHeldKeys`): this session neither overwrites nor deletes it, and writes its own copy beside it, under the
next slot of the key (`RecoveryStore.slots`: `<key>`, `<key>-2`, `<key>-3`), so a crash loses neither; on the
next open every copy is offered, the newest first, one at a time, and after a Restore the others only as copies
(Save As… or Discard). A session deletes only a copy it wrote or restored (`recoveryOwnedKey`): on
Save, Discard Changes, a saved Save As, or closing with nothing unsaved (`recoveryEpoch` drops one being written
meanwhile). Copies older than 30 days are swept at launch. Nothing of a document is logged. The copy is found by
the file's path, so a file renamed or moved while the app was stopped is not matched (its copy is swept after 30
days). While the document closes (`isClosing`, set only as the close starts) no copy is written. If the
system's back action leaves the document open (3 s later its controller is still in a window and its document not
closed), SwiftUI's `dismiss` is tried; only if that leaves it open too is `isClosing` cleared and the copy written
again, so the reader is never stuck in a document that will not close (UI test with a DEBUG hook that makes the
system's action do nothing).

`EngineHandle` (`ios/EditinPDF/Document/EngineHandle.swift`) is what the file document and the model share: a
lock-guarded slot for the document, the counter of jobs on their way, whether Save is writing, and whether every
write writes the changes (the automatic case). The model
fills the slot when the file opens, on `unlock`, and when a recovery copy is restored.

### 4. There is no `markSaved`

The design spec listed `markSaved()`. The engine has the equivalent (`Session::mark_saved`, which reopens the
engine's working file from the saved bytes, clears the dirty flag and rebases the next save on them), and the
bridge deliberately does not expose it. `PdfDocument.save` says so: it "does not mark the document as saved", and
`is_dirty` stays true after a save.

So **every save is the file as it was opened plus one appended update holding every change made since**
(`Session::save_bytes`, "an incremental update of the file as opened/last saved"). The user's original bytes are a
prefix of what is written, which is what makes Save safe for files the app did not make. An unchanged document
comes back as the engine holds it: the bytes as opened, except for an XFA form, which the engine may lay out or
fill in from its XFA data as it opens it, and holds with that appended (the original bytes still come first). The
other consequence is the safety property: nothing ever tells the engine that a write succeeded, so a write that
failed, or that the system could not finish, can never leave the engine believing the file holds changes it does
not. The next save simply writes all of them again. The cost is that an update holds the whole session's changes
rather than only the newest, which is small next to rewriting the file (`SaveMode.full` exists in the bridge for a
later "optimized copy", and refuses a signed document; the app does not use it yet). Save As (`DocumentModel.copyBytes`) writes this same incremental save, once what waits is
added through the closing path and the changes on their way are made, to a file the reader picks with the system's
exporter: the copy of a password-protected file keeps its password, and the document stays open, its changes
still unsaved in its own file (or, from Back's Save As…, closes with its file as it was).

One kind of file is the exception. When the file's cross-reference data cannot be read, the object layer rebuilds
it from the objects' headers as the file opens (`pdfcraft_cos`), which leaves no revision to append to, and its
incremental write falls back to a full one. The bridge finds this out when the document opens (where each revision
ends, and only when it finds none, a second read of the file) and reports it as
`EditCapabilities.rewrites_on_save`. An unsigned such file stays editable: the first save of a change writes it out
in full, a whole, repaired copy of what the reader sees, and the README says so. A **signed** one would lose its
signatures with that save, with nothing refusing it, so the bridge refuses every change to it (`ReadOnly`, the
capabilities all false, a `read_only_reason`) and, as a second line of defence, every save that would write a
change or rewrite it (`Signed`); unchanged, its incremental save is the bytes it was opened from. The app
says why in one sentence of its own (`Strings.signedDocumentDamaged`), in place of each tool's own refusal
(`DocumentModel.signatureLock`).

### 5. What `apply_all` refuses to mix

`apply` makes one change. `apply_all(label, edits, base_revision)` makes several, in order, as one engine step
(`Edit::Batch`): all or none, one revision, one undo step (`document.rs`, `edit.rs`). It refuses, as `Invalid`:

- no edit at all, or more than 10,000 (`MAX_STEP_EDITS`);
- **a page-structure edit with an edit that carries a point or a box** (`is_page_structure` with `has_geometry`).
  Every edit of a step is converted from view space to the file's space against the document **as it is before the
  step** (`to_engine` is given that one document). After a turn, a delete, a move or an insert, a later edit's
  "view space" would be a different place. So the app cannot turn a page and draw on it in one step;
- **an edit that renumbers pages with an edit that addresses a comment** (`renumbers_pages` with
  `addresses_annotation`: delete, move or change the text of a comment). Those name the comment by page number and
  place, read before the step. A turn does not renumber, so a turn with a change of a comment's text is allowed;
  a turn with a move is already refused by the previous rule, because a move has a distance in view space;
- **a delete of a comment (`DeleteAnnotation` or `DeleteAnnotations`) with any other edit that addresses a
  comment of the same page by its place** (`annotation_places_check`), another delete included, for the reason in
  section 7. `RestyleTextBox` counts as a delete here: a new text size or background deletes the text box and
  adds it again (section 7). Adding a comment (it goes at the end of the list), changes to other pages and form
  fills are fine; so a delete and a new text box of the same page (`[DeleteAnnotation, AddTextBox]`, the new box
  placed by its box, not by a place) make one step.

Filling a form field is addressed by the field's name (`FormField.name`), which no change to pages or comments
alters, so `SetFieldValue` mixes with anything. Names are checked against the fields as they are before the step
(`field_check`), so a field that pages inserted by the same step bring in can be filled from the next step on.

The app stays inside these rules by construction: a multi-page delete is one `deletePages` with a list, an
eraser stroke is one `deleteAnnotations`, and a long Pencil drawing that exceeds the bridge's ink caps becomes
several `addInk` edits of one step (`ios/EditinPDF/Markup/InkGeometry.swift`). Every other change is a step of one
edit, and `DocumentModel.enqueue` hands over no empty step. The rules exist so that a mistake in the app is refused
with `Invalid` instead of changing the wrong thing.

The bridge also caps what one edit carries, so a hostile or mistaken caller cannot make the engine lay out or keep
without bound: a comment's, a text box's or an information entry's text at `max_text_chars()` (100,000 characters;
a form field's text has its own cap of 10,000), and one text markup at 10,000 boxes. The text box and note editors
hold what is typed or pasted to the same cap (`ShapeGeometry.limitedText`), so the reader is never refused for it.

### 6. Revisions, `Stale`, and the rebase rule

`PdfDocument.revision()` is 0 on open and goes up by one after every edit, undo or redo that succeeds (and after
a `Failed`, which may have changed the document: the apps are told to read it again). `apply` and `apply_all` take
the revision the edit was worked out for: under the lock, `mutate` compares it with the current one and, if they
differ, does nothing and returns `EditError::Stale { current }`.

The app does not want every second tap to fail just because the first has not been published yet, so
`DocumentModel.apply` decides, when the change's turn comes, whether it may be **rebased**: sent with the current
revision instead of the one it was worked out at. `canRebase` says yes when nothing since could have made it
mean something else:

- A change can shift three things an edit worked out before it depends on (`EditShift`): **page numbers**
  (deleting, moving or inserting pages), the **places of a page's comments** (deleting or moving a comment, and
  restyling a text box, which may delete it and add it again at the end of the list), and
  **points in view space** (turning pages). `shift(of:)` says which for a change. Adding a comment appends it to
  its page's list, so it shifts nothing.
- An undo or a redo shifts what its own change did, the other way (`undoShift(of:)`, kept on the change's token,
  since the edits themselves can carry a PDF's bytes), and for a change that adds a comment, the places too: its
  undo takes the comment off the end of its page's list. Nothing more: the undo of a highlight moves no page and
  no point, so strokes drawn meanwhile, or a shape being dragged, are still good.
- The model keeps the revision of the last shift of each kind (`Shifts`).
- An edit depends on (`dependence(of:)`) the page numbers when it names a page (every edit but a form fill and
  the document's information), the places when it names a comment (delete, move, change its text, restyle a
  text box), and the
  points when it carries a point or a box in view space (every added comment, and a move).
- An edit worked out at revision `base` is rebased when no shift it depends on was made after `base`. A form
  fill is always rebased, being addressed by name.
- Otherwise it keeps its own revision and the engine refuses it as `Stale`. The reader sees "the document changed,
  try again" (`EditFailure`, `Strings.documentChangedTryAgain`) and the change leaves nothing on the undo manager,
  except for what was waiting to be added, below.

Strokes drawn and not yet added are worked out against the revision they were drawn on (`workedOutAt`), so ink
drawn before a rotation is refused rather than placed turned. Undo and redo take no revision: they move the
engine's stack, and the queue keeps that in order.

Strokes and typed text refused as stale are not lost (`enqueue`'s `whenStale`). The model knows what each change,
undo and redo did to which pages (`PageEffect`: from which page on the pages were renumbered, which were turned; a
failure counts as everything) and so whether a page is still the page it was at a revision, as it was
(`pageIsUnchanged`, over the last 256 such changes, `PageMoves`). When it is, refused strokes go back on the canvas,
waiting where they were drawn (`InkInteraction.putBack`), or, when the canvas cannot take them (Draw put down, the
screen gone, a stroke being drawn on it), are handed over again for the page as it is now, which is the same; a
text box's text is handed over again. Handing them over adds what waits first, but the strokes on a canvas a stroke
is being drawn on are not added, nor the canvas emptied or moved, then: that would cut the stroke. They wait
until it is over (PencilKit puts a stroke on the drawing a moment after it ends using the tool), and are added with
it. The paths after which the document or the screen may go first (Back touched, the scene leaving the screen, the
screen going, focus leaving the pages) do not wait: they add the strokes drawn at once and may cut the stroke being
drawn, since losing strokes drawn would be worse (`commitPendingInk(closing:)`). When it is not, the reader is told the drawing was not added (`Strings.drawingNotAdded`); a text box's text,
like the changed text of a text box another change numbered again, is put on the pasteboard, and the reader is
told so (`Strings.typedTextCopied`). It goes there as plain text for this device only (`DocumentModel.keepLocally`,
`.localOnly`): the reader did not copy it, so Universal Clipboard does not hand it to their other devices.

### 7. Comments are addressed by position, and `DeleteAnnotations` deletes by object

`AnnotationInfo.index` is the comment's **position in its page's `/Annots` list**
(`core/editinpdf-core/src/annotations.rs`), because that is how the engine addresses a comment
(`DeleteAnnotation { page, index }`). The list the app sees skips replies, is sorted by page, then top to bottom,
and the `index` of each is not that order. A position moves when an earlier comment on the page is deleted, and with
the undo or redo of a change that adds, deletes or moves one, so the app reads all comments again after every
revision (`EngineState.read`, `AnnotationIndex`) and any edit that names a position is only good for the revision
it was worked out at: section 6.

Inside a single step, deleting comments by position is where this breaks down: every edit of a step names its
comment by its place before the step, and a delete moves the places after it. Among the edits the app makes, it
matters when several comments of a page are deleted at once (the eraser). The engine's delete takes out the comment
together with its pop-up and its replies, wherever they are listed, and those have places of their own that can
come before the comment. So deleting the highest place first is not safe, and no order of "delete place N" edits
is sure to remove the comments meant. `Edit::DeleteAnnotations { page, indices }` (`annotations::deletes`)
therefore follows each comment **as the object it is**:

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
that page by its place; the same holds for a step with a `DeleteAnnotation` (section 5). The eraser
(`DocumentModel.eraseEdit`) sends a single `deleteAnnotations`; the Comments list and the delete button send a
single `deleteAnnotation`, which is fine on its own.

**Restyling a text box.** The engine changes a text box's colour and border in place (`StyleAnnotation`), but
has no change for its text size or its background. `Edit::RestyleTextBox` (`annotations::restyle_text_box`)
therefore makes, as one engine `Batch` (one revision, one undo step), either the in-place change, when the size
and background stay, or the engine's `DeleteAnnotation` of the text box followed by `AddAnnotation` of a new one
with the same text and author, its top-left corner where it was, as wide as keeps its lines (the room across
scaled with the size, no further than the page's right edge) and as tall as its text then needs. The new one goes
at the end of the page's list: the places after the old one move down, as after a delete, which is why the
mixing rule and the rebase rule treat a restyle as a delete. It loses what the engine does not set on a new
comment: its name (`/NM`), creation date, pop-up, opacity, alignment and rich text, and it is drawn over the
others. The
bridge refuses a locked text box, a re-add on a page shown turned (its text would be set upright in the file),
and a re-add that would lose more (`re_add_refusal`: a callout or typed text, which a plain box would replace; a
box with replies, which the delete would take out; one whose text is all rich text); such a box keeps its colour
and border changes in place, and the list says so (`AnnotationInfo.restyle_in_place_only`). A size or border the
app does not ask for (`None`) is the box's own, kept as the file has it, so a colour change never resizes a box
or adds it again. A restyle that changes nothing (a colour read back in single precision, say) is refused as
`Invalid`, so no empty step reaches the history. "Nothing" is to within `look_tolerance()` (under 0.004: a
colour's component, a size or a border), which the bridge exports and the app compares looks by too
(`RGBA.matches`, `TextBoxFormat ==`), so the app never sends one: the two sides cannot disagree about a change. The text size, background and border the app starts from are read from the file
(`AnnotationInfo.font_size`, `fill`, `border_width`, `annotations::with_text_box_looks`), as the engine draws
them: that read of the file is made only when the document has a text box. Each comment's date as the file
writes it, with its time zone, is a separate call (`PdfDocument::annotation_dates`), which the app makes only
while the list of comments is up, off the main thread: reading every comment's dictionary again at every
revision cost tens of milliseconds on a large file.

### 8. Taking a highlight, underline or strikethrough off part of its text (0.2.3)

Highlight, Underline and Strikethrough work like a word processor's (`ios/EditinPDF/Markup/MarkupToggle.swift`,
`DocumentModel.markSelection`):

- **What is marked.** A glyph has a mark when the middle of its box is in one of the mark's quads. Spaces and
  glyphs with no box do not count. The bridge lists each mark's quads in view space (`AnnotationInfo.quads`).
  Every number is held finite and within 1e6, as `rect` is. A mark gets **all of its quads or none**: none past
  10,000 quads, or past 100,000 for the whole list. So the app never takes part of a mark for all of it and cuts
  it short. A mark listed with none covers nothing, so it can only be added to.
- **What each gesture asks** (`MarkIntent`):
  - The palette, and the current tool picked again, *toggle*. All of the selection has the mark: it comes off
    the selected glyphs. Otherwise the glyphs without the mark are marked.
  - A drag with the tool, and the menu's Highlight, Underline and Strikethrough, only *add*. They mark the
    glyphs without the mark, never over one of the same kind, and never take one off.
  - The menu's Remove items only *remove*. The menu offers "Remove …" only when every counted glyph is covered
    and an unlocked mark is among those that cover it. Until the app knows that, it offers Copy alone, so a
    title never says other than what its item does.
- **How a mark comes off.** In one `apply_all`, named "Remove Highlight", "Remove Underline" or "Remove
  Strikethrough":
  - `DeleteAnnotations` deletes every unlocked mark of that kind that covers a selected glyph.
  - `AddTextMarkup` adds back what each mark covers outside the selection: one piece before it and one after,
    each with the line boxes the engine gives a selection of those glyphs. A piece keeps the mark's kind and
    colour, and its opacity through `opacity_of`. `opacity_of` names the mark by its place before the step.
    The bridge reads every opacity of the step with one read of the file, before any change, so a piece may
    name the mark the same step deletes. The mark's comment goes on the first piece only.
  - One undo puts the whole mark back. The step depends on the page's annotation places. The app also refuses
    a plan worked out from the page's marks when a change queued before it deleted or moved one
    (`ChangeAtItsTurn.stale`, through `stillNamesTheSame`), even when the plan only adds.
- **What a cut-short mark loses.** The pieces are new comments. They lose the mark's author, name (`/NM`),
  creation and modification dates, subject, pop-up and any other entry the engine does not write for a new
  markup, and the second piece loses the comment's text. A comment longer than the bridge's 100,000-character
  cap is cut to it.
- **Refusals.**
  - A mark the file locks is never deleted or cut. Text covered only by locked marks gets
    `Strings.editNotAllowed`.
  - A mark with replies (`AnnotationInfo.has_replies`, an `/IRT` naming its `/NM`, read from the engine's list)
    is never cut short, since deleting it deletes the replies (`Strings.markHasReplies`). One wholly inside the
    selection comes off, replies and all, as Delete takes it off.
  - When the page's text cannot be read, a toggle or a remove changes nothing; only an add marks the selection
    as it is.
  - A selection too large to work out (4,000,000 glyph-to-quad looks, 1,000 runs) is marked as it is by an add
    or a toggle, and refused by a remove.

## Consequences

- Undo, redo and the unsaved count stay consistent however fast the reader taps, and a refused change is never on the undo
  stack. The price is a protocol with several moving parts (token, entry, queue, counter) that has to be kept
  whole: a new kind of change goes through `enqueue`, never straight to the engine. A failure of the engine's own
  undo empties the undo manager's stack rather than guessing, so the reader loses their Undo history there.
- Changes, undos and redos and the reads after them never call the engine on the main actor, and the write was
  observed to run off the main thread, so a long save does not freeze the screen. A few quick calls do run on
  the main thread: `SelectionWorker.init` reads the revision when the document opens, and a new blank document is
  made there. A change is published only after the jobs before it, so the screen can lag behind the reader's taps
  by the queue's length.
- The user's file keeps its original bytes, and a failed write loses nothing; the exception is a file whose
  cross-reference data had to be rebuilt, which is written out in full the first time it changes (and is read-only
  when signed: section 4). Each Save writes the original plus the whole session's update; shrinking it would take a
  full save, which the app does not offer yet.
- Every addressed edit is right for exactly one revision. Most are rebased and a few are refused as `Stale`, the
  alert being the price for never editing the wrong page or comment; strokes and typed text refused so are kept
  (section 6). The rebase rule is a list of what can shift an index or a point: **a new `Edit` must be added to
  `shift(of:)`, `addsAnAnnotation`, `dependence(of:)`, `PageEffect(of:)`, `OrganizeMath.readerPage`
  (`ios/EditinPDF/Organize/OrganizeMath.swift`, where the reader's page follows page changes) and the bridge's
  predicates** (those Swift `switch`es and the predicates in `edit.rs` are exhaustive, so the compiler says
  where), and to `annotation_places_check` when it deletes a comment (`RestyleTextBox` does).
- Because the engine has no stable comment identity, `DeleteAnnotations` re-derives the engine's delete in the
  bridge. It depends on how the pinned PdfCraft release treats pop-ups and replies
  (`pdfcraft_annot::delete_annotation`); `core/editinpdf-core/tests/delete_annotations.rs` pins the cases (pop-ups
  and replies listed before the comment, locked comments, encrypted files), and `make update-upstream` re-runs it.
- A snapshot is live, not a copy. SwiftUI can ask for one, and write it a little later, while a change is on its
  way. Save settles the queue before it writes, and the wait in `savedBytes` covers a change handed over as the
  write starts, for up to 10 s; one that arrives after the wait stays unsaved, and Back asks about it.
- The file changes only with Save. The price: a reader used to autosave can lose changes by choosing Discard,
  and an app stopped or a scene closed without a choice relies on the recovery copy, offered on the next open
  of the same path. Back's interception depends on SwiftUI's document scene putting its close action in
  `UINavigationItem.backAction` of a `UIDocumentViewController` (iOS 26.5 and 27.0 simulators); without it Back
  closes without asking and the recovery copy is the only net. The system's shake and three-finger undo no
  longer reach the document's history.
- No script a document carries is run. Every engine session the bridge makes has the engine's JavaScript off
  (`document::session`): with it on, every fill would run the field's keystroke, validate, calculate and format
  scripts, and an XFA form its scripts as it opens, with no time or memory limit, under the document's lock. The
  built-in formats and calculations Acrobat writes (`AFNumber_Format`, `AFSimple_Calculate` and the like) are still
  worked out by the engine itself; a form whose own scripts compute values is not recalculated, and the README says
  so.
