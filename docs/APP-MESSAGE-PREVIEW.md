# 0.2.25 Independent App-Message Preview Experiment

## 0.2.25 Hard-Link Compatibility

The 0.2.24 device report reached the link-count guard. The native path remained
inside the app container and identified a regular file of the declared length,
but that file had multiple hard links. Version 0.2.25 accepts hard-linked
regular files while still requiring the native path to remain within approved
directories, rejecting symlinks/traversal/non-regular objects, matching the
declared length, and verifying inode/device/size/link-count/mtime/ctime remain
stable throughout the bounded read. This keeps the path and content checks
without assuming each app-managed file has exactly one filesystem link.

## 0.2.24 Diagnostic Refinement

The 0.2.23 device report reached the native-file metadata gate but its combined
`file_size_or_type_rejected` state could not distinguish a declared-length
mismatch, a non-regular object or a multiple-link file. Version 0.2.24 reports
those outcomes separately (`file_length_mismatch`, `file_non_regular`, and
`file_link_count_rejected`), plus distinct stat/size-unavailable states. It
does not relax any file gate or record a path, actual size, contents or hash in
diagnostics. The parser continues accepting the earlier combined state.

This checkpoint adds an explicitly armed, memory-only preview experiment. It is
not file/link forwarding and does not extend configuration types, ordinary
source envelopes, durable plans, submission claims or any host send adapter.
The separate entry avoids accidentally routing a type-49 payload through the
existing text/image pipeline. Concurrent operations changes are not included.

## Device Evidence And Boundaries

The user's 0.2.22 link and file reports on iOS 16.0.3 / WeChat 8.0.79.35 confirmed
outer type 49, inner type 5 with title/URL, and inner type 6 with title, attachment
ID, extension and length. Both were own-account-to-source-group callbacks. They
do not establish complete card semantics, other-sender behavior, file availability
or any sending ABI. Raw reports and real identifiers are not published.

Offline inspection of the supplied Mikoto 2.5.0 ARM64 binary found the exact
`GetAppAttachmentPath` selector at call sites including 0x2777840/0x2777948 and
0xce49c8/0xce49cc. This is a zero-explicit-argument message call, not proof of the
live receiver class or ABI. The independent implementation therefore uses only
the original candidate wrap's declared zero-argument object/string getter; absent,
incompatible, nil or failing getters stop without KVC, ivars, path synthesis or
downloads. No third-party binary is loaded or packaged.

## Capture And Privacy

- A dedicated arm chooses exactly link or file using saved source group/members.
  Existing text/image selection remains unchanged. Other types do not end this
  experiment or enter normal capture. Only the selected type-49 structure can
  produce the one frozen experimental preview.
- XML retains the same encoding/entity, nesting, element, byte and queue limits.
  Only explicit preview mode collects bounded direct title/URL/extension/length
  fields. The attachment ID and full XML are never retained in the preview.
  Normal structural probes remain body-redacted.
- Link previews require a nonempty bounded title and absolute HTTP(S) URL with
  a host, no credentials, whitespace/control characters or invalid port. No URL
  opening, network request, thumbnail fetching or complete-card claim occurs.
- File snapshots require a positive declared length no larger than 8 MiB. Only
  an existing native path inside this app's Documents, tmp or Library/Caches is
  eligible. No user title, attachment ID or sender is used to construct a path.
- Open directory components through pinned directory descriptors with no-follow;
  reject traversal, outside/sibling containers, symlink components and
  nonregular files. Hard-linked files are accepted only if link count remains
  stable across the read. Read without mmap, bounded to declared length, compare
  exact length/EOF and inode/device/link count/mtime/ctime before and after.
  Copy immutable bytes into memory and compute SHA-256 of that owned copy.
  This detects normal changes but is not an authenticated remote-file checksum.
- Context is revalidated before/after native getter calls, during bounded reads,
  and before accepting the preview: account, arm generation, endpoints, sender,
  type, content equality and optional strict source-time evidence. File reads
  are synchronous on the main thread and may briefly affect responsiveness;
  the 8 MiB cap bounds bytes but is not a hard I/O time limit.
- These previews need no server ID because they are not source envelopes and
  cannot become plans/send requests. They may be old synchronization callbacks;
  normal manual capture does not opt into strict new-message time semantics.
- UI shows link title/URL or file title/extension/byte count/hash. It never
  renders/executes arbitrary documents. The screen has no send/confirm button.
  Clear, stop, account invalidation, editing settings or app inactivity releases
  the owned snapshot. Backing out of the screen hides its text. No file snapshot
  is written to disk, exported or retained across process restart.

## Diagnostic Contract

`receiveCandidate.appMessagePreview` schema 1 includes only constant state/kind,
memory-only/non-relayable flags, file byte limit, exact getter name, getter
presence (not ABI compatibility), and disabled plan/send flags. No title, URL,
path, raw XML, attachment ID, bytes, source identifiers or content hash appears
in diagnostics. Structural samples remove the private-field map before storage.
The report parser uses fixed messages and does not echo untrusted values.

## Device Check

1. Install the independently built 0.2.25 package, restart WeChat, verify version,
   commit and CI run. Use authorized test groups and small nonsensitive fixtures.
2. Save the source group/member configuration. Stop normal waiting, clear any
   ordinary preview, end active rules and turn off old single-send experiments.
3. Under source/plan actions, choose the dedicated link preview entry. Confirm,
   close the panel, send one new link from the selected member, then reopen that
   entry. Check the exact title/URL. No ordinary source preview is expected.
4. Clear the experimental preview. Choose the separate file preview entry. Use
   an already-loaded file no larger than 8 MiB. Send it from the selected member,
   reopen the entry and check title, byte count and hash. A file-path/getter
   error stays waiting: export diagnostics rather than guessing paths or retrying
   sends. The prior report reached the hard-link check; this build accepts the
   same kind of file if all path, declared-size and read-stability checks pass.
5. Export diagnostics while foreground/ready. Opening a share sheet may trigger
   inactivity after report generation and clear the in-memory preview as designed.
6. Test incoming-from-another-selected-member separately. Background/lockscreen
   must clear the preview and require explicit re-arming. No sending tests here.

Native synthetic tests cover parsing/URL gates, account/generation cancellation,
own callbacks without server IDs, redacted diagnostics, immutable byte copies,
ABI traps, size limits, path boundaries, symlinks, stable hardlinks and FIFOs. iOS syntax
and macOS native execution cannot replace UIKit or device validation. File getter
semantics, resource readiness and actual preview screens remain unverified until
the next device reports. Sending/forwarding is separate future work.
