# shellcheck shell=bash
# Sourced by the provider scripts: the parts of running a headless agent that do not
# depend on which CLI it is.

# Neither Cursor nor Anthropic documents a version-pinned CLI installer for CI, so this
# runs whatever the endpoint serves. It is at least downloaded before it is run: piping
# into bash starts executing while the transfer is still going, so a connection dropped
# halfway leaves the first half already run, and nothing is recorded about what ran.
# Fetching first makes the download succeed or fail as a whole and lets the run log what
# it executed.
run_installer() {
  local name="$1" slug="$2" url="$3" installer installer_digest

  # Templated rather than bare: mktemp only honours TMPDIR when given one on BSD, and
  # the name says what the file is if a failed run ever leaves it behind.
  installer="$(mktemp "${TMPDIR:-/tmp}/${slug}-installer.XXXXXX")"
  # shellcheck disable=SC2064 # expanded now, while installer is still in scope
  trap "rm -f '${installer}'" EXIT

  curl -fsSL "${url}" -o "${installer}"

  if command -v sha256sum >/dev/null 2>&1; then
    installer_digest="$(sha256sum "${installer}" | cut -d" " -f1)"
  else
    installer_digest="$(shasum -a 256 "${installer}" | cut -d" " -f1)"
  fi
  echo "[agent] ${name} installer: $(wc -c <"${installer}") bytes, sha256 ${installer_digest}" >&2

  # A 200 with an empty body satisfies curl -f, and bash then runs an empty script and
  # exits 0. The install would look like it had happened, and the missing CLI would be
  # reported afterwards as though the installer had run and not worked.
  if [[ ! -s "${installer}" ]]; then
    echo "Downloaded an empty ${name} installer from ${url}" >&2
    exit 1
  fi

  bash "${installer}"
  rm -f "${installer}"
  trap - EXIT
}

# The output path is in the workspace, which is the pull request's head, so it may
# already hold a file -- or a symlink -- by that name. A shell redirect follows a
# symlink; rm -rf unlinks one.
clear_agent_output() {
  rm -rf -- "${AGENT_OUTPUT_PATH}"
}

# Agents write their own diagnostics to stdout, which the redirect captures into the
# output file rather than the log. Without echoing the file back, a refused workspace
# surfaces as a bare exit code here, or as a confusing parse error later.
check_agent_output() {
  local name="$1" status="$2"

  if [[ "${status}" -ne 0 ]]; then
    echo "The ${name} agent failed with exit ${status}." >&2
    preview_agent_output
    exit "${status}"
  fi

  if [[ ! -s "${AGENT_OUTPUT_PATH}" ]]; then
    echo "The ${name} agent exited 0 but produced no output." >&2
    exit 1
  fi

  # Both parsers recover JSON from fences and surrounding prose, so this only has to rule
  # out a response that contains no object at all.
  if ! grep -q "{" "${AGENT_OUTPUT_PATH}"; then
    echo "The ${name} agent returned no JSON object." >&2
    preview_agent_output
    exit 1
  fi
}

preview_agent_output() {
  echo "[agent] First 2 KiB of the agent's output:" >&2
  head -c 2048 "${AGENT_OUTPUT_PATH}" >&2 || true
  echo >&2
}
