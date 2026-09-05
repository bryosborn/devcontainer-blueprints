#!/bin/sh
set -eu
cd "$(dirname "$0")"
# Only this disposable fixture output is cleared; never touch profile artifacts.
rm -rf results
node node_modules/@playwright/test/cli.js test "$@"
node check-results.cjs
