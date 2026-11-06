#!/usr/bin/env sh
# Fetch official sources through the caller's existing network/proxy policy.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dest=${1:-"$repo_dir/.toolchains/v"}
if [ -e "$dest" ]; then
  echo "Refusing to replace existing toolchain: $dest" >&2
  exit 1
fi
git clone --filter=blob:none --no-checkout https://github.com/vlang/v.git "$dest"
git -C "$dest" checkout --detach "$(cat "$repo_dir/scripts/v-revision")"
git clone --filter=blob:none --no-checkout https://github.com/vlang/vc.git "$dest/vc"
git -C "$dest/vc" checkout --detach "$(cat "$repo_dir/scripts/vc-revision")"
git clone --filter=blob:none --no-checkout https://github.com/vlang/tccbin.git "$dest/thirdparty/tcc"
git -C "$dest/thirdparty/tcc" checkout --detach "$(cat "$repo_dir/scripts/tcc-revision")"
make -C "$dest" local=1
"$dest/v" version
