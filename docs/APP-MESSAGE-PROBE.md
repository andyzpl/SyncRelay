# Type-49 App-Message Structural Probe

This is a source-level diagnostic addition, not file/link forwarding support.
It is not included in the already-built 0.2.21 package. The independently built
0.2.22 checkpoint adds this probe; do not rename or replace the old package.

## Scope

- Existing text/static-image capture, previews, plans, storage and send gates
  are unchanged. Type 49 still fails the relay type filter.
- Only an explicitly armed configuration with a selected sender can schedule
  XML inspection. Legacy group-only arms and unselected senders remain body-free.
- Both incoming and own outgoing callbacks can supply diagnostic evidence. The
  server ID requirement is per path, not one uniform identity gate: the incoming
  relay and census path rejects a callback that has no server ID, while on the
  outgoing path the server ID is only the settlement gate of an own type-1
  message.
- An outgoing type-49 callback is observable even when it carries no server ID,
  but it stays a read-only observation: it never becomes a source message, a
  pending readback or a send request. An outgoing type-1 callback without a
  server ID may still be recorded in the type census, but it may only become a
  source candidate after an exact local-ID readback supplies a server ID.
- The main-thread observer rechecks the current account, arm generation,
  endpoints, sender, message type and optional strict time evidence before and
  after reading the declared `m_nsContent` getter. It uses no KVC, ivar fallback,
  guessed media paths, downloads or host sending API.
- No other new media type reads a body or resource getter in this addition.

## XML Contract

The accepted envelope is a single `msg/appmsg` or root `appmsg`. A group sender
prefix is accepted only as the exact validated sender plus `:\n` or `:\r\n`.
The direct child `appmsg/type` must contain a decimal uint32 value. A conventional
subtype of 5 produces a `link` kind hint and 6 a `file` kind hint; all others
produce `other`. These are structural hints, not verified device payload schemas.

The parser records only whether direct title/URL and attachment fields contain
non-whitespace text. It does not validate a URL, confirm a local attachment,
retain a filename/attachment ID, build a payload or establish a send ABI.

Limits and rejection rules:

- Input is bounded before XML encoding, and encoded UTF-8 is at most 128 KiB.
- At most 32 element levels and 1,024 elements are accepted.
- Type text is bounded separately, and numeric overflow is rejected.
- Duplicate appmsg/type/known fields, nested scalar fields and namespaces are
  rejected rather than guessed. Unknown nested type tags cannot set the subtype.
- DTD/entity declarations are rejected before parsing. External entity
  resolution is disabled independently. Parser errors and exception text are
  never exported. Any parser error callback rejects the sample even if the
  Foundation implementation reports a successful parse return value.
- NUL characters and non-UTF-8 XML encoding declarations are rejected before
  parsing, preventing alternate encoding detection from bypassing DTD preflight.
- Each arm reserves at most 16 callbacks before queueing. Excess callbacks do
  not read XML. Results from stale generations or changed identities are dropped.

## Diagnostics

`receiveCandidate.appMessageProbe` has schema 1:

```json
{
  "schema": 1,
  "observerOnly": true,
  "relayable": false,
  "deviceVerified": false,
  "limit": 16,
  "byteLimit": 131072,
  "attempts": 2,
  "dropped": 0,
  "samples": [
    {
      "state": "parsed",
      "subtype": 5,
      "kindHint": "link",
      "hasTitle": true,
      "hasURL": true,
      "hasAttachment": false,
      "hasAttachmentID": false,
      "hasFileExtension": false,
      "hasTotalLength": false
    }
  ]
}
```

This example is synthetic, not a device result. `attempts` counts reserved
callbacks, including callbacks later invalidated by context changes. `samples`
are in processing order, not deduplicated message order. One message can have
multiple callbacks, and samples can be fewer than attempts. No raw IDs, content,
paths, URLs, titles, XML or parser error text are included. A successful subtype
parse cannot imply source capture, preview, media readiness or delivery.

## Verification And Next Device Check

- `tests/app_message_probe_cases.h` is included and invoked by the existing
  native receive-test target; it exercises the production Foundation XML parser
  and receiver against synthetic wraps. It needs macOS to run.
- `tests/app_message_contract_test.py` exercises redacted report triage and source
  contracts only. Python tests and iOS syntax checks do not run Foundation XML
  parsing and cannot replace native tests or device verification.
- Once a separately versioned build has passed native tests, arm text-only
  waiting, send one new file and then one link from the selected source, keep
  WeChat active, and export diagnostics while still waiting. Do not send a text
  terminator first: that ends waiting and can invalidate queued probe samples.
- Inspect subtype, kind hint and presence flags, not just the outer type 49.
  Reject failures stay diagnostic-only. File resources, link payload snapshots,
  actual previews and host submission remain separate future work.
