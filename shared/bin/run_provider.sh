#!/usr/bin/env bash
# Runs the provider script PROVIDER names. Kept beside the providers rather than inline in
# each action, so the name check below cannot drift apart between them.
set -euo pipefail

provider="${PROVIDER:-cursor}"

# Interpolated into a path, so it has to be a bare name: ../ would otherwise escape
# providers/ and run some other reachable script with the provider credential in the
# environment.
if [[ ! "${provider}" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "Invalid provider name: ${provider}" >&2
  exit 1
fi

SHARED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
provider_script="${SHARED_ROOT}/providers/${provider}.sh"

if [[ ! -f "${provider_script}" ]]; then
  echo "Unknown provider: ${provider} (expected script at ${provider_script})" >&2
  exit 1
fi

exec bash "${provider_script}"
