#!/bin/sh

set -eu

INSTALL_URL=${INSTALL_URL:-https://raw.githubusercontent.com/screwys/freebsd-scripts/main/install.sh}
TARGET=/
INSTALL_USER=${INSTALL_USER:-}
PKG_BRANCH=${PKG_BRANCH:-latest}
DRY_RUN=0
VALIDATE_ONLY=0
BSDINSTALL_GUIDED=0
FROM_INSTALLER=0
SKIP_NOCTALIA=0
ENABLE_CRASH_DUMPS=0

CORE_PACKAGES='
ca_root_nss
curl
git
gh
jq
yq
sudo
doas
nano
fish
fastfetch
just
ripgrep
fd-find
bat
eza
fzf
tree
wget
direnv
neovim
lazygit
socat
zoxide
btop
duf
dust
hyperfine
tokei
shfmt
hs-ShellCheck
uv
node
npm
python3
py311-pip
'

DESKTOP_PACKAGES='
xorg
gnome-lite
gdm
niri
xwayland-satellite
quickshell
ghostty
gnome-keyring
polkit
nautilus
showtime
xdg-desktop-portal
xdg-desktop-portal-gnome
xdg-desktop-portal-gtk
qt6ct
fcitx5
fcitx5-configtool
fcitx5-gtk3
fcitx5-gtk4
fcitx5-qt5
fcitx5-qt6
ja-fcitx5-anthy
pipewire
wireplumber
wl-clipboard
grim
slurp
wf-recorder
cliphist
wtype
libnotify
ImageMagick7
tesseract
kdeconnect-kde
okular
gwenview
dolphin
kate
konsole
ark
kcalc
plasma6-xdg-desktop-portal-kde
mpv
vlc
obs-studio
libreoffice
signal-desktop
vesktop
qbittorrent
syncthing
xdg-user-dirs
xdg-utils
shared-mime-info
gvfs
mesa-demos
mesa-dri
nerd-fonts-jetbrainsmono
noto-basic
noto-emoji
noto-jp
noto-sans
'

KMOD_PACKAGES='
drm-515-kmod
'

BROWSER_PACKAGES='
firefox
librewolf
chromium
zed
vscode
'

NOCTALIA_PLUGINS='
clipper
file-search
kaomoji-provider
niri-animation-picker
niri-overview-launcher
noctalia-calculator
notes-scratchpad
polkit-agent
pomodoro
screen-recorder
screen-toolkit
timer
todo
weather-indicator
'

log()
{
	printf '%s\n' "==> $*"
}

warn()
{
	printf '%s\n' "warn: $*" >&2
}

die()
{
	printf '%s\n' "error: $*" >&2
	exit 1
}

usage()
{
	cat <<'EOF'
usage: sh install.sh [options]

options:
  --user NAME              desktop user to create/configure
  --bsdinstall-guided      create a temporary bsdinstall script and run it
  --pkg-branch NAME        FreeBSD pkg branch, default: latest
  --target PATH            configure a mounted root, default: /
  --dry-run                print actions without changing the system
  --validate               validate generated policy JSON and manifests
  --skip-noctalia          skip Noctalia best-effort staging
  --enable-crash-dumps     keep dumpdev=AUTO instead of disabling dumps
  --help                   show this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--user)
			[ $# -ge 2 ] || die "--user needs a value"
			INSTALL_USER=$2
			shift 2
			;;
		--user=*)
			INSTALL_USER=${1#*=}
			shift
			;;
		--bsdinstall-guided)
			BSDINSTALL_GUIDED=1
			shift
			;;
		--pkg-branch)
			[ $# -ge 2 ] || die "--pkg-branch needs a value"
			PKG_BRANCH=$2
			shift 2
			;;
		--pkg-branch=*)
			PKG_BRANCH=${1#*=}
			shift
			;;
		--target)
			[ $# -ge 2 ] || die "--target needs a value"
			TARGET=$2
			shift 2
			;;
		--target=*)
			TARGET=${1#*=}
			shift
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		--validate)
			VALIDATE_ONLY=1
			shift
			;;
		--from-installer)
			FROM_INSTALLER=1
			shift
			;;
		--skip-noctalia)
			SKIP_NOCTALIA=1
			shift
			;;
		--enable-crash-dumps)
			ENABLE_CRASH_DUMPS=1
			shift
			;;
		--help|-h)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		*)
			die "unknown option: $1"
			;;
	esac
done

case "$PKG_BRANCH" in
	latest|quarterly) ;;
	*) die "--pkg-branch must be latest or quarterly" ;;
esac

if [ -n "$INSTALL_USER" ]; then
	case "$INSTALL_USER" in
		*[!A-Za-z0-9._-]*)
			die "--user contains unsupported characters"
			;;
	esac
fi

case "$TARGET" in
	/) ;;
	/*) TARGET=${TARGET%/} ;;
	*) die "--target must be an absolute path" ;;
esac

is_freebsd()
{
	[ "$(uname -s 2>/dev/null || true)" = "FreeBSD" ]
}

need_root()
{
	if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
		die "run as root, or use --dry-run/--validate"
	fi
}

target_path()
{
	path=$1
	path=${path#/}
	if [ "$TARGET" = "/" ]; then
		printf '/%s\n' "$path"
	else
		printf '%s/%s\n' "$TARGET" "$path"
	fi
}

ensure_parent()
{
	path=$1
	dir=${path%/*}
	[ "$dir" = "$path" ] && dir=.
	[ "$DRY_RUN" -eq 1 ] && return 0
	mkdir -p "$dir"
}

write_file()
{
	path=$1
	mode=${2:-0644}
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would write $path"
		cat >/dev/null
		return 0
	fi
	ensure_parent "$path"
	_write_file_tmp="${path}.tmp.$$"
	cat >"$_write_file_tmp"
	chmod "$mode" "$_write_file_tmp"
	mv "$_write_file_tmp" "$path"
}

append_unique_line()
{
	file=$1
	line=$2
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would ensure line in $file: $line"
		return 0
	fi
	ensure_parent "$file"
	touch "$file"
	grep -Fqx "$line" "$file" || printf '%s\n' "$line" >>"$file"
}

set_conf_value()
{
	file=$1
	key=$2
	value=$3
	style=${4:-quoted}

	case "$style" in
		plain) line="${key}=${value}" ;;
		quoted) line="${key}=\"${value}\"" ;;
		*) die "bad set_conf_value style: $style" ;;
	esac

	if [ "$DRY_RUN" -eq 1 ]; then
		log "would set $line in $file"
		return 0
	fi

	ensure_parent "$file"
	touch "$file"
	_set_conf_tmp="${file}.tmp.$$"
	awk -v k="$key" -v repl="$line" '
		BEGIN { done = 0 }
		{
			s = $0
			sub(/^[ \t]*/, "", s)
			if (index(s, k "=") == 1) {
				if (!done) print repl
				done = 1
				next
			}
			print
		}
		END {
			if (!done) print repl
		}
	' "$file" >"$_set_conf_tmp"
	mv "$_set_conf_tmp" "$file"
}

run_cmd()
{
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would run: $*"
		return 0
	fi
	"$@"
}

run_in_target()
{
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would run in $TARGET: $*"
		return 0
	fi
	if [ "$TARGET" = "/" ]; then
		/bin/sh -c "$*"
	else
		chroot "$TARGET" /bin/sh -c "$*"
	fi
}

package_manifest()
{
	printf '%s\n%s\n%s\n' "$CORE_PACKAGES" "$DESKTOP_PACKAGES" "$BROWSER_PACKAGES" |
		awk 'NF { print $1 }'
}

kmod_manifest()
{
	printf '%s\n' "$KMOD_PACKAGES" |
		awk 'NF { print $1 }'
}

all_package_manifest()
{
	printf '%s\n%s\n' "$(package_manifest)" "$(kmod_manifest)" |
		awk 'NF { print $1 }'
}

ensure_pkg_repo()
{
	repo_dir=$(target_path /usr/local/etc/pkg/repos)
	repo_file=$(target_path /usr/local/etc/pkg/repos/FreeBSD.conf)
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would set FreeBSD pkg branch to $PKG_BRANCH"
		return 0
	fi
	mkdir -p "$repo_dir"
	cat >"$repo_file" <<EOF
FreeBSD: {
  url: "pkg+https://pkg.FreeBSD.org/\${ABI}/$PKG_BRANCH",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
EOF
}

freebsd_release()
{
	if [ "$TARGET" = "/" ]; then
		freebsd-version -u 2>/dev/null || uname -r
	else
		chroot "$TARGET" /bin/sh -c 'freebsd-version -u 2>/dev/null || uname -r'
	fi
}

kmods_flavor()
{
	release=$(freebsd_release)
	case "$release" in
		14.*-RELEASE*)
			minor=${release#14.}
			minor=${minor%%-*}
			printf 'kmods_%s_%s\n' "$PKG_BRANCH" "$minor"
			;;
		*)
			printf 'kmods_%s\n' "$PKG_BRANCH"
			;;
	esac
}

ensure_kmods_repo()
{
	repo_dir=$(target_path /usr/local/etc/pkg/repos)
	repo_file=$(target_path /usr/local/etc/pkg/repos/kmods.conf)
	flavor=$(kmods_flavor)
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would set FreeBSD kmods pkg branch to $flavor"
		return 0
	fi
	mkdir -p "$repo_dir"
	cat >"$repo_file" <<EOF
FreeBSD-kmods: {
  url: "pkg+https://pkg.FreeBSD.org/\${ABI}/$flavor",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
EOF
}

pkg_exists()
{
	pkg=$1
	[ "$DRY_RUN" -eq 1 ] && return 0
	if [ "$TARGET" = "/" ]; then
		pkg search -q "^${pkg}$" >/dev/null 2>&1
	else
		chroot "$TARGET" /bin/sh -c "pkg search -q '^${pkg}$' >/dev/null 2>&1"
	fi
}

pkg_exists_in_repo()
{
	repo=$1
	pkg=$2
	[ "$DRY_RUN" -eq 1 ] && return 0
	if [ "$TARGET" = "/" ]; then
		pkg search -r "$repo" -q "^${pkg}$" >/dev/null 2>&1
	else
		chroot "$TARGET" /bin/sh -c "pkg search -r '$repo' -q '^${pkg}$' >/dev/null 2>&1"
	fi
}

install_gpu_firmware_kmods()
{
	if [ "$DRY_RUN" -eq 1 ]; then
		log "would install available gpu-firmware-* kmods from FreeBSD-kmods"
		return 0
	fi

	run_in_target "
firmware_pkgs=\$(pkg search -r FreeBSD-kmods -q '^gpu-firmware-.*-kmod-' | tr '\n' ' ')
if [ -n \"\$firmware_pkgs\" ]; then
	env ASSUME_ALWAYS_YES=yes pkg install -y -r FreeBSD-kmods \$firmware_pkgs
else
	printf '%s\n' 'warn: no gpu firmware kmod packages found on FreeBSD-kmods' >&2
fi
"
}

install_packages()
{
	ensure_pkg_repo
	ensure_kmods_repo

	if ! is_freebsd && [ "$DRY_RUN" -eq 0 ]; then
		die "package installation must run on FreeBSD"
	fi

	run_in_target "env ASSUME_ALWAYS_YES=yes pkg bootstrap -f"
	run_in_target "env ASSUME_ALWAYS_YES=yes pkg update -f"

	available=
	skipped=
	for pkg in $(package_manifest); do
		if pkg_exists "$pkg"; then
			available="$available $pkg"
		else
			skipped="$skipped $pkg"
		fi
	done

	if [ -n "$available" ]; then
		run_in_target "env ASSUME_ALWAYS_YES=yes pkg install -y $available"
	fi

	if [ -n "$skipped" ]; then
		warn "packages not found on this pkg branch:$skipped"
	fi

	kmod_available=
	kmod_skipped=
	for pkg in $(kmod_manifest); do
		if pkg_exists_in_repo FreeBSD-kmods "$pkg"; then
			kmod_available="$kmod_available $pkg"
		else
			kmod_skipped="$kmod_skipped $pkg"
		fi
	done

	if [ -n "$kmod_available" ]; then
		run_in_target "env ASSUME_ALWAYS_YES=yes pkg install -y -r FreeBSD-kmods $kmod_available"
	fi

	if [ -n "$kmod_skipped" ]; then
		warn "kmod packages not found on this kmods branch:$kmod_skipped"
	fi

	install_gpu_firmware_kmods
}

configure_rc_conf()
{
	rc=$(target_path /etc/rc.conf)

	set_conf_value "$rc" dbus_enable YES
	set_conf_value "$rc" gdm_enable YES
	set_conf_value "$rc" seatd_enable YES
	set_conf_value "$rc" powerd_enable YES
	set_conf_value "$rc" ntpd_enable YES
	set_conf_value "$rc" ntpd_sync_on_start YES
	set_conf_value "$rc" zfs_enable YES
	set_conf_value "$rc" sshd_enable NO
	set_conf_value "$rc" clear_tmp_enable YES
	set_conf_value "$rc" syslogd_flags -ss
	set_conf_value "$rc" sendmail_enable NONE
	set_conf_value "$rc" sendmail_submit_enable NO
	set_conf_value "$rc" sendmail_outbound_enable NO
	set_conf_value "$rc" sendmail_msp_queue_enable NO
	set_conf_value "$rc" xdg_runtime_base_enable YES

	if [ "$ENABLE_CRASH_DUMPS" -eq 1 ]; then
		set_conf_value "$rc" dumpdev AUTO
	else
		set_conf_value "$rc" dumpdev NO
	fi

	for svc in pipewire wireplumber pipewire_pulse; do
		if [ "$DRY_RUN" -eq 1 ] || [ -x "$(target_path /usr/local/etc/rc.d/$svc)" ]; then
			set_conf_value "$rc" "${svc}_enable" YES
		fi
	done
}

configure_hardening()
{
	sysctl_file=$(target_path /etc/sysctl.conf)
	loader_file=$(target_path /boot/loader.conf)

	set_conf_value "$sysctl_file" security.bsd.see_other_uids 0 plain
	set_conf_value "$sysctl_file" security.bsd.see_other_gids 0 plain
	set_conf_value "$sysctl_file" security.bsd.see_jail_proc 0 plain
	set_conf_value "$sysctl_file" security.bsd.unprivileged_read_msgbuf 0 plain
	set_conf_value "$sysctl_file" security.bsd.unprivileged_proc_debug 0 plain
	set_conf_value "$sysctl_file" kern.randompid 1 plain
	set_conf_value "$loader_file" security.bsd.allow_destructive_dtrace 0
}

configure_mounts()
{
	fstab=$(target_path /etc/fstab)
	append_unique_line "$fstab" "proc	/proc	procfs	rw	0	0"

	if [ "$DRY_RUN" -eq 1 ]; then
		log "would create /var/run/user with mode 1777"
	else
		mkdir -p "$(target_path /var/run/user)"
		chmod 1777 "$(target_path /var/run/user)"
	fi
}

configure_doas_and_editor()
{
	doas_file=$(target_path /usr/local/etc/doas.conf)
	profile_file=$(target_path /usr/local/etc/profile.d/freebsd-scripts.sh)

	write_file "$doas_file" 0644 <<'EOF'
permit persist :wheel
EOF

	write_file "$profile_file" 0644 <<'EOF'
export EDITOR=nano
export VISUAL=nano
export PAGER=${PAGER:-less}
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
	XDG_RUNTIME_DIR="/var/run/user/$(id -u)"
	export XDG_RUNTIME_DIR
	if [ ! -d "$XDG_RUNTIME_DIR" ]; then
		mkdir -p -m 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
	fi
	chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
fi
EOF
}

configure_xdg_runtime_rc()
{
	rc_script=$(target_path /usr/local/etc/rc.d/xdg_runtime_base)
	write_file "$rc_script" 0755 <<'EOF'
#!/bin/sh

# PROVIDE: xdg_runtime_base
# REQUIRE: LOGIN
# BEFORE: gdm

. /etc/rc.subr

name=xdg_runtime_base
rcvar=xdg_runtime_base_enable
start_cmd="${name}_start"

: ${xdg_runtime_base_enable:=NO}

xdg_runtime_base_start()
{
	install -d -m 1777 /var/run/user
}

load_rc_config $name
run_rc_command "$1"
EOF
}

configure_niri_session()
{
	session_bin=$(target_path /usr/local/bin/freebsd-niri-session)
	session_desktop=$(target_path /usr/local/share/wayland-sessions/niri.desktop)

	write_file "$session_bin" 0755 <<'EOF'
#!/bin/sh

export XDG_CURRENT_DESKTOP=niri
export XDG_SESSION_DESKTOP=niri
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland,x11

if command -v dbus-update-activation-environment >/dev/null 2>&1; then
	dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR
fi

if [ -x /usr/local/bin/niri-session ]; then
	exec /usr/local/bin/niri-session
fi

exec /usr/local/bin/niri
EOF

	write_file "$session_desktop" 0644 <<'EOF'
[Desktop Entry]
Name=Niri
Comment=Run Niri
Exec=/usr/local/bin/freebsd-niri-session
Type=Application
DesktopNames=niri
EOF
}

passwd_file()
{
	target_path /etc/passwd
}

group_file()
{
	target_path /etc/group
}

discover_user()
{
	[ -f "$(passwd_file)" ] || return 1
	awk -F: '$3 >= 1000 && $6 ~ /^\/(usr\/)?home\// { print $1; exit }' "$(passwd_file)"
}

user_record()
{
	user=$1
	[ -f "$(passwd_file)" ] || return 1
	awk -F: -v u="$user" '$1 == u { print; found = 1; exit } END { exit found ? 0 : 1 }' "$(passwd_file)"
}

group_exists()
{
	group=$1
	[ -f "$(group_file)" ] || return 1
	awk -F: -v g="$group" '$1 == g { found = 1; exit } END { exit found ? 0 : 1 }' "$(group_file)"
}

existing_groups_csv()
{
	out=
	for group in wheel operator video webcamd seatd _seatd; do
		if group_exists "$group"; then
			if [ -n "$out" ]; then
				out="$out,$group"
			else
				out=$group
			fi
		fi
	done
	printf '%s\n' "$out"
}

ensure_user()
{
	[ -n "$INSTALL_USER" ] || INSTALL_USER=$(discover_user || true)
	[ -n "$INSTALL_USER" ] || {
		warn "no desktop user found; pass --user NAME to create/configure one"
		return 0
	}

	if user_record "$INSTALL_USER" >/dev/null 2>&1; then
		log "configuring existing user $INSTALL_USER"
	else
		groups=$(existing_groups_csv)
		shell=/bin/sh
		if [ "$DRY_RUN" -eq 1 ] || [ -x "$(target_path /usr/local/bin/fish)" ]; then
			shell=/usr/local/bin/fish
		fi
		cmd="pw useradd '$INSTALL_USER' -m -s '$shell'"
		[ -n "$groups" ] && cmd="$cmd -G '$groups'"
		run_in_target "$cmd"
		if [ "$DRY_RUN" -eq 0 ]; then
			warn "set a password for $INSTALL_USER"
			if [ "$TARGET" = "/" ]; then
				passwd "$INSTALL_USER" || warn "password was not set for $INSTALL_USER"
			else
				chroot "$TARGET" passwd "$INSTALL_USER" || warn "password was not set for $INSTALL_USER"
			fi
		fi
	fi

	for group in wheel operator video webcamd seatd _seatd; do
		if [ "$DRY_RUN" -eq 1 ] || group_exists "$group"; then
			run_in_target "pw groupmod '$group' -m '$INSTALL_USER'" || true
		fi
	done

	if [ "$DRY_RUN" -eq 1 ] || [ -x "$(target_path /usr/local/bin/fish)" ]; then
		run_in_target "pw usermod '$INSTALL_USER' -s /usr/local/bin/fish" || true
	fi
}

user_field()
{
	user=$1
	field=$2
	record=$(user_record "$user" 2>/dev/null || true)
	if [ -n "$record" ]; then
		printf '%s\n' "$record" | awk -F: -v f="$field" '{ print $f }'
		return 0
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		case "$field" in
			3|4) printf '%s\n' 1001 ;;
			6) printf '/home/%s\n' "$user" ;;
			*) printf '\n' ;;
		esac
		return 0
	fi

	return 1
}

user_path()
{
	home=$1
	rel=$2
	path="${home%/}/$rel"
	if [ "$TARGET" = "/" ]; then
		printf '%s\n' "$path"
	else
		printf '%s/%s\n' "$TARGET" "${path#/}"
	fi
}

write_user_file()
{
	user=$1
	rel=$2
	mode=$3
	home=$(user_field "$user" 6)
	uid=$(user_field "$user" 3)
	gid=$(user_field "$user" 4)
	path=$(user_path "$home" "$rel")

	write_file "$path" "$mode"

	if [ "$DRY_RUN" -eq 0 ]; then
		chown "$uid:$gid" "$path"
	fi
}

configure_user_files()
{
	[ -n "$INSTALL_USER" ] || return 0
	if ! user_record "$INSTALL_USER" >/dev/null 2>&1 && [ "$DRY_RUN" -eq 0 ]; then
		warn "skipping user files; $INSTALL_USER does not exist"
		return 0
	fi

	write_user_file "$INSTALL_USER" .config/fish/config.fish 0644 <<'EOF'
set -gx EDITOR nano
set -gx VISUAL nano
set -gx PAGER less

if test -z "$XDG_RUNTIME_DIR"
    set -gx XDG_RUNTIME_DIR /var/run/user/(id -u)
    mkdir -p -m 700 "$XDG_RUNTIME_DIR" 2>/dev/null
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
end

if command -q zoxide
    zoxide init fish | source
end
EOF

	write_user_file "$INSTALL_USER" .config/ghostty/config 0644 <<'EOF'
font-family = JetBrainsMono Nerd Font
command = /usr/local/bin/fish
confirm-close-surface = false
copy-on-select = clipboard
EOF

	write_user_file "$INSTALL_USER" .config/niri/config.kdl 0644 <<'EOF'
environment {
    SHELL "/usr/local/bin/fish"
    EDITOR "nano"
    VISUAL "nano"
    XDG_CURRENT_DESKTOP "niri"
    XDG_SESSION_TYPE "wayland"
    QT_QPA_PLATFORM "wayland"
    GDK_BACKEND "wayland,x11"
    GTK_IM_MODULE "fcitx"
    QT_IM_MODULE "fcitx"
    XMODIFIERS "@im=fcitx"
}

input {
    keyboard {
        xkb {
            layout "us"
        }
    }
    touchpad {
        tap
        natural-scroll
    }
}

layout {
    gaps 8
    center-focused-column "never"
    preset-column-widths {
        proportion 0.33333
        proportion 0.5
        proportion 0.66667
    }
    default-column-width { proportion 0.5; }
}

spawn-at-startup "dbus-update-activation-environment" "--systemd" "DISPLAY" "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP" "XDG_SESSION_TYPE" "XDG_RUNTIME_DIR"
spawn-at-startup "gnome-keyring-daemon" "--start" "--components=secrets"
spawn-at-startup "fcitx5" "-d"
spawn-at-startup "qs" "-c" "noctalia-shell"

prefer-no-csd
screenshot-path "~/Pictures/Screenshots/%Y-%m-%d_%H-%M-%S.png"

binds {
    Mod+Return { spawn "ghostty"; }
    Mod+B { spawn "librewolf"; }
    Mod+E { spawn "nautilus"; }
    Mod+D { spawn "qs" "-c" "noctalia-shell" "ipc" "call" "launcher" "toggle"; }
    Mod+Q { close-window; }
    Mod+F { maximize-column; }
    Mod+Shift+F { fullscreen-window; }
    Mod+H { focus-column-left; }
    Mod+L { focus-column-right; }
    Mod+J { focus-window-down; }
    Mod+K { focus-window-up; }
    Mod+Shift+H { move-column-left; }
    Mod+Shift+L { move-column-right; }
    Mod+Shift+J { move-window-down; }
    Mod+Shift+K { move-window-up; }
    Print { spawn "sh" "-c" "grim -g \"$(slurp)\" - | wl-copy"; }
    Mod+Shift+E { quit; }
}
EOF
}

stage_noctalia()
{
	[ "$SKIP_NOCTALIA" -eq 0 ] || return 0
	[ -n "$INSTALL_USER" ] || return 0
	if ! user_record "$INSTALL_USER" >/dev/null 2>&1 && [ "$DRY_RUN" -eq 0 ]; then
		return 0
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		log "would stage Noctalia shell/plugins for $INSTALL_USER"
		warn "FreeBSD quickshell is upstream quickshell, not noctalia-qs; GNOME remains the fallback session"
		return 0
	fi

	home=$(user_field "$INSTALL_USER" 6)
	uid=$(user_field "$INSTALL_USER" 3)
	gid=$(user_field "$INSTALL_USER" 4)
	home_root=$(user_path "$home" .)
	qs_dir="$home_root/.config/quickshell"
	noctalia_dir="$qs_dir/noctalia-shell"
	plugins_dir="$home_root/.config/noctalia/plugins"

	mkdir -p "$qs_dir" "$plugins_dir"

	if [ ! -d "$noctalia_dir" ]; then
		tmp=$(mktemp -d)
		if fetch -o "$tmp/noctalia-shell.tar.gz" https://github.com/noctalia-dev/noctalia-shell/archive/refs/heads/main.tar.gz 2>/dev/null ||
			curl -L -o "$tmp/noctalia-shell.tar.gz" https://github.com/noctalia-dev/noctalia-shell/archive/refs/heads/main.tar.gz; then
			tar -xf "$tmp/noctalia-shell.tar.gz" -C "$tmp"
			found=$(find "$tmp" -maxdepth 1 -type d -name 'noctalia-shell-*' | head -n 1)
			[ -n "$found" ] && mv "$found" "$noctalia_dir"
		else
			warn "could not download noctalia-shell"
		fi
		rm -rf "$tmp"
	fi

	tmp=$(mktemp -d)
	if fetch -o "$tmp/noctalia-plugins.tar.gz" https://github.com/noctalia-dev/noctalia-plugins/archive/refs/heads/main.tar.gz 2>/dev/null ||
		curl -L -o "$tmp/noctalia-plugins.tar.gz" https://github.com/noctalia-dev/noctalia-plugins/archive/refs/heads/main.tar.gz; then
		tar -xf "$tmp/noctalia-plugins.tar.gz" -C "$tmp"
		root=$(find "$tmp" -maxdepth 1 -type d -name 'noctalia-plugins-*' | head -n 1)
		if [ -n "$root" ]; then
			for plugin in $NOCTALIA_PLUGINS; do
				[ -d "$root/$plugin" ] && cp -R "$root/$plugin" "$plugins_dir/"
			done
		fi
	else
		warn "could not download noctalia-plugins"
	fi
	rm -rf "$tmp"

	if [ ! -f "$home_root/.config/noctalia/plugins.json" ]; then
		cat >"$home_root/.config/noctalia/plugins.json" <<'EOF'
{
  "enabled": [
    "clipper",
    "file-search",
    "niri-animation-picker",
    "niri-overview-launcher",
    "noctalia-calculator",
    "polkit-agent",
    "screen-toolkit",
    "todo"
  ]
}
EOF
	fi

	chown -R "$uid:$gid" "$home_root/.config/quickshell" "$home_root/.config/noctalia"
	warn "FreeBSD quickshell is upstream quickshell, not noctalia-qs; GNOME remains the fallback session"
}

write_firefox_policy()
{
	path=$1
	write_file "$path" 0644 <<'EOF'
{
  "policies": {
    "DisableAppUpdate": false,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DisableTelemetry": true,
    "DontCheckDefaultBrowser": true,
    "ExtensionSettings": {
      "uBlock0@raymondhill.net": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi",
        "private_browsing": true
      },
      "jid1-BoFifL9Vbdl2zQ@jetpack": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/decentraleyes/latest.xpi",
        "private_browsing": true
      },
      "78272b6fa58f4a1abaac99321d503a20@proton.me": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/proton-pass/latest.xpi",
        "private_browsing": true
      },
      "vpn@proton.ch": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/proton-vpn-firefox-extension/latest.xpi",
        "private_browsing": true
      }
    },
    "FirefoxHome": {
      "Highlights": false,
      "Pocket": false,
      "Search": true,
      "Snippets": false,
      "SponsoredPocket": false,
      "SponsoredTopSites": false,
      "TopSites": true
    },
    "FirefoxSuggest": {
      "ImproveSuggest": false,
      "SponsoredSuggestions": false,
      "WebSuggestions": false
    },
    "NoDefaultBookmarks": true,
    "OfferToSaveLoginsDefault": false,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "SearchEngines": {
      "Default": "DuckDuckGo",
      "Add": [
        {
          "Name": "DuckDuckGo",
          "URLTemplate": "https://duckduckgo.com/?q={searchTerms}",
          "Method": "GET",
          "IconURL": "https://duckduckgo.com/favicon.ico",
          "Alias": "@ddg",
          "SuggestURLTemplate": ""
        }
      ]
    },
    "SearchSuggestEnabled": false,
    "SkipTermsOfUse": true,
    "UserMessaging": {
      "ExtensionRecommendations": false,
      "FeatureRecommendations": false,
      "MoreFromMozilla": false,
      "SkipOnboarding": true,
      "UrlbarInterventions": false
    }
  }
}
EOF
}

write_browser_policies()
{
	write_firefox_policy "$(target_path /usr/local/lib/firefox/distribution/policies.json)"
	write_firefox_policy "$(target_path /usr/local/lib/librewolf/distribution/policies.json)"
	write_firefox_policy "$(target_path /usr/local/share/librewolf/distribution/policies.json)"

	write_file "$(target_path /usr/local/etc/chromium/policies/managed/freebsd-scripts-privacy.json)" 0644 <<'EOF'
{
  "AlternateErrorPagesEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "BackgroundModeEnabled": false,
  "BlockThirdPartyCookies": true,
  "BrowserSignin": 0,
  "CloudReportingEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "DnsOverHttpsMode": "automatic",
  "ExtensionSettings": {
    "ddkjiahejlhfcafbddmgiahcphecmpfh": {
      "installation_mode": "normal_installed",
      "update_url": "https://clients2.google.com/service/update2/crx"
    },
    "ldpochfccmkkmhdbclfhpagapcfdljkj": {
      "installation_mode": "normal_installed",
      "update_url": "https://clients2.google.com/service/update2/crx"
    },
    "ghmbeldphafepmbegfdlkpapadhbakde": {
      "installation_mode": "normal_installed",
      "update_url": "https://clients2.google.com/service/update2/crx"
    },
    "jplgfhpmjnbigmhklmmbgecoobifkmpa": {
      "installation_mode": "normal_installed",
      "update_url": "https://clients2.google.com/service/update2/crx"
    }
  },
  "MetricsReportingEnabled": false,
  "NetworkPredictionOptions": 2,
  "PasswordManagerEnabled": false,
  "PrivacySandboxAdMeasurementEnabled": false,
  "PrivacySandboxAdTopicsEnabled": false,
  "PrivacySandboxPromptEnabled": false,
  "PrivacySandboxSiteEnabledAdsEnabled": false,
  "PromotionalTabsEnabled": false,
  "SafeBrowsingExtendedReportingEnabled": false,
  "SearchSuggestEnabled": false,
  "SpellCheckServiceEnabled": false,
  "SyncDisabled": true,
  "UrlKeyedAnonymizedDataCollectionEnabled": false
}
EOF

	write_file "$(target_path /usr/local/etc/chromium/policies/recommended/freebsd-scripts-search.json)" 0644 <<'EOF'
{
  "DefaultSearchProviderEnabled": true,
  "DefaultSearchProviderKeyword": "duckduckgo.com",
  "DefaultSearchProviderName": "DuckDuckGo",
  "DefaultSearchProviderSearchURL": "https://duckduckgo.com/?q={searchTerms}"
}
EOF
}

validate_json_files()
{
	root=$1
	files=$(find "$root" -name '*.json' -type f | sort)
	[ -n "$files" ] || die "no JSON files generated"

	if command -v python3 >/dev/null 2>&1; then
		python3 - "$root" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for path in sorted(root.rglob("*.json")):
    with path.open("r", encoding="utf-8") as handle:
        json.load(handle)
    print(path.relative_to(root))
PY
	elif command -v jq >/dev/null 2>&1; then
		for file in $files; do
			jq empty "$file"
			printf '%s\n' "${file#$root/}"
		done
	else
		die "python3 or jq is required to validate JSON"
	fi
}

validate_manifest()
{
	dupes=$(all_package_manifest | sort | uniq -d)
	if [ -n "$dupes" ]; then
		printf '%s\n' "$dupes" >&2
		die "package manifest contains duplicates"
	fi

	all_package_manifest | awk '
		$0 !~ /^[A-Za-z0-9_.+@-]+$/ {
			printf "bad package name: %s\n", $0 > "/dev/stderr"
			bad = 1
		}
		END { exit bad ? 1 : 0 }
	'
}

validate_only()
{
	validate_manifest
	validate_root=$(mktemp -d)
	old_target=$TARGET
	old_dry=$DRY_RUN
	TARGET=$validate_root
	DRY_RUN=0
	write_browser_policies >/dev/null
	validate_json_files "$validate_root"
	TARGET=$old_target
	DRY_RUN=$old_dry
	rm -rf "$validate_root"
	log "validation passed"
}

select_install_disk()
{
	if ! is_freebsd; then
		die "--bsdinstall-guided must be run from the FreeBSD installer"
	fi
	if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
		die "--bsdinstall-guided needs an interactive tty"
	fi

	disks=$(sysctl -n kern.disks 2>/dev/null || true)
	[ -n "$disks" ] || die "could not discover disks from kern.disks"

	printf '%s\n' "available disks:" >/dev/tty
	for disk in $disks; do
		printf '  %s\n' "$disk" >/dev/tty
	done

	printf '%s' "disk to install FreeBSD on: " >/dev/tty
	IFS= read -r disk </dev/tty
	case " $disks " in
		*" $disk "*) ;;
		*) die "disk '$disk' is not in kern.disks" ;;
	esac

	printf '%s\n' "this will let bsdinstall create a ZFS layout on $disk." >/dev/tty
	printf '%s\n' "bsdinstall will show its own final destructive confirmation too." >/dev/tty
	printf '%s' "type the disk name again to continue: " >/dev/tty
	IFS= read -r confirm </dev/tty
	[ "$confirm" = "$disk" ] || die "confirmation did not match"

	printf '%s\n' "$disk"
}

write_bsdinstall_config()
{
	cfg=$1
	disk=$2
	install_args="--from-installer --pkg-branch $PKG_BRANCH"
	[ -n "$INSTALL_USER" ] && install_args="$install_args --user $INSTALL_USER"
	[ "$SKIP_NOCTALIA" -eq 1 ] && install_args="$install_args --skip-noctalia"
	[ "$ENABLE_CRASH_DUMPS" -eq 1 ] && install_args="$install_args --enable-crash-dumps"

	cat >"$cfg" <<EOF
DISTRIBUTIONS="kernel.txz base.txz"
ZFSBOOT_DISKS="$disk"
ZFSBOOT_VDEV_TYPE="stripe"
ZFSBOOT_SWAP_SIZE="2g"
ZFSBOOT_CONFIRM_LAYOUT="1"

#!/bin/sh
set -eu

if command -v fetch >/dev/null 2>&1; then
	fetch -o /tmp/freebsd-install.sh "$INSTALL_URL"
else
	curl -L -o /tmp/freebsd-install.sh "$INSTALL_URL"
fi

sh /tmp/freebsd-install.sh $install_args
EOF
}

run_bsdinstall_guided()
{
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then
		cfg=$(mktemp)
		write_bsdinstall_config "$cfg" "DISK_YOU_CONFIRM"
		log "would prompt for a disk and run: bsdinstall script $cfg"
		cat "$cfg"
		rm -f "$cfg"
		return 0
	fi

	disk=$(select_install_disk)
	cfg=$(mktemp /tmp/freebsd-scripts-bsdinstall.XXXXXX)
	write_bsdinstall_config "$cfg" "$disk"
	log "running bsdinstall script $cfg"
	bsdinstall script "$cfg"
}

main()
{
	if [ "$VALIDATE_ONLY" -eq 1 ]; then
		validate_only
		return 0
	fi

	if [ "$BSDINSTALL_GUIDED" -eq 1 ]; then
		run_bsdinstall_guided
		return 0
	fi

	need_root

	if [ "$FROM_INSTALLER" -eq 1 ]; then
		log "running post-install bootstrap inside bsdinstall chroot"
	fi

	install_packages
	configure_rc_conf
	configure_hardening
	configure_mounts
	configure_doas_and_editor
	configure_xdg_runtime_rc
	configure_niri_session
	write_browser_policies
	ensure_user
	configure_user_files
	stage_noctalia

	log "done"
	log "reboot, then use GDM for GNOME or the Niri session"
}

main "$@"
