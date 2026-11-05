#!/usr/bin/env bash
# Regenerates every state machine diagram in the original design document from the code
# that enforces it. Run this before submitting; the diagrams cannot drift.
set -euo pipefail
cd "$(dirname "$0")/../.."
swift run -q kairo-uml plantuml > ../../docs/diagrams/state-machines.puml
swift run -q kairo-uml mermaid  > ../../docs/diagrams/state-machines.mmd
swift run -q kairo-uml audit    > ../../docs/diagrams/audit.txt
echo "regenerated -> docs/diagrams/"
cat ../../docs/diagrams/audit.txt
