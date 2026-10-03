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

# ghcr.io/openkaiden/openshell-image-base-builder:next
FROM ghcr.io/openkaiden/openshell-image-base-builder@sha256:9ed6a310ace8f3f5cb6e7ccfb06329a3f25f4c9e6f7385eb3528eb17b9fdba75 AS builder
ARG CLAUDE_CODE_VERSION=2.1.286
ARG BUN_VERSION="bun-v1.4.2"
ARG CLAUDE_AGENT_ACP_VERSION=v0.85.0
ARG CLAUDE_AGENT_ACP_SHA=c84845272fe3c55c1f97759f00ee48a1356fccae

# Install Claude and then copy it inside the root filesystem
RUN set -eux; \
    curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"; \
    install -D -m 0755 "$(readlink -f /root/.local/bin/claude)" /mnt/rootfs/usr/local/bin/claude

# Build the ACP wrapper with bun and copy it inside the root filesystem
RUN set -eux; \
    dnf install -y git unzip; \
    curl -fsSL https://bun.com/install | bash -s -- "${BUN_VERSION}"; \
    install -D -m 0755 "$(readlink -f /root/.bun/bin/bun)" /usr/local/bin/bun; \
    # clone the ACP tag and check it still points to the expected commit
    git clone --depth 1 --branch "${CLAUDE_AGENT_ACP_VERSION}" https://github.com/agentclientprotocol/claude-agent-acp /tmp/claude-agent-acp; \
    test "$(git -C /tmp/claude-agent-acp rev-parse HEAD)" = "${CLAUDE_AGENT_ACP_SHA}"; \
    cd /tmp/claude-agent-acp; \
    bun install; \
    bun build --compile src/index.ts --outfile /mnt/rootfs/usr/local/bin/claude-agent-acp

# Now create our final image with reduced layers
FROM scratch
COPY --from=builder /mnt/rootfs/ /
# Notify the SDK/ACP client where claude binary is located
ENV CLAUDE_CODE_EXECUTABLE=/usr/local/bin/claude
CMD ["claude", "--dangerously-skip-permissions"]
