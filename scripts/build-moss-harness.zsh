#!/bin/zsh

set -euo pipefail

repo_root=${0:A:h:h}
harness_root="$repo_root/benchmarks/scripts/runners/moss-harness"
cache_root="${MACCHERONI_BENCHMARK_CACHE:-$HOME/Library/Caches/Maccheroni/benchmarks}"
scratch="$cache_root/swift-scratch/moss-harness"
configuration=release
target_architecture=arm64
target_triple=arm64-apple-macosx
binary="$scratch/$target_triple/$configuration/MaccheroniMossHarness"
metallib="$scratch/$target_triple/$configuration/mlx.metallib"
fingerprint="$binary.fingerprint.json"
contract_version=moss-harness-v2
build_flags='--configuration release --arch arm64 --product MaccheroniMossHarness'

usage() {
    print -u2 -- "usage: scripts/build-moss-harness.zsh [--verify]"
    exit 64
}

[[ $# -le 1 ]] || usage
verify_only=false
if [[ $# -eq 1 ]]; then
    [[ $1 == --verify ]] || usage
    verify_only=true
fi

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

source_tree_digest() {
    (
        cd "$harness_root"
        find Sources -type f -print | LC_ALL=C sort | while IFS= read -r source; do
            print -r -- "$source"
            /usr/bin/shasum -a 256 "$source"
        done
    ) | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

[[ -d "$harness_root" ]] || { print -u2 -- "MOSS harness source missing: $harness_root"; exit 66; }
[[ -f "$harness_root/Package.swift" ]] || { print -u2 -- "MOSS harness Package.swift missing"; exit 66; }
[[ -f "$harness_root/Package.resolved" ]] || { print -u2 -- "MOSS harness Package.resolved missing"; exit 66; }

source_digest=$(source_tree_digest)
package_digest=$(sha256_file "$harness_root/Package.swift")
resolved_digest=$(sha256_file "$harness_root/Package.resolved")
swift_version=$(/usr/bin/xcrun swift --version)
swift_version_digest=$(print -rn -- "$swift_version" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')

verify_fingerprint() {
    [[ -x "$binary" ]] || { print -u2 -- "MOSS harness executable missing: $binary"; exit 69; }
    [[ -f "$metallib" ]] || { print -u2 -- "MOSS harness metallib missing: $metallib"; exit 69; }
    [[ -f "$fingerprint" ]] || { print -u2 -- "MOSS harness fingerprint missing: $fingerprint"; exit 69; }
    local binary_digest metallib_digest
    binary_digest=$(sha256_file "$binary")
    metallib_digest=$(sha256_file "$metallib")
    /usr/bin/python3 - "$fingerprint" "$contract_version" "$source_digest" "$package_digest" "$resolved_digest" "$swift_version" "$swift_version_digest" "$target_architecture" "$configuration" "$build_flags" "$binary_digest" "$metallib_digest" <<'PY'
import json
import sys

(
    path,
    contract_version,
    source_digest,
    package_digest,
    resolved_digest,
    swift_version,
    swift_version_digest,
    target_architecture,
    configuration,
    build_flags,
    binary_digest,
    metallib_digest,
) = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    found = json.load(source)
expected = {
    "contract_version": contract_version,
    "source_tree_sha256": source_digest,
    "package_swift_sha256": package_digest,
    "package_resolved_sha256": resolved_digest,
    "swift_version": swift_version,
    "swift_version_sha256": swift_version_digest,
    "target_architecture": target_architecture,
    "configuration": configuration,
    "build_flags": build_flags.split(),
    "executable_sha256": binary_digest,
    "metallib_sha256": metallib_digest,
}
if found != expected:
    print("MOSS harness fingerprint mismatch", file=sys.stderr)
    for key in sorted(set(found) | set(expected)):
        if found.get(key) != expected.get(key):
            print(f"  {key}: expected {expected.get(key)!r}, found {found.get(key)!r}", file=sys.stderr)
    raise SystemExit(65)
PY
}

if [[ "$verify_only" == true ]]; then
    verify_fingerprint
    print -r -- "verified $fingerprint"
    exit 0
fi

mkdir -p "$scratch"
swift build \
    --package-path "$harness_root" \
    --scratch-path "$scratch" \
    --configuration "$configuration" \
    --arch "$target_architecture" \
    --product MaccheroniMossHarness

[[ -x "$binary" ]] || { print -u2 -- "MOSS harness build did not produce: $binary"; exit 70; }
metallib_source="$(brew --prefix speech)/libexec/mlx.metallib"
[[ -f "$metallib_source" ]] || { print -u2 -- "MLX metallib missing: $metallib_source"; exit 69; }
if [[ ! -f "$metallib" ]] || [[ "$(sha256_file "$metallib")" != "$(sha256_file "$metallib_source")" ]]; then
    install -m 0644 "$metallib_source" "$metallib"
fi

binary_digest=$(sha256_file "$binary")
metallib_digest=$(sha256_file "$metallib")
fingerprint_directory=${fingerprint:h}
mkdir -p "$fingerprint_directory"
fingerprint_tmp=$(mktemp "$fingerprint_directory/.MaccheroniMossHarness.fingerprint.XXXXXX")
/usr/bin/python3 - "$fingerprint_tmp" "$contract_version" "$source_digest" "$package_digest" "$resolved_digest" "$swift_version" "$swift_version_digest" "$target_architecture" "$configuration" "$build_flags" "$binary_digest" "$metallib_digest" <<'PY'
import json
import sys

(
    path,
    contract_version,
    source_digest,
    package_digest,
    resolved_digest,
    swift_version,
    swift_version_digest,
    target_architecture,
    configuration,
    build_flags,
    binary_digest,
    metallib_digest,
) = sys.argv[1:]
payload = {
    "contract_version": contract_version,
    "source_tree_sha256": source_digest,
    "package_swift_sha256": package_digest,
    "package_resolved_sha256": resolved_digest,
    "swift_version": swift_version,
    "swift_version_sha256": swift_version_digest,
    "target_architecture": target_architecture,
    "configuration": configuration,
    "build_flags": build_flags.split(),
    "executable_sha256": binary_digest,
    "metallib_sha256": metallib_digest,
}
with open(path, "w", encoding="utf-8", newline="\n") as destination:
    json.dump(payload, destination, sort_keys=True, indent=2)
    destination.write("\n")
PY
mv -f "$fingerprint_tmp" "$fingerprint"
verify_fingerprint
print -r -- "$binary"
