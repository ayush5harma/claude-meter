#!/usr/bin/env bash
# Remove Claude Meter: unload the agent, delete the app, the collector and the
# rendered plist. Pass --purge to delete the cache and usage history as well.
# One implementation, in install.sh, so install and uninstall can never disagree
# about which paths are involved.

set -uo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SRC_DIR/install.sh" --uninstall "$@"
