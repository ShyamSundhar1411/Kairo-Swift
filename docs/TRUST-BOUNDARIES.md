# Who is trusted, by what, and on whose word

Written because somebody asked a question the code could not answer out loud:
**does the watch authenticate?**

It does not, and it does not need to - but "it does not need to" was an
assumption nobody had written down, which is the same condition the
`stewardVetoed` edge was in. An assumption that is only in somebody's head is
not a design decision, it is a thing that happens to be true until it isn't.

## The three legs

| Leg | Carried by | Proves identity how |
|---|---|---|
| watch → phone | WatchConnectivity | **iOS pairing.** Not a credential this project issues. |
| phone → backend | HTTPS + bearer token | `KAIRO_AUTH_TOKEN`, Keychain, `Authorization:` header |
| backend → model provider | HTTPS + provider key | the provider's own key, never on a device |

## The watch does not talk to the backend at all

Checked rather than assumed: `mobile/watch/KairoWatch/` contains **no**
`URLSession`, no `URLRequest` and no URL of any kind. It imports `Foundation`,
`KairoKit`, `Observation`, `SwiftUI`, `WatchConnectivity` and `WatchKit`. The
only `http://` strings in that directory are the DOCTYPE lines in two plists.

So there is no missing watch credential. The phone is the sole client of the
backend, and the watch is a remote control for the phone.

## AS-15 - the assumption this rests on

> **AS-15** A watch paired to the phone by iOS is the primary user's own watch.
> Anything it sends over WatchConnectivity - a water tap, a nudge response - is
> attributed to that user without the watch presenting a credential of its own.

This is sound, and it is worth being explicit about *why* rather than waving at
Apple:

- A `WCSession` exists only between one phone and the watch paired to it. The
  pairing is established by iOS at setup time, and an app cannot opt into
  receiving messages from an arbitrary device.
- The transport is encrypted by the OS between two devices the user physically
  holds. It is **not** TLS, so NFR6's "TLS 1.3 in transit" covers the phone →
  backend leg; this leg is covered by a different mechanism and the report
  should say so rather than letting one claim appear to cover both.
- The blast radius if the assumption fails is bounded by what the watch can
  actually say. `WristEvent` is a closed enum: log water, answer a nudge, ask
  for a refresh. It cannot read habit memories, move the cost ceiling, reach a
  decision record or speak to an agent. The phone validates the wire version
  (`WristSync.version`) and de-duplicates every sip by id, so a replayed message
  changes nothing.

**What would break it:** a shared or family watch, which AS-3 already rules out
of Stage 1 ("one account represents one adult primary user"). AS-15 is the watch
half of AS-3 and should sit beside it in the report.

## What this is not

It is not an argument that the watch leg needs a token. Issuing one would mean
storing a credential on a second device to re-prove a fact iOS has already
established cryptographically, and the honest version of that work is one line
of prose rather than a key in a second Keychain.

It *is* an argument that the pairing is a trust boundary and should be visible
to the person relying on it - which is why onboarding now has a page about it
rather than leaving the watch to appear, unexplained, in a status chip.

## Still open

- **AS-15 is not in the submitted report.** It belongs in Table 19 beside AS-3.
  Raise it for Stage 2 rather than editing a handed-in document.
- **NFR6's wording covers one leg and reads as though it covers all three.**
  Worth a sentence in Stage 2.
