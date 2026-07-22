#!/bin/sh
# Repo-root installer: delegates to osx-app/install.sh
set -e
exec "$(dirname "$0")/osx-app/install.sh" "$@"
