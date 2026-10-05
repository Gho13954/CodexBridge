#!/bin/bash
set -euo pipefail
[ "$(/usr/bin/id -u)" -eq 0 ] || { echo 'Administrator authorization required.' >&2; exit 1; }
task_label='io.github.codexbridge'
task_root='/Library/Application Support/CodexBridge'
task_plist="/Library/LaunchDaemons/$task_label.plist"
if [ -L "$task_root" ] || [ -L "$task_plist" ]; then echo 'Refusing a symlink at the service install path.' >&2; exit 1; fi
case "${1:-}" in
    install)
        task_repo="${2:?Project directory required}"
        task_user_home="${3:?User home required}"
        task_sha="$(cat "$task_repo/.build/core/core.sha256")"
        [[ "$task_sha" =~ ^[a-f0-9]{64}$ ]] || { echo 'Invalid core SHA256.' >&2; exit 1; }
        task_actual="$(/usr/bin/shasum -a 256 "$task_repo/.build/core/mihomo" | /usr/bin/awk '{print $1}')"
        [ "$task_actual" = "$task_sha" ] || { echo 'Core changed since verification.' >&2; exit 1; }
        /usr/bin/plutil -lint "$task_repo/Resources/io.github.codexbridge.plist"
        task_backup="$(/usr/bin/mktemp -d /private/tmp/codexbridge-install.XXXXXX)"
        task_had_install=0
        task_had_plist=0
        if [ -d "$task_root" ]; then /bin/cp -R "$task_root" "$task_backup/previous"; task_had_install=1; fi
        if [ -f "$task_plist" ]; then /bin/cp "$task_plist" "$task_backup/previous.plist"; task_had_plist=1; fi
        task_committed=0
        task_touched=0
        task_staging="$(/usr/bin/mktemp -d '/Library/Application Support/.CodexBridge-stage.XXXXXX')"
        cleanup() {
            task_exit=$?
            if [ "$task_committed" -eq 0 ] && [ "$task_touched" -eq 1 ]; then
                /bin/launchctl bootout "system/$task_label" >/dev/null 2>&1 || true
                /bin/rm -rf "$task_root"
                /bin/rm -f "$task_plist"
                if [ "$task_had_install" -eq 1 ]; then /bin/mv "$task_backup/previous" "$task_root"; fi
                if [ "$task_had_plist" -eq 1 ]; then
                    /bin/cp "$task_backup/previous.plist" "$task_plist"
                    /bin/launchctl bootstrap system "$task_plist" || true
                fi
                echo 'Installation failed; the previous installation was restored.' >&2
            fi
            /bin/rm -rf "$task_backup" "$task_staging"
            exit "$task_exit"
        }
        trap cleanup EXIT
        /usr/bin/install -m 755 -o root -g wheel "$task_repo/.build/release/codexbridge" "$task_staging/codexbridge"
        /usr/bin/install -m 755 -o root -g wheel "$task_repo/.build/core/mihomo" "$task_staging/mihomo"
        "$task_staging/codexbridge" config "$task_sha" "$task_user_home" > "$task_staging/config.json"
        /bin/chmod 600 "$task_staging/config.json"
        /bin/chown -R root:wheel "$task_staging"
        /bin/chmod 755 "$task_staging"
        /bin/mkdir -p "$task_staging/logs"
        /bin/chmod 700 "$task_staging/logs"
        # Stop the old job only after a complete replacement is ready.
        if /bin/launchctl print "system/$task_label" >/dev/null 2>&1; then
            /bin/launchctl bootout "system/$task_label"
        fi
        task_touched=1
        if [ -d "$task_root/logs" ]; then /bin/cp -R "$task_root/logs/." "$task_staging/logs/"; fi
        /bin/rm -rf "$task_root"
        /bin/mv "$task_staging" "$task_root"
        /usr/bin/install -m 644 -o root -g wheel "$task_repo/Resources/io.github.codexbridge.plist" "$task_plist"
        /bin/launchctl enable "system/$task_label"
        /bin/launchctl bootstrap system "$task_plist"
        for task_try in {1..10}; do
            [ -f "$task_root/status.json" ] && break
            /bin/sleep 1
        done
        /bin/launchctl print "system/$task_label" >/dev/null
        "$task_root/codexbridge" status
        task_committed=1
        echo 'CodexBridge boot service installed. Terminal may now be closed.'
        ;;
    stop) /bin/launchctl bootout "system/$task_label" ;;
    start) /bin/launchctl enable "system/$task_label"; /bin/launchctl bootstrap system "$task_plist" ;;
    restart) /bin/launchctl kickstart -k "system/$task_label" ;;
    uninstall)
        /bin/launchctl bootout "system/$task_label" >/dev/null 2>&1 || true
        /bin/rm -f "$task_plist"
        /bin/rm -rf "$task_root" /var/run/codexbridge
        echo 'CodexBridge service, installed binaries, runtime state and logs removed. Project source retained.'
        ;;
    *) echo 'Usage: service-admin.sh install <repo> <user-home> | start | stop | restart | uninstall' >&2; exit 1 ;;
esac
