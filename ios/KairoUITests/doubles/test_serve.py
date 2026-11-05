"""The three backends `KairoUITests` drives the app against.

`ScreenTour` has named 127.0.0.1:8099, :8098 and :8097 since it was written and
this repository shipped nothing to answer them, so ten UI tests - including the
accessibility audit, which is the only automated check on NFR11 - have been
unrunnable. `mobile/ios/KairoUITests/doubles/serve.py` is what they talk to.

These tests exist because a screenshot harness fails *silently*. A double that
answers 200 with an empty round renders as a quiet day, not as a broken
fixture, and the person looking at the PNG has no way to tell. Both failures
below were real and were found this way: role keys spelled without spaces
matched no prompt, and a bid outside the role's granted classes was dropped
before it reached the board.

They run in-process rather than over a socket: the states are a property of how
the app is composed, and binding ports in CI buys nothing but flakiness.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[2]
SERVE = ROOT / "mobile" / "ios" / "KairoUITests" / "doubles" / "serve.py"

COVERAGE = {"meals": {"observed": 2, "expected": 3}, "sleep": {"observed": 1, "expected": 1},
            "movement": {"observed": 20, "expected": 24},
            "hydration": {"observed": 4, "expected": 5}}
OBSERVATIONS = {"sedentaryMinutes": 82, "hydrationML": 660, "hydrationTargetML": 2000}


@pytest.fixture(scope="module")
def doubles():
    spec = importlib.util.spec_from_file_location("ui_doubles", SERVE)
    module = importlib.util.module_from_spec(spec)
    sys.modules["ui_doubles"] = module
    spec.loader.exec_module(module)
    return module


def client_for(doubles, port: int, tmp_path) -> TestClient:
    return TestClient(doubles.app_for(port, tmp_path))


# -- the three states ---------------------------------------------------------

def test_8099_is_served_by_agents_and_metered(doubles, tmp_path):
    body = client_for(doubles, 8099, tmp_path).get("/health").json()
    assert body["provider"]["costing"] == "metered"


def test_8098_is_the_same_round_on_shadow_rates(doubles, tmp_path):
    """8099 and 8098 differ only in whether the money on screen is money, and
    the costing comes from the provider because that is where the real one comes
    from. A flag read straight into the response would photograph a banner the
    production code could never produce."""
    body = client_for(doubles, 8098, tmp_path).get("/health").json()
    assert body["provider"]["costing"] == "shadow"


def test_8097_refuses_and_says_why(doubles, tmp_path):
    """The app's job on this screen is to name the provider and the tier, not to
    show an empty Today."""
    response = client_for(doubles, 8097, tmp_path).get("/health")
    assert response.status_code == 503
    body = response.json()
    assert "no model provider could be bound" in body["mode"]
    assert body["diagnosis"]


def test_the_refusing_double_does_not_bind_a_local_model(doubles, tmp_path):
    """Without pinning `OLLAMA_HOST` at a dead port this app binds whatever the
    developer happens to be running, so the "no backend" screenshot would be
    reproducible on CI and not on the machine of the person who wrote it."""
    body = client_for(doubles, 8097, tmp_path).get("/health").json()
    assert "ollama" not in body["mode"].lower()


# -- the ledger the screenshots and the audit need -------------------------------

@pytest.fixture
def served(doubles, tmp_path):
    c = client_for(doubles, 8099, tmp_path)
    return c.post("/v1/arbitrate",
                  json={"userID": "u1", "dailyBudget": 6, "spent": 0,
                        "coverage": COVERAGE, "observations": OBSERVATIONS}).json()


def test_the_round_produces_exactly_five_rows(served):
    """`testLedgerAnnouncesEachBidOnce` asserts five. Four is the failure this
    caught: a `bedtimePrep` bid was given to the Coach, which may only bid
    hydration, so it was dropped before it reached the board."""
    assert len(served["delivered"]) + len(served["suppressed"]) == 5


def test_one_bid_wins_and_it_is_the_one_the_ui_test_names(served):
    assert [n["text"] for n in served["delivered"]] == ["82 minutes sitting unbroken"]


def test_every_loser_carries_a_reason(served):
    """The ledger's whole job is explaining what was held back. A suppressed bid
    with no reason photographs as an unexplained absence."""
    assert served["suppressed"]
    assert all(n["suppressionReason"] for n in served["suppressed"])


def test_the_round_is_screened_rather_than_failing_closed(served):
    """Unscripted, the Steward is unparseable and the service fails closed -
    correct behaviour, and it would photograph an empty ledger."""
    assert served["record"]["safetyVerdict"] in ("pass", "rewritten")


def test_the_roles_are_named_as_the_prompt_spells_them(doubles):
    """The first draft keyed the fixture by the enum spelling
    (`LifestyleSignalAnalyst`) and matched nothing, so every round came back
    empty - which the app renders as a quiet day, not as a broken harness."""
    assert "Lifestyle Signal Analyst" in doubles.BIDS
    assert all(" " in role for role in doubles.BIDS)


def test_the_harness_never_reaches_the_repository_env(doubles, tmp_path):
    """`Settings.load(ROOT)` walks up and finds the repository `.env`, which
    carries a real provider key. A screenshot harness must not be one
    misconfiguration away from sending a test fixture to a vendor."""
    settings = doubles._settings(tmp_path / "x")
    assert settings.dotenv_path is None or "Kairo/.env" not in settings.dotenv_path
