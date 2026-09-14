# OpenVPN 3 for elementary OS

A GTK3/Granite profile manager and a Wingpanel indicator for the
[OpenVPN 3 Linux](https://github.com/OpenVPN/openvpn3-linux) client.

* Drag an `.ovpn` file onto the window to import it (or use the import button,
  or open the file from Files).
* Set the user name and password per profile. Passwords go into the login
  keyring via libsecret, never to disk.
* Pick one profile as the **default** with the star button.
* Switch any profile on or off from the app.
* Switch the default profile on or off from the panel.
* Relax OpenVPN 3's defaults per profile under **Connection Options**, which an
  OpenVPN 2 profile usually needs (see below).

## Layout

```
icons/           Source artwork (the two files as supplied)
tools/           make-icons.py, regenerates data/icons from icons/
src/shared/      InputDialog, used by both front ends
src/core/        Shared, GTK-free core
  Ovpn3.vala         D-Bus bindings for net.openvpn.v3.{configuration,sessions}
  ProfileStore.vala  Per-profile settings (GSettings) and passwords (libsecret)
  VpnController.vala Connection state machine and credential hand-off
  TestHarness.vala   Development-only CLI driver (not installed)
src/app/         The profile manager window
src/indicator/   The Wingpanel plugin
data/            GSettings schema, desktop entry, generated icons
```

## Icons

`data/icons/` is generated from the artwork in `icons/` — rerun
`python3 tools/make-icons.py` (needs only Pillow) after changing either source
file.

The application icon is the OpenVPN mark lifted off its white square: the white
is un-matted back to alpha and replaced with a white disc, which keeps the
artwork's own colours while staying legible on elementary's dark app menu and
dock.

The panel icon has to be a vector, because GTK only recolours symbolic icons to
the panel's foreground colour when they are SVG. It is traced from the logo's
solid shapes rather than from the outline artwork, which blurs into itself at
the 16px panel size. There is a single mark instead of one icon per state, so
the panel shows state by weight: solid when connected, faded while connecting,
faint when down, and tinted with the theme's error colour after a failure.

The core is compiled into both the app and the indicator, so the two always
agree about state without needing any IPC of their own: profile settings live
in GSettings, and connection state is read straight from the OpenVPN 3
services.

## Build and install

Dependencies:

```sh
sudo apt install -y build-essential valac meson ninja-build \
    libwingpanel-dev libgranite-dev libgtk-3-dev libsecret-1-dev libglib2.0-dev gettext
```

Build and install:

```sh
meson setup build --prefix=/usr
ninja -C build
sudo ninja -C build install
```

The indicator is a Wingpanel plugin, so the panel has to be restarted once
after installing:

```sh
killall io.elementary.wingpanel
```

Wingpanel is respawned automatically by the session.

To uninstall:

```sh
sudo ninja -C build uninstall
```

## Profiles written for OpenVPN 2

OpenVPN 3 is stricter than OpenVPN 2 and will refuse a connection rather than
quietly downgrade. A profile carrying `comp-lzo`, `cipher AES-256-CBC` or
`auth SHA1` typically fails until its defaults are relaxed, because compression
is off by default (it can leak tunnel contents — the VORACLE attack) and the
older algorithms are not enabled.

**Connection Options** in a profile's menu writes these as OpenVPN 3 overrides,
stored by the configuration manager against that profile alone:

| Setting          | Override                   |
| ---------------- | -------------------------- |
| Compression      | `allow-compression`        |
| Older algorithms | `enable-legacy-algorithms` |
| Certificates     | `tls-cert-profile`         |
| Minimum TLS      | `tls-version-min`          |

*Use settings for an OpenVPN 2 profile* fills in the combination such profiles
normally need. The same thing can be done with
`openvpn3 config-manage --config NAME --allow-compression asym`, and
`--show` lists whatever is currently set.

## How it works

Profiles are imported into the OpenVPN 3 configuration manager as *persistent*
profiles, so they survive a reboot and are visible to `openvpn3 configs-list`
as well.

Connecting follows the same handshake the `openvpn3` command line tool uses:

1. `NewTunnel` on the session manager creates a session.
2. `Ready` is called; it keeps failing while the backend still wants input.
3. Every queued question (`UserInputQueueFetch`) is answered —
   `username` from GSettings, `password` and `pk_passphrase` from the keyring,
   and anything else (a dynamic challenge, say) by asking the user.
4. `Connect` starts the tunnel, and the first seconds are watched so an
   immediate failure is reported with the backend's own message instead of
   silently falling back to "not connected".

The services exit when idle, so state is polled only while a session actually
exists; otherwise the code waits for `SessionManagerEvent`.

## Development

Two extra targets are built on demand and never installed:

```sh
ninja -C build indicator-preview   # renders the panel popover in a window
ninja -C build connect-test        # drives a connection from the terminal

GSETTINGS_SCHEMA_DIR=$PWD/build/schemas ./build/indicator-preview
G_MESSAGES_DEBUG=all ./build/connect-test "Profile Name" username password
```

Before installing, compile the schema locally so the binaries can find it:

```sh
mkdir -p build/schemas && cp data/*.gschema.xml build/schemas/
glib-compile-schemas build/schemas
```
