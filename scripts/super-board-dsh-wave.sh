#!/usr/bin/env bash
# DeepSeek Harness wave: super-board-codex-wave.sh --backend dsh (same flags; --dsh[=<provider>/<model>]).
exec bash "$(dirname "${BASH_SOURCE[0]}")/super-board-codex-wave.sh" --backend dsh "$@"
