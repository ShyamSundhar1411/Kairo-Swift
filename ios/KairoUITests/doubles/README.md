# Running `KairoUITests`

Ten tests in `ScreenTour.swift` drive the app against three backend addresses.
Until now this repository shipped nothing to answer them, so none of them could
run - including `testAccessibilityAudit`, which is the only automated check on
NFR11.

```bash
# one terminal
./backend/.venv/bin/python mobile/ios/KairoUITests/doubles/serve.py

# another
cd mobile && xcodegen generate
xcodebuild test -project Kairo.xcodeproj -scheme KairoApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:KairoUITests
```

Screenshots land in `KAIRO_SHOT_DIR` (default `$TMPDIR/kairo-shots`). Set
`KAIRO_TEXT_SIZE=UICTContentSizeCategoryAccessibilityXXXL` to run the whole tour
at the largest text size, which is what `.textClipped` in the audit is for.

## The three ports

| | State | How it gets there |
|---|---|---|
| 8099 | served by agents, metered | scripted provider reporting `METERED` |
| 8098 | served by agents, shadow costing | the same round, provider reporting `SHADOW` |
| 8097 | no backend could be bound | no key in scope, `OLLAMA_HOST` at a dead port |

8088 is deliberately unserved: `testAgentsUnreachable` wants a fine address with
nothing behind it.

**These are not hand-written fakes.** Each is the real `create_app` with a
scripted provider, so the UI runs against the backend's actual contract. A
double that can drift from the thing it doubles is a test that keeps passing
after the contract breaks.

## Why there are tests for the test harness

`backend/tests/test_ui_doubles.py` asserts the three states and the shape of the
round, and it earns its place because **a screenshot harness fails silently**. A
double that answers 200 with an empty round renders as a quiet day rather than
as a broken fixture, and the person looking at the PNG cannot tell the
difference. Two real failures were caught exactly that way while this was
written:

- the role keys were spelled `LifestyleSignalAnalyst`, but the prompt says
  `Lifestyle Signal Analyst`, so no rule matched and every round came back
  empty;
- a `bedtimePrep` bid was given to the Wellness Coach, which may only bid
  `hydration`, so it was dropped before reaching the board and the ledger had
  four rows where the test expects five.

## Not in CI

These need a booted simulator and they photograph things. The `apps` job builds
the app on every push, which catches the compile-level breakage; the doubles are
covered by the in-process tests above, which run in the `backend` job. Running
the tour itself is a local step before a demo or a screenshot refresh.
