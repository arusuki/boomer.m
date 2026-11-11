#!/bin/sh
set -eu
bin="$1"
tmp=$(mktemp -d /tmp/boomer-cli-test.XXXXXX)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
"$bin" --help > "$tmp/help"
"$bin" --version > "$tmp/version"
expect_fail() {
    if "$bin" "$@" > "$tmp/out" 2>&1; then
        echo "Expected failure: $*" >&2
        exit 1
    fi
}
expect_fail --invalid
expect_fail --delay
expect_fail --delay nan
expect_fail --delay -1
expect_fail --display 1.5
expect_fail --image
expect_fail --live --demo
expect_fail --demo --image x.png
"$bin" --new-config "$tmp/config"
cp "$tmp/config" "$tmp/original"
expect_fail --new-config "$tmp/config"
cmp "$tmp/config" "$tmp/original"
echo 'CLI tests passed.'
