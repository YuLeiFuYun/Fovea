#!/bin/sh
set -eu
python3 scripts/check-mathematical-research.py
python3 scripts/check-mathematical-proof-obligations.py
python3 scripts/check-optimization-parameters.py --strict
python3 scripts/check-resource-envelope.py
python3 scripts/prove-namespace-generation-manifest-bound.py
python3 scripts/audit-numeric-constants.py --strict
python3 scripts/model-check-cache-transactions.py
python3 scripts/model-check-shared-task-registry.py
python3 scripts/model-check-permit-scheduler.py
python3 scripts/model-check-validated-encoded-handoff.py
python3 scripts/model-check-adaptive-image-admission.py
python3 scripts/model-check-http-metadata-limits.py
python3 scripts/model-check-transport-retry.py
