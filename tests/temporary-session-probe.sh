#!/bin/sh

# Run inside the synthetic user's session in the temporary native CI job.
set +x
set -eu

export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
report_dir=$1
expected_home=$2
stage=identity
failure_reason='session probe exited before completion'

finish()
{
	status=$?
	trap - EXIT
	set +e
	if [ "$status" -ne 0 ]; then
		jq -n --arg stage "$stage" --arg reason "$failure_reason" \
			--argjson exitStatus "$status" \
			'{status: "failed", stage: $stage, reason: $reason, exitStatus: $exitStatus}' \
			>"$report_dir/failure.json.tmp"
		mv "$report_dir/failure.json.tmp" "$report_dir/failure.json"
	fi
	exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail()
{
	failure_reason=$1
	printf '%s\n' "$failure_reason" >&2
	exit 1
}

jq -n \
	--argjson uid "$(id -u)" --argjson gid "$(id -g)" \
	--arg username "$(id -un)" --arg home "${HOME:-}" \
	--arg user "${USER:-}" --arg logname "${LOGNAME:-}" \
	--arg workingDirectory "$(pwd)" \
	--arg sessionType "${XDG_SESSION_TYPE:-}" \
	--arg sessionDesktop "${XDG_SESSION_DESKTOP:-}" \
	--arg currentDesktop "${XDG_CURRENT_DESKTOP:-}" \
	--arg runtimeDirectory "${XDG_RUNTIME_DIR:-}" \
	--arg waylandDisplay "${WAYLAND_DISPLAY:-}" --arg niriSocket "${NIRI_SOCKET:-}" \
	'{uid: $uid, gid: $gid, username: $username, home: $home, user: $user,
	  logname: $logname, workingDirectory: $workingDirectory, sessionType: $sessionType,
	  sessionDesktop: $sessionDesktop, currentDesktop: $currentDesktop,
	  runtimeDirectory: $runtimeDirectory, waylandDisplay: $waylandDisplay,
	  niriSocket: $niriSocket}' >"$report_dir/identity.json"

jq -e --arg home "$expected_home" '
	.uid == 2001 and .username == "ci-login" and .home == $home and
	.user == "ci-login" and .logname == "ci-login" and
	.sessionType == "wayland" and .sessionDesktop == "niri" and .currentDesktop == "niri" and
	.runtimeDirectory == "/var/run/xdg/ci-login" and
	(.waylandDisplay | length > 0) and (.niriSocket | length > 0)
' "$report_dir/identity.json" >/dev/null || fail 'authenticated session identity is incorrect'
[ "$HOME" -ef . ] || fail 'authenticated session did not start in its home directory'

[ -d "$XDG_RUNTIME_DIR" ] || fail 'authenticated user runtime directory is missing'
[ "$(stat -f %u "$XDG_RUNTIME_DIR")" = 2001 ] || fail 'runtime directory has the wrong owner'
[ "$(stat -f %Lp "$XDG_RUNTIME_DIR")" = 700 ] || fail 'runtime directory has the wrong mode'
[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] || fail 'Niri Wayland socket is missing'
[ -S "$NIRI_SOCKET" ] || fail 'Niri IPC socket is missing'

runtime_owner=$(stat -f %u "$XDG_RUNTIME_DIR")
runtime_mode=$(stat -f %Lp "$XDG_RUNTIME_DIR")
jq --argjson runtimeOwner "$runtime_owner" --arg runtimeMode "$runtime_mode" \
	'. + {runtimeOwner: $runtimeOwner, runtimeMode: $runtimeMode}' \
	"$report_dir/identity.json" >"$report_dir/identity.json.tmp"
mv "$report_dir/identity.json.tmp" "$report_dir/identity.json"

stage=niri-output
timeout 10 niri msg --json outputs >"$report_dir/outputs.json" 2>"$report_dir/niri-output.log"
jq -e 'type == "object" and length > 0 and any(.[]; .current_mode != null)' \
	"$report_dir/outputs.json" >/dev/null || fail 'Niri has no active output'

stage=noctalia-shell
deadline=$(($(date +%s) + 90))
while :; do
	if timeout 10 noctalia msg status >"$report_dir/status.json.tmp" 2>"$report_dir/noctalia-status.log" &&
		jq -e '.barVisible == true and .locked == false' "$report_dir/status.json.tmp" >/dev/null &&
		timeout 10 niri msg --json layers >"$report_dir/layers.json.tmp" 2>"$report_dir/niri-layers.log" &&
		jq -e 'type == "array" and any(.[]; (.namespace // "") | startswith("noctalia-bar-"))' \
			"$report_dir/layers.json.tmp" >/dev/null; then
		mv "$report_dir/status.json.tmp" "$report_dir/status.json"
		mv "$report_dir/layers.json.tmp" "$report_dir/layers.json"
		break
	fi
	[ "$(date +%s)" -lt "$deadline" ] || fail 'Noctalia did not show its bar inside Niri'
	sleep 1
done

jq -n '{status: "ready"}' >"$report_dir/ready.json.tmp"
mv "$report_dir/ready.json.tmp" "$report_dir/ready.json"

stage=await-logout
deadline=$(($(date +%s) + 90))
while [ ! -f "$report_dir/logout" ]; do
	[ "$(date +%s)" -lt "$deadline" ] || fail 'CI did not request logout'
	sleep 1
done

stage=noctalia-logout
timeout 10 noctalia msg session logout >"$report_dir/logout.txt" 2>"$report_dir/noctalia-logout.log"
[ "$(cat "$report_dir/logout.txt")" = ok ] || fail 'Noctalia did not accept logout'
jq -n '{status: "passed"}' >"$report_dir/complete.json.tmp"
mv "$report_dir/complete.json.tmp" "$report_dir/complete.json"
