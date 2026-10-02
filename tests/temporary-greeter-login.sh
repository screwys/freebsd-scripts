#!/bin/sh

# Use only in the temporary FreeBSD CI VM with the synthetic ci-login account.
set +x
set -eu

export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
[ "$(uname -s)" = FreeBSD ] || { printf '%s\n' 'This fixture requires native FreeBSD.' >&2; exit 1; }
[ "$(id -u)" = 0 ] || { printf '%s\n' 'This fixture requires root in the CI VM.' >&2; exit 1; }
: "${CI_LOGIN_PASSWORD:?Supply the synthetic account password in CI_LOGIN_PASSWORD}"
ci_password=$CI_LOGIN_PASSWORD
ci_wrong_password=incorrect-$ci_password
unset CI_LOGIN_PASSWORD

for tool in Xvfb xdotool niri noctalia jq timeout greetd; do
	command -v "$tool" >/dev/null || { printf '%s\n' "Missing CI package command: $tool" >&2; exit 1; }
done
[ "$(id -u ci-login)" = 2001 ] || { printf '%s\n' 'ci-login must have UID 2001.' >&2; exit 1; }

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fixture_root=/tmp/freebsd-greeter-ci
login_home=$(getent passwd ci-login | awk -F: '{print $6}')
profile=$login_home/.profile
niri_config=$login_home/.config/niri/config.kdl
report_dir=$login_home/.cache/freebsd-greeter-ci
greeter_uid=$(id -u greetd)
greeter_gid=$(id -g greetd)
stage=setup
greetd_pid=
xvfb_pid=
profile_saved=false
profile_created=false
niri_saved=false
passed=false

mkdir -p "$fixture_root"
chmod 755 "$fixture_root"

stop_tree()
{
	for child in $(pgrep -P "$1" 2>/dev/null || true); do
		stop_tree "$child"
	done
	kill -TERM "$1" 2>/dev/null || true
}

finish()
{
	status=$?
	trap - EXIT
	set +e
	[ -z "$greetd_pid" ] || stop_tree "$greetd_pid"
	pkill -TERM -u 2001 2>/dev/null
	[ -z "$xvfb_pid" ] || kill -TERM "$xvfb_pid" 2>/dev/null
	for pid in $greetd_pid $xvfb_pid; do
		attempt=0
		while kill -0 "$pid" 2>/dev/null; do
			[ "$attempt" -lt 10 ] || break
			sleep 1
			attempt=$((attempt + 1))
		done
		kill -KILL "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
	done
	pkill -KILL -u 2001 2>/dev/null
	if "$profile_saved"; then
		cp -p "$fixture_root/profile.original" "$profile" || status=1
	elif "$profile_created"; then
		rm -f "$profile"
	fi
	if "$niri_saved"; then
		cp -p "$fixture_root/config.kdl.original" "$niri_config" || status=1
	fi
	if [ -d "$report_dir" ]; then
		rm -rf "$fixture_root/session"
		cp -R "$report_dir" "$fixture_root/session"
	fi
	if [ "$status" -ne 0 ] || ! "$passed"; then
		[ "$status" -ne 0 ] || status=1
		jq -n --arg stage "$stage" --argjson exitStatus "$status" \
			'{status: "failed", stage: $stage, exitStatus: $exitStatus}' >"$fixture_root/result.json"
		for file in "$fixture_root/greetd.log" "$fixture_root/greeter.log" "$fixture_root/xvfb.log" \
			"$report_dir/probe.log" "$report_dir/failure.json"; do
			[ ! -f "$file" ] || { printf '\n%s\n' "$file"; tail -n 100 "$file"; }
		done
	fi
	printf '%s\n' "Synthetic login reports: $fixture_root"
	exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail()
{
	printf '%s\n' "Login fixture failed at $stage: $*" >&2
	exit 1
}

wait_until()
{
	description=$1
	shift
	deadline=$(($(date +%s) + 90))
	while ! "$@"; do
		[ ! -f "$report_dir/failure.json" ] || fail 'session probe reported a failure'
		[ -z "$greetd_pid" ] || kill -0 "$greetd_pid" 2>/dev/null || fail 'greetd exited'
		[ "$(date +%s)" -lt "$deadline" ] || fail "timed out waiting for $description"
		sleep 1
	done
}

log_count()
{
	awk -v needle="$1" 'index($0, needle) { count++ } END { print count + 0 }' "$fixture_root/greeter.log"
}

log_reached()
{
	[ "$(log_count "$1")" -ge "$2" ]
}

greeter_ready()
{
	log_reached 'greeter initialized (' "$1" || return 1
	greeter_window=$(DISPLAY=:99 timeout 5 xdotool search --onlyvisible --name '^wlroots' 2>/dev/null | head -n 1)
	[ -n "$greeter_window" ]
}

greeter_returned()
{
	! DISPLAY=:99 timeout 5 xdotool getwindowname "$first_window" >/dev/null 2>&1 || return 1
	greeter_ready 2
}

submit_password()
{
	DISPLAY=:99 timeout 10 xdotool windowfocus --sync "$greeter_window"
	DISPLAY=:99 timeout 5 xdotool key --clearmodifiers ctrl+u
	# Read stdin so the password never appears in process arguments or logs.
	printf '%s' "$1" | DISPLAY=:99 timeout 15 xdotool type --clearmodifiers --delay 40 --file -
	DISPLAY=:99 timeout 5 xdotool key --clearmodifiers Return
}

[ -f "$niri_config" ] || fail 'installer-generated Niri configuration is missing'
[ -f /usr/local/etc/greetd/config.toml ] || fail 'installed greetd configuration is missing'
[ -x /usr/local/bin/freebsd-noctalia-greeter-session ] || fail 'installed greeter session wrapper is missing'
[ -x /usr/local/bin/freebsd-niri-session ] || fail 'installed Niri session wrapper is missing'
[ -f /usr/local/share/wayland-sessions/niri.desktop ] || fail 'installed Niri desktop entry is missing'

rm -f "$fixture_root/result.json" "$fixture_root/greeter.log"
rm -rf "$report_dir"
install -d -o 2001 -g "$(id -g ci-login)" -m 700 "$report_dir"
install -m 755 "$script_dir/temporary-session-probe.sh" "$fixture_root/session-probe"
cat >"$fixture_root/run-probe" <<EOF
#!/bin/sh
exec "$fixture_root/session-probe" "$report_dir" "$login_home" >"$report_dir/probe.log" 2>&1
EOF
chmod 755 "$fixture_root/run-probe"

if [ -f "$profile" ]; then
	cp -p "$profile" "$fixture_root/profile.original"
	profile_saved=true
else
	install -o 2001 -g "$(id -g ci-login)" -m 644 /dev/null "$profile"
	profile_created=true
fi
cat >>"$profile" <<'EOF'

# The CI session runs nested inside the synthetic X server.
export DISPLAY=:99
export LIBGL_ALWAYS_SOFTWARE=1
export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
EOF
cp -p "$niri_config" "$fixture_root/config.kdl.original"
niri_saved=true
printf '\nspawn-at-startup "%s/run-probe"\n' "$fixture_root" >>"$niri_config"
niri validate -c "$niri_config"

awk -v command="env DISPLAY=:99 WLR_BACKENDS=x11 WLR_X11_OUTPUTS=1 WLR_RENDERER=pixman LIBGL_ALWAYS_SOFTWARE=1 WLR_LOG=info NOCTALIA_GREETER_LOG=$fixture_root/greeter.log /usr/local/bin/freebsd-noctalia-greeter-session --user ci-login --session Niri" '
	/^\[/ { section = $0 }
	section == "[terminal]" && /^[[:space:]]*vt[[:space:]]*=/ {
		print "vt = \"none\""; terminals++; next
	}
	section == "[default_session]" && /^[[:space:]]*command[[:space:]]*=/ {
		print "command = \"" command "\""; commands++; next
	}
	{ print }
	END { if (terminals != 1 || commands != 1) exit 1 }
' /usr/local/etc/greetd/config.toml >"$fixture_root/config.toml"
install -o "$greeter_uid" -g "$greeter_gid" -m 600 /dev/null "$fixture_root/greeter.log"

stage=initial-greeter
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp -ac >"$fixture_root/xvfb.log" 2>&1 &
xvfb_pid=$!
wait_until 'Xvfb' env DISPLAY=:99 timeout 5 xdotool getdisplaygeometry
greetd -c "$fixture_root/config.toml" >"$fixture_root/greetd.log" 2>&1 &
greetd_pid=$!
wait_until 'initial greeter' greeter_ready 1
first_window=$greeter_window

stage=wrong-password
submit_password "$ci_wrong_password"
wait_until 'PAM rejection' log_reached 'authentication failed:' 1
wait_until 'authentication cancellation' log_reached 'greetd reply to cancel_session: success' 1
[ ! -f "$report_dir/identity.json" ] || fail 'a session started after the wrong password'

stage=authenticated-session
submit_password "$ci_password"
unset ci_password
wait_until 'confirmed session start' log_reached 'session start confirmed, exiting greeter' 1
wait_until 'Niri and Noctalia readiness' test -f "$report_dir/ready.json"
[ ! -f "$report_dir/failure.json" ] || fail 'session probe reported a failure'
jq -e --arg home "$login_home" '
	.uid == 2001 and .username == "ci-login" and .home == $home and
	.sessionType == "wayland" and .sessionDesktop == "niri" and .currentDesktop == "niri" and
	.runtimeDirectory == "/var/run/xdg/ci-login" and .runtimeOwner == 2001 and .runtimeMode == "700"
' "$report_dir/identity.json" >/dev/null
jq -e '.barVisible == true and .locked == false' "$report_dir/status.json" >/dev/null
jq -e 'any(.[]; (.namespace // "") | startswith("noctalia-bar-"))' "$report_dir/layers.json" >/dev/null

stage=logout
touch "$report_dir/logout"
wait_until 'Noctalia logout reply' test -f "$report_dir/complete.json"
jq -e '.status == "passed"' "$report_dir/complete.json" >/dev/null
wait_until 'returned greeter' greeter_returned

stage=returned-greeter-authentication
submit_password "$ci_wrong_password"
unset ci_wrong_password
wait_until 'PAM rejection from the returned greeter' log_reached 'authentication failed:' 2
wait_until 'returned authentication cancellation' log_reached 'greetd reply to cancel_session: success' 2
kill -0 "$greetd_pid"

jq -n --slurpfile session "$report_dir/identity.json" \
	'{status: "passed", wrongPasswordRejected: true, authenticatedSession: $session[0],
	  noctaliaBarMapped: true, noctaliaLogoutAccepted: true, returnedGreeterRejectedWrongPassword: true}' \
	>"$fixture_root/result.json"
passed=true
printf '%s\n' 'Native FreeBSD greeter login, Niri/Noctalia session, and return passed.'
