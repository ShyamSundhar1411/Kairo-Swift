# NFR10 - the 3% daily battery budget

> **NFR10** Battery cost - watchOS companion ≤ 3% of daily battery

**Status: unverified.** The figure in the report is a target nobody has
measured, and nothing in this repository can measure it. This file is the
procedure for doing so, plus the tripwire that runs in the meantime.

## Why the app cannot measure it

watchOS gives an app `WKInterfaceDevice.current().batteryLevel` - the *device's*
charge, not this app's share of the drain. A number computed from it would be
the whole watch's consumption wearing Kairo's name, which is worse than no
number: it would look like a measurement and would move with the user's workout
tracking, their screen-on time and the weather.

Attribution needs the energy instrument, which runs on a Mac against a paired
watch. That is the procedure below, and it needs hardware this repository does
not have.

## The tripwire that does run

`WatchEnergyBudget` (KairoKit) counts the three things the companion initiates
that cost energy - wakes, WatchConnectivity transmissions, haptics - against a
per-day budget drawn from what the design assumes:

| | Budget | Why that number |
|---|---|---|
| wakes | 40 | Six interruptions (AG-1), the user opening the app a handful of times, hourly-ish background refreshes while worn |
| transmissions | 60 | One per water tap, one per nudge response, plus outbox re-sends |
| haptics | 50 | One per tap, plus FR8.5's milestones - at most four more per day |

Every outbound message goes through one `send` on `WatchModel` and every haptic
through one `haptic`, so a new caller cannot miss the counter.

**Crossing a budget does not mean NFR10 was breached.** It means the companion
is doing more than the design assumed and the real measurement below is now
worth running. The value is catching the regression on the day it lands - "we
added milestone haptics" is exactly the kind of change that should have to show
its cost - rather than the day somebody finally opens Instruments.

## The real measurement

Needs: an Apple Watch, a paired iPhone, both off the charger, and Xcode.

1. **Charge both to 100%** and leave them off power for the run. A device
   charging during a battery measurement produces a number that means nothing.
2. **Install a Release build.** Debug builds carry instrumentation that is not
   in what users run, and measuring it would overstate the cost.
3. **Baseline day.** Wear the watch for a normal day with Kairo installed but
   *not* running and with notifications off. Record the charge at the start and
   at the same hour the next day. This is the control, and skipping it is how a
   watch that loses 40% a day anyway gets blamed on one app.
4. **Measured day.** Same watch, same wearer, same rough activity, with Kairo
   running normally - AG-1's six interruptions, water logged on the wrist a few
   times. Record the same two numbers.
5. **Attribute.** The difference between the two daily drops is Kairo's share.
   Repeat over at least three paired days: one day's difference is inside the
   noise of how much somebody raised their wrist.
6. **Then the instrument.** Xcode → Debug → *Attach to Process*, or Instruments'
   **Energy Log** template against the watch, for a breakdown by subsystem.
   Points of interest: WatchConnectivity activity while the link is flapping,
   and background refresh frequency.

Record the result here, with the dates and the watch model. An unverified target
and a verified one should not look the same in this repository.

## What would be done about a failure

In order of what costs the user least:

1. **Batch the outbox.** The re-send on reconnect is per sip. A flapping link
   turns four taps into many sends.
2. **Lower the background refresh rate.** The watch does not need the day's
   state until the wrist is raised.
3. **Drop the milestone haptics to the target only.** FR8.5's non-visual
   equivalent survives - the spoken form is the primary channel - and the
   quarter buzzes are the part with the weakest claim on the budget.

Interruptions are the last thing to cut, not the first: AG-1 already caps them
at six, and a wellness companion that saves battery by saying less has stopped
being the product.
