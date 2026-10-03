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

response=$(echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' \
  | timeout 120 podman run --rm -i --platform "${PLATFORM}" "${IMAGE}" claude-agent-acp)
echo "ACP response: ${response}"
jq -se 'any(.[]; .id == 1 and .result.protocolVersion == 1)' <<< "${response}" || { echo "::error::invalid ACP initialize response"; exit 1; }
