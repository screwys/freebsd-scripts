# freebsd-scripts

FreeBSD installation script for Niri + Noctalia v5 and GNOME, plus browsers and other core utils.

Run as root. Replace `user_name` with the account to create or configure. New accounts prompt for a password. Without `--user`, the installer uses the first existing desktop user or asks for a username.

```sh
fetch -o - https://raw.githubusercontent.com/screwys/freebsd-scripts/main/install.sh | sh -s -- --user user_name
```

Guided installer:

```sh
fetch -o - https://raw.githubusercontent.com/screwys/freebsd-scripts/main/install.sh | sh -s -- --guided --user user_name
```

The normal path installs all component groups. You can choose what to install with a simple TUI.

```sh
fetch https://raw.githubusercontent.com/screwys/freebsd-scripts/main/install.sh
sh install.sh --tui --user user_name
```

Installs and configures doas for the desktop user, plus fish, Starship, Yazi, Rust/Go and other dev tools, Neovim with LazyVim, GNOME/GDM, Niri, Xwayland Satellite, native Noctalia v5, Ghostty, Firefox, LibreWolf, Chromium, Zed, Vesktop, GStreamer and media apps, KDE utilities, fcitx5 Japanese input, screenshot/clipboard tools, fonts, portals, GPU firmware, and desktop hardening defaults.

Noctalia, Signal Desktop, and Vesktop build from source.
