#!/usr/bin/env bash
# DeepSeek Harness lane: super-board-lane.sh --backend dsh (same flags; --dsh[=<provider>/<model>]).
exec bash "$(dirname "${BASH_SOURCE[0]}")/super-board-lane.sh" --backend dsh "$@"
