#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
V=${V:-v}
mkdir -p bin
exec "$V" -cc gcc -d use_openssl -prod -o bin/v-nico-list src
