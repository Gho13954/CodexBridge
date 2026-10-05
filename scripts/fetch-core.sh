#!/bin/bash
set -euo pipefail
task_repo="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
task_cli="$task_repo/.build/release/codexbridge"
test -x "$task_cli" || { echo 'Run scripts/build.sh first.' >&2; exit 1; }
task_core_dir="$task_repo/.build/core"
mkdir -p "$task_core_dir"
task_version='v1.19.32'
case "$(/usr/bin/uname -m)" in
    arm64)
        task_asset="mihomo-darwin-arm64-$task_version.gz"
        task_expected='3312a6780652c622890fd4357c6a853bbf865464fd047ac7b7f52dab8de18652'
        ;;
    x86_64)
        task_asset="mihomo-darwin-amd64-compatible-$task_version.gz"
        task_expected='18b382df77bded2ad0fb3db27db5636cb15b20729d5ba995a357eeb9b46bf507'
        ;;
    *) echo 'Unsupported architecture.' >&2; exit 1 ;;
esac
task_archive="$task_core_dir/$task_asset"
task_actual=''
if [ -f "$task_archive" ]; then task_actual="$(/usr/bin/shasum -a 256 "$task_archive" | /usr/bin/awk '{print $1}')"; fi
if [ "$task_actual" != "$task_expected" ]; then
    task_proxy="$("$task_cli" proxy-url)"
    /usr/bin/curl --fail --location --retry 2 --connect-timeout 10 --max-time 180 \
        --proxy "$task_proxy" --noproxy '' \
        "https://github.com/MetaCubeX/mihomo/releases/download/$task_version/$task_asset" \
        --output "$task_archive.part"
    task_actual="$(/usr/bin/shasum -a 256 "$task_archive.part" | /usr/bin/awk '{print $1}')"
    [ "$task_actual" = "$task_expected" ] || { echo 'Official release SHA256 mismatch; refusing core.' >&2; exit 1; }
    mv "$task_archive.part" "$task_archive"
fi
/usr/bin/gzip -dc "$task_archive" > "$task_core_dir/mihomo.part"
chmod 755 "$task_core_dir/mihomo.part"
mv "$task_core_dir/mihomo.part" "$task_core_dir/mihomo"
/usr/bin/shasum -a 256 "$task_core_dir/mihomo" | /usr/bin/awk '{print $1}' > "$task_core_dir/core.sha256"
echo "Official Mihomo $task_version verified and prepared."
