#!/usr/bin/env bash
#
# Copyright (C) 2026 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

# Smoke test of the built image, run by the shared oci-image workflow once per platform.
# IMAGE and PLATFORM are provided by the workflow.
set -euo pipefail

expected=$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' Containerfile)
version=$(podman run --rm --platform "${PLATFORM}" "${IMAGE}" claude --version)
echo "claude --version: ${version}"
[[ "${version}" == "${expected} (Claude Code)" ]] || { echo "::error::expected ${expected}, got ${version}"; exit 1; }

# OpenShell network policies match the kernel-resolved /proc/<pid>/exe against
# `binaries`, usually /usr/local/bin/claude or a **/claude glob. So the launcher
# must shadow the native binary from an earlier PATH entry, and the binary that
# ends up connecting must still be /usr/local/bin/claude.
layout=$(podman run --rm --platform "${PLATFORM}" "${IMAGE}" /bin/sh -c '
  echo "cmd=$(command -v claude)"
  echo "native=$(readlink -f /usr/local/bin/claude)"
  if [ -e /usr/local/libexec/claude ] || [ -e /usr/local/bin/claude-real ]; then
    echo renamed=yes
  else
    echo renamed=no
  fi')
grep -qx 'cmd=/usr/local/sbin/claude' <<< "${layout}" \
  || { echo "::error::a bare claude does not reach the launcher: ${layout}"; exit 1; }
grep -qx 'native=/usr/local/bin/claude' <<< "${layout}" \
  || { echo "::error::the native CLI is not at /usr/local/bin/claude: ${layout}"; exit 1; }
grep -qx 'renamed=no' <<< "${layout}" \
  || { echo "::error::the image still carries a renamed claude binary: ${layout}"; exit 1; }

# Claude Code prompts for an ANTHROPIC_API_KEY it has not been told to trust.
# The launcher moves the key to CLAUDE_API_KEY and passes an apiKeyHelper to the
# CLI with --settings, so the helper is scoped to the session and nothing is
# written to a settings file.
key='openshell:resolve:env:ANTHROPIC_API_KEY'
# The literal is the helper command as JSON, not something to expand here.
# shellcheck disable=SC2016
settings='{"apiKeyHelper":"printf %s \"$CLAUDE_API_KEY\""}'

# Run the launcher with the wrapped binary replaced by a stub that prints the
# arguments it receives and the environment it inherits, so a test can see what
# the CLI would get. Arguments before "--" are podman -e assignments, after it
# are passed to claude.
launcher_dump() {
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=(-e "$1"); shift; done
  shift
  podman run --rm --platform "${PLATFORM}" "${envs[@]}" \
    -e CLAUDE_REAL_EXECUTABLE=/tmp/stub "${IMAGE}" /bin/sh -c '
      cat > /tmp/stub <<"STUB"
#!/bin/sh
echo "argv:$*"
env
STUB
      chmod +x /tmp/stub
      claude "$@"' sh "$@"
}

dump=$(launcher_dump ANTHROPIC_API_KEY="${key}" -- --dangerously-skip-permissions)
grep -Fqx "argv:--settings ${settings} --dangerously-skip-permissions" <<< "${dump}" \
  || { echo "::error::launcher did not pass the helper with --settings: $(grep '^argv:' <<< "${dump}")"; exit 1; }
grep -qx "CLAUDE_API_KEY=${key}" <<< "${dump}" \
  || { echo "::error::launcher did not move the key to CLAUDE_API_KEY"; exit 1; }
if grep -q '^ANTHROPIC_API_KEY=' <<< "${dump}"; then
  echo "::error::launcher left the key in ANTHROPIC_API_KEY"
  exit 1
fi

# Nothing is written to disk: a user-level entry would be shared state that a
# keyless launch has to undo, and Claude Code reloads settings while it runs.
written=$(podman run --rm --platform "${PLATFORM}" \
  -e ANTHROPIC_API_KEY="${key}" \
  -e CLAUDE_REAL_EXECUTABLE=/usr/bin/true \
  "${IMAGE}" /bin/sh -c 'claude; if [ -e "$HOME/.claude/settings.json" ]; then echo settings.json; fi')
[[ -z "${written}" ]] \
  || { echo "::error::launcher wrote ${written}"; exit 1; }

# The real CLI has to accept the inline settings the launcher passes it.
version=$(podman run --rm --platform "${PLATFORM}" \
  -e ANTHROPIC_API_KEY=sk-ant-launcher-test \
  "${IMAGE}" claude --version)
[[ "${version}" == "${expected} (Claude Code)" ]] \
  || { echo "::error::claude --version through the launcher: ${version}"; exit 1; }

# A launch without a key leaves the CLI exactly as it was called, so an OAuth,
# Vertex or Bedrock session never inherits a helper that returns nothing.
dump=$(launcher_dump -- hello)
[[ "$(grep '^argv:' <<< "${dump}")" == "argv:hello" ]] \
  || { echo "::error::launcher changed a keyless launch: $(grep '^argv:' <<< "${dump}")"; exit 1; }
if grep -q '^CLAUDE_API_KEY=' <<< "${dump}"; then
  echo "::error::launcher exported CLAUDE_API_KEY without a key"
  exit 1
fi

# A caller that brings its own --settings keeps it, and keeps the key too: the
# launcher does not add a second flag whose precedence would be ambiguous.
check_caller_settings() {
  local expected="$1"
  shift
  dump=$(launcher_dump ANTHROPIC_API_KEY="${key}" -- "$@" hi)
  [[ "$(grep '^argv:' <<< "${dump}")" == "argv:${expected} hi" ]] \
    || { echo "::error::launcher rewrote the caller settings ${expected}: $(grep '^argv:' <<< "${dump}")"; exit 1; }
  grep -qx "ANTHROPIC_API_KEY=${key}" <<< "${dump}" \
    || { echo "::error::launcher dropped the key next to a caller ${expected}"; exit 1; }
  if grep -q '^CLAUDE_API_KEY=' <<< "${dump}"; then
    echo "::error::launcher exported CLAUDE_API_KEY next to a caller ${expected}"
    exit 1
  fi
}

check_caller_settings \
  '--settings {"model":"claude-sonnet-4-5"}' \
  --settings '{"model":"claude-sonnet-4-5"}'
check_caller_settings \
  '--settings={"model":"claude-sonnet-4-5"}' \
  '--settings={"model":"claude-sonnet-4-5"}'

# The key leaves the environment but must not be replaced by anything else: an
# explicit ANTHROPIC_AUTH_TOKEN would make Claude Code send Authorization: Bearer,
# which a gateway fronting a custom base URL may not accept.
for base_url in default https://gateway.example.com; do
  envs=(ANTHROPIC_API_KEY=sk-ant-launcher-test)
  [[ "${base_url}" == default ]] || envs+=("ANTHROPIC_BASE_URL=${base_url}")
  dump=$(launcher_dump "${envs[@]}" -- )
  grep -qx 'CLAUDE_API_KEY=sk-ant-launcher-test' <<< "${dump}" \
    || { echo "::error::launcher did not hand ANTHROPIC_API_KEY to the helper for ${base_url}"; exit 1; }
  if grep -qE '^ANTHROPIC_(API_KEY|AUTH_TOKEN)=' <<< "${dump}"; then
    echo "::error::launcher left an ANTHROPIC credential next to the helper for ${base_url}"
    exit 1
  fi
done

# An explicit gateway token still wins over the API key, which the launcher drops
# so Claude Code does not report an auth conflict, and no helper is installed.
dump=$(launcher_dump \
  ANTHROPIC_API_KEY=sk-ant-launcher-test \
  ANTHROPIC_AUTH_TOKEN=sk-ant-caller-token \
  ANTHROPIC_BASE_URL=https://gateway.example.com -- hi)
[[ "$(grep '^argv:' <<< "${dump}")" == "argv:hi" ]] \
  || { echo "::error::launcher added a helper next to an explicit ANTHROPIC_AUTH_TOKEN"; exit 1; }
grep -qx 'ANTHROPIC_AUTH_TOKEN=sk-ant-caller-token' <<< "${dump}" \
  || { echo "::error::launcher did not keep the caller ANTHROPIC_AUTH_TOKEN"; exit 1; }
if grep -qE '^(ANTHROPIC_API_KEY|CLAUDE_API_KEY)=' <<< "${dump}"; then
  echo "::error::launcher kept an API key next to an explicit ANTHROPIC_AUTH_TOKEN"
  exit 1
fi

# The ACP adapter must spawn the launcher, not the native binary, or ACP
# sessions would hit the approval prompt again.
executable=$(podman run --rm --platform "${PLATFORM}" "${IMAGE}" printenv CLAUDE_CODE_EXECUTABLE)
[[ "${executable}" == "/usr/local/sbin/claude" ]] \
  || { echo "::error::CLAUDE_CODE_EXECUTABLE is ${executable}, expected /usr/local/sbin/claude"; exit 1; }

response=$(echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' \
  | timeout 120 podman run --rm -i --platform "${PLATFORM}" "${IMAGE}" claude-agent-acp)
echo "ACP response: ${response}"
jq -se 'any(.[]; .id == 1 and .result.protocolVersion == 1)' <<< "${response}" || { echo "::error::invalid ACP initialize response"; exit 1; }
