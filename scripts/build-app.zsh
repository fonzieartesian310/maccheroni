#!/bin/zsh

set -euo pipefail

repo_root=${0:A:h:h}
build_configuration=${1:-debug}

case "$build_configuration" in
    debug|release) ;;
    *)
        print -u2 -- "usage: scripts/build-app.zsh [debug|release]"
        exit 64
        ;;
esac

cd "$repo_root"

zsh "$repo_root/scripts/build-moss-harness.zsh"
swift build --configuration "$build_configuration" --product MaccheroniApp
swift build --configuration "$build_configuration" --product maccheroni

bin_directory=$(swift build --configuration "$build_configuration" --show-bin-path)
resource_bundles=(
    Maccheroni_MaccheroniApp.bundle
    Maccheroni_MaccheroniCLI.bundle
    Maccheroni_MaccheroniASR.bundle
    Maccheroni_MaccheroniPostprocess.bundle
)
app_artifact_root=$(mktemp -d "$repo_root/.build/MaccheroniApp-${build_configuration}.XXXXXX")
app_bundle="$app_artifact_root/Maccheroni.app"

test -x "$bin_directory/MaccheroniApp"
test -x "$bin_directory/maccheroni"
for resource_bundle in "${resource_bundles[@]}"; do
    test -d "$bin_directory/$resource_bundle"
done

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
/usr/bin/install -m 755 "$bin_directory/MaccheroniApp" "$app_bundle/Contents/MacOS/MaccheroniApp"
/usr/bin/install -m 755 "$bin_directory/maccheroni" "$app_bundle/Contents/MacOS/maccheroni"
/usr/bin/install -m 644 "$repo_root/Support/MaccheroniApp/Info.plist" "$app_bundle/Contents/Info.plist"

copy_python_resource_bundle() {
    local resource_bundle=$1
    shift
    local source_bundle="$bin_directory/$resource_bundle"
    local destination_bundle="$app_bundle/Contents/Resources/$resource_bundle"

    mkdir -p "$destination_bundle"
    /usr/bin/install -m 644 "$source_bundle/Info.plist" "$destination_bundle/Info.plist"
    local file_name
    for file_name in "$@"; do
        /usr/bin/install -m 644 "$source_bundle/$file_name" "$destination_bundle/$file_name"
    done
}

for resource_bundle in "${resource_bundles[@]}"; do
    case "$resource_bundle" in
        Maccheroni_MaccheroniASR.bundle)
            copy_python_resource_bundle "$resource_bundle" \
                maccheroni_asr_runner.py pyproject.toml uv.lock
            ;;
        Maccheroni_MaccheroniPostprocess.bundle)
            copy_python_resource_bundle "$resource_bundle" \
                maccheroni_postprocess_runner.py pyproject.toml uv.lock postprocess-output.schema.json
            ;;
        *)
            /usr/bin/ditto \
                "$bin_directory/$resource_bundle" \
                "$app_bundle/Contents/Resources/$resource_bundle"
            ;;
    esac
done

verify_python_resource_inventory() {
    local resource_bundle=$1
    shift
    local bundle="$app_bundle/Contents/Resources/$resource_bundle"
    local expected
    expected=$(print -rl -- Info.plist "$@" | sort)
    local actual
    actual=$(cd "$bundle" && find . -type f -print | sed 's#^./##' | sort)
    if [[ "$actual" != "$expected" ]]; then
        print -u2 -- "unexpected Python resource inventory in $resource_bundle"
        print -u2 -- "$actual"
        return 1
    fi
    print -r -- "$resource_bundle: $actual"
}

verify_python_resource_inventory Maccheroni_MaccheroniASR.bundle \
    maccheroni_asr_runner.py pyproject.toml uv.lock
verify_python_resource_inventory Maccheroni_MaccheroniPostprocess.bundle \
    maccheroni_postprocess_runner.py pyproject.toml uv.lock postprocess-output.schema.json

if [[ -n $(find "$app_bundle" -type l -print -quit) ]]; then
    print -u2 -- "app bundle must not contain symbolic links"
    exit 1
fi

/usr/bin/plutil -lint "$app_bundle/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --deep --sign - \
    --entitlements "$repo_root/Support/MaccheroniApp/Maccheroni.entitlements" \
    "$app_bundle"
/usr/bin/codesign --verify --deep --strict "$app_bundle"

print -r -- "$app_bundle"
