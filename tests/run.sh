#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

sh "$repo_root/tests/entrypoint-killswitch.test.sh"
