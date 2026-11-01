#!/usr/bin/env python3
"""The backends `KairoUITests` expects on 8099, 8098 and 8097.

`ScreenTour` has driven the app against these three addresses since it was
written and the repository never shipped anything to answer them, so ten tests -
including the accessibility audit, which is the only automated check on NFR11 -
have been unrunnable. This is what they talk to.

**These are not hand-written fakes.** Each one is the real `create_app` with a
scripted provider, so the UI is exercised against the backend's actual contract
rather than against a JSON file somebody kept in step by hand. A double that can
drift from the thing it doubles is a test that passes after the contract breaks.

Three ports because the app renders three different provenance states and each
has to be photographed rather than described:

* **8099 - served by agents.** A full round: five bids, one delivered, four
  suppressed with their reasons. This is the one the ledger, the decision record
  and the accessibility audit all run against.
* **8098 - shadow costing.** The same round from a backend whose provider costs
  nothing, so §7.1's ladder moves on shadow rates and every figure derived from
  them says so. The app has to show that it is notional.
* **8097 - refusing.** No provider could be bound. `/health` answers 503 with a
  diagnosis and every `/v1` route refuses. The app's job is to say which backend
  and which tier, not to show an empty Today.

8088 is deliberately not served. `testAgentsUnreachable` wants a fine address
with nothing behind it - the state where the server is simply not there.

    python mobile/ios/KairoUITests/doubles/serve.py          # all three
    python mobile/ios/KairoUITests/doubles/serve.py 8099     # just one
"""
from __future__ import annotations

import signal
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "backend"))

import uvicorn

from kairo.api.app import create_app
from kairo.config import Settings
from kairo.providers.base import Costing
from kairo.providers.scripted import Rule, ScriptedProvider

#: The bids the ledger screenshots and `testLedgerAnnouncesEachBidOnce` expect.
#: Five, so the ledger has losers to explain - a round where everything was
#: delivered would photograph the one case the attention budget is not for.
#: Keyed by the role name **as the prompt spells it**, with spaces. The first
#: draft keyed them by the enum spelling (`LifestyleSignalAnalyst`) and matched
#: nothing, so every round came back empty - a double that answers 200 with no
#: bids is the most confusing possible failure, because the app renders it as a
#: quiet day rather than a broken harness.
BIDS = {
    # Each role may only bid in the classes `Roster.build` grants it, and a bid
    # outside them is dropped before it reaches the board. The first draft gave
    # the Coach a `bedtimePrep` bid and quietly got four rows instead of five.
    "Lifestyle Signal Analyst": [
        ("sedentary", "82 minutes sitting unbroken", 0.82, 0.70),
        ("movement", "a short walk would close today's ring", 0.44, 0.30),
        ("bedtimePrep", "a wind-down now protects tomorrow morning", 0.52, 0.25),
    ],
    "Wellness Coach": [
        ("hydration", "340 ml behind today's target", 0.60, 0.30),
    ],
    "Nutrition Analyst": [
        ("mealLog", "lunch is not logged yet", 0.38, 0.20),
    ],
}


def _bid_json(entries) -> str:
    items = ",".join(
        '{"nudgeClass":"%s","text":"%s","expectedBenefit":%s,"urgency":%s,'
        '"rationale":"from the readings"}' % (cls, text, benefit, urgency)
        for cls, text, benefit, urgency in entries)
    return '{"bids":[%s]}' % items


def rules() -> list[Rule]:
    out = [Rule((f"YOUR ROLE: {role}", "Propose at most two interventions"),
                _bid_json(entries))
           for role, entries in BIDS.items()]
    # The Steward screens whatever the arbiter allocates (CF11). Unscripted, the
    # judge is unparseable and the service fails closed - which is the correct
    # behaviour and would photograph an empty ledger.
    out.append(Rule(("YOUR ROLE: Wellbeing Steward", "MESSAGE ABOUT TO BE SENT"),
                    '{"verdict":"pass","reason":"safe as written"}'))
    return out


class MeteredScripted(ScriptedProvider):
    """A scripted provider that reports metered costing.

    8099 and 8098 differ only in whether the money on screen is money. Both run
    the same scripted round, so the costing has to be the thing that varies -
    and it has to come from the provider, because that is where the real one
    comes from. A flag read straight into the response would photograph a
    banner the production code could never produce.
    """
    costing = Costing.METERED
    name = "scripted-metered"


def _settings(data_dir: Path, **overrides):
    """Settings rooted at the data directory, **not** at the repository.

    Deliberate: `Settings.load(ROOT)` walks up and finds the repository `.env`,
    which carries a real provider key. A screenshot harness must never be one
    misconfiguration away from spending someone's credit or sending a test
    fixture to a vendor.
    """
    data_dir.mkdir(parents=True, exist_ok=True)
    return Settings.load(data_dir, overrides={"KAIRO_DATA_DIR": str(data_dir),
                                              **overrides})


def app_for(port: int, data_dir: Path):
    """One app per port, each with its own data directory.

    Separate directories because a shared one would let one port's round leave
    memories and outcomes behind for the next, and two tests that interfere are
    worse than one test.
    """
    here = data_dir / str(port)
    if port == 8097:
        # Nothing resolves. `_settings` roots at a temp directory and replaces
        # the process environment, so there is no `.env` above it and no key in
        # scope - which is exactly the production condition for "no backend
        # could be bound", reached the way production reaches it rather than
        # through a flag that exists only for tests.
        #
        # Naming a provider instead would *raise* `ProviderUnusable` at startup,
        # which is a different and correct behaviour for a misconfiguration and
        # not the state this screen is for.
        # `OLLAMA_HOST` is pointed at a dead port on purpose. Without it this
        # app binds whatever local model the developer happens to be running,
        # so the "no backend" screenshot would be reproducible on CI and not on
        # the machine of the person who wrote it - which is the worst of both.
        return create_app(_settings(here, OLLAMA_HOST="http://127.0.0.1:1"))

    sys.path.insert(0, str(ROOT / "backend"))
    from tests.conftest import make_service   # type: ignore

    provider = (ScriptedProvider if port == 8098 else MeteredScripted)(
        rules=rules(), fallback='{"bids":[]}')
    service = make_service(rules=rules(), tmp_path=here)
    service.provider = provider
    service.roster = type(service.roster).build(provider)
    return create_app(_settings(here), service=service)


def serve(port: int, data_dir: Path) -> threading.Thread:
    config = uvicorn.Config(app_for(port, data_dir), host="127.0.0.1", port=port,
                            log_level="warning")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True, name=f"kairo-{port}")
    thread.start()
    return thread


def main() -> None:
    import tempfile

    ports = [int(a) for a in sys.argv[1:]] or [8099, 8098, 8097]
    data_dir = Path(tempfile.mkdtemp(prefix="kairo-uitest-"))
    for port in ports:
        serve(port, data_dir)
        print(f"  127.0.0.1:{port}")
    print(f"data in {data_dir}")
    print("ready - ctrl-c to stop")
    signal.pause()


if __name__ == "__main__":
    main()
