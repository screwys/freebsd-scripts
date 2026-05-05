# freebsd-scripts

Personal FreeBSD desktop bootstrap.

```sh
fetch -o - https://raw.githubusercontent.com/screwys/freebsd-scripts/main/install.sh | sh
```

Guided installer:

```sh
fetch -o - https://raw.githubusercontent.com/screwys/freebsd-scripts/main/install.sh | sh -s -- --bsdinstall-guided --user screwy
```

The guided installer requires an explicit disk choice before ZFS setup. Noctalia is best-effort on FreeBSD because packaged quickshell is not `noctalia-qs`.
