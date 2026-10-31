#!/usr/bin/env bash
set -euo pipefail

if [[ "${PHASE:-}" != "bootstrap" || "${DATABASE_PARTIAL_ROLLBACK_SAFE:-false}" != "true" ]]; then
  echo "Partial cleanup was not authorized; the shared database state and resources were retained." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

# The only rollback target in this workflow is envs/staging/database, which owns
# the RDS instance shared by HML and PRD. An empty pre-apply state does not make
# deleting that shared instance safe for a single environment's failed session.
echo "::error::Automatic partial rollback of the shared HML/PRD RDS root is disabled; resources were retained for operator review." >&2
echo "The shared RDS was retained because an HML or PRD session cannot authorize its deletion." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit 1
