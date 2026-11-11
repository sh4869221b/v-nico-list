#!/usr/bin/env bash
set -euo pipefail
cd /workspace/scratch/b81277eea609
export VMODULES=$PWD/v-nico-vmodules
V=$PWD/v-nico-toolchain/v
R=$PWD/v-nico-parser-combined
E=$R/docs/provenance/parser-combined-20261111
B=$PWD/v-nico-final-cli-binaries
python3 "$R/scripts/benchmark_parse.py" --binary main=$PWD/v-nico-parser-main-binaries/main --binary combined=$PWD/v-nico-parser-final-binaries/combined --size 100 --iterations 25 --warmups 10 --repetitions 9 --output "$E/main-vs-combined.json" > "$E/main-vs-combined.log" 2>&1
git -C "$R" worktree add --detach ../v-nico-parser-exact-main 1f518b8385cbba51f1b57d6048de17b77d57fdbe
mkdir -p "$B"
"$V" -cc gcc -d use_openssl -prod -o "$B/main" "$PWD/v-nico-parser-exact-main/src" > "$E/build-main.txt" 2>&1
"$V" -cc gcc -d use_openssl -prod -o "$B/combined-openssl" "$R/src" > "$E/build-openssl.txt" 2>&1
"$V" -cc gcc -prod -o "$B/combined-mbedtls" "$R/src" > "$E/build-mbedtls.txt" 2>&1
sha256sum "$B/"* > "$E/cli-binary-sha256.txt"
for payload in minimal extended; do
 for format in json lines; do
  for latency in 0 10; do
   python3 "$R/scripts/benchmark.py" --binary main="$B/main" --binary combined="$B/combined-openssl" --targets 4 --pages 3 --repetitions 7 --payload "$payload" --format "$format" --latency-ms "$latency" --output "$E/cli-$payload-$format-${latency}ms.json" > "$E/cli-$payload-$format-${latency}ms.log" 2>&1
  done
 done
done
cd "$R"
"$V" fmt -verify src scripts/parse_benchmark > "$E/format.txt" 2>&1
python3 tests/benchmark_parse_test.py > "$E/fixture-tests.txt" 2>&1
python3 -m py_compile scripts/benchmark.py scripts/benchmark_parse.py tests/benchmark_parse_test.py
"$V" -cc gcc -d use_openssl test src > "$E/unit-openssl.txt" 2>&1
"$V" -cc gcc test src > "$E/unit-mbedtls.txt" 2>&1
python3 tests/integration.py --binary "$B/combined-openssl" > "$E/integration-openssl.txt" 2>&1
python3 tests/integration.py --binary "$B/combined-mbedtls" > "$E/integration-mbedtls.txt" 2>&1
python3 scripts/benchmark_parse.py --binary combined=$PWD/../v-nico-parser-final-binaries/combined --size 4 --iterations 2 --warmups 1 --repetitions 1 --output "$E/parser-smoke.json" > "$E/parser-smoke.log" 2>&1
python3 scripts/benchmark.py --binary combined="$B/combined-mbedtls" --targets 3 --pages 3 --repetitions 1 --output "$E/cli-mbedtls-smoke.json" > "$E/cli-mbedtls-smoke.log" 2>&1
git diff --check
