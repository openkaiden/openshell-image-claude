#!/bin/sh
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
#
# Claude Code launcher.
#
# Claude Code refuses to use an ANTHROPIC_API_KEY that it has not been told to
# trust, so every fresh sandbox stops at a "Detected a custom API key in your
# environment / Do you want to use this API key?" prompt and never reaches the
# model. Approvals live in $HOME/.claude.json and can only be written from the
# sandbox.
#
# Instead of answering that prompt, this launcher takes the credential out of
# ANTHROPIC_API_KEY and hands it back through apiKeyHelper, which it passes to
# Claude Code with --settings for this session. The CLI then reads the key from
# the helper rather than spotting a stray environment variable, so there is
# nothing to approve and nothing is written to a settings file.
#
# The helper is session-scoped on purpose. A helper written into
# ~/.claude/settings.json is shared state: a keyless launch would have to remove
# it, and Claude Code reloads settings while it runs, so that removal can strip
# the credential from a session that is already using it. --settings belongs to
# one process, disappears with it, and outranks user, project and project-local
# settings - only managed settings take precedence - so a repository's own
# apiKeyHelper cannot shadow it either.
#
# The launcher is installed in /usr/local/sbin, which precedes /usr/local/bin in
# PATH, and execs the native binary at /usr/local/bin/claude. That path is what
# OpenShell network policies match (the kernel-resolved /proc/<pid>/exe), so the
# real CLI has to stay there under its own name.
#
# CLAUDE_REAL_EXECUTABLE overrides the wrapped binary. The image tests use it to
# point the launcher at a stub and observe what it forwards.
set -eu

# The helper command, as JSON for --settings. Claude Code runs it in a shell, so
# the key is expanded there; only the command, never the key, goes on the command
# line. The literal is not expanded here: the single quotes keep the \" the JSON
# needs and the $ the helper needs.
# shellcheck disable=SC2016
SESSION_SETTINGS='{"apiKeyHelper":"printf %s \"$CLAUDE_API_KEY\""}'

# Whether the caller brought its own settings. Adding a second --settings would
# either be ignored or drop the caller's, and the caller's file may hold the
# helper it wants to authenticate with.
has_settings_flag() {
    for arg in "$@"; do
        case "${arg}" in
            --settings|--settings=*) return 0 ;;
        esac
    done
    return 1
}

# An explicit gateway token wins over the API key inside Claude Code; drop the
# key so the CLI does not report an auth conflict.
if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    unset ANTHROPIC_API_KEY
fi

if [ -n "${ANTHROPIC_API_KEY:-}" ] && ! has_settings_flag "$@"; then
    # Move the key behind the helper: the CLI must never see it in the
    # environment, or it asks whether the key may be used.
    CLAUDE_API_KEY=${ANTHROPIC_API_KEY}
    export CLAUDE_API_KEY
    unset ANTHROPIC_API_KEY
    set -- --settings "${SESSION_SETTINGS}" "$@"
fi

exec "${CLAUDE_REAL_EXECUTABLE:-/usr/local/bin/claude}" "$@"
