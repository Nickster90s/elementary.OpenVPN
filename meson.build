project(
    'io.github.nick.openvpn3gui',
    ['c', 'vala'],
    version: '1.0.0',
    license: 'GPL-3.0-or-later',
    meson_version: '>= 0.59.0',
    default_options: ['warning_level=1']
)

gnome = import('gnome')

app_id = meson.project_name()

add_project_arguments(
    '-DGETTEXT_PACKAGE="@0@"'.format(app_id),
    '-DAPP_VERSION="@0@"'.format(meson.project_version()),
    language: 'c'
)

glib_dep      = dependency('glib-2.0', version: '>= 2.64')
gobject_dep   = dependency('gobject-2.0')
gio_dep       = dependency('gio-2.0')
gtk_dep       = dependency('gtk+-3.0', version: '>= 3.24')
granite_dep   = dependency('granite', version: '>= 6.0')
secret_dep    = dependency('libsecret-1')
wingpanel_dep = dependency('wingpanel')

# Shared between the app and the panel indicator. Vala compiles fast enough
# that building the sources twice is cheaper than maintaining a vapi.
core_sources = files(
    'src/core/Ovpn3.vala',
    'src/core/ProfileStore.vala',
    'src/core/VpnController.vala',
)

# Needed by both front ends, so it cannot live in either one.
shared_sources = files(
    'src/shared/InputDialog.vala',
)

common_deps = [glib_dep, gobject_dep, gio_dep, gtk_dep, granite_dep, secret_dep]

executable(
    app_id,
    core_sources,
    shared_sources,
    files(
        'src/app/Application.vala',
        'src/app/MainWindow.vala',
        'src/app/ProfileRow.vala',
        'src/app/Dialogs.vala',
    ),
    dependencies: common_deps,
    install: true
)

shared_module(
    'openvpn3',
    core_sources,
    shared_sources,
    files('src/indicator/Indicator.vala'),
    dependencies: common_deps + [wingpanel_dep],
    install: true,
    install_dir: wingpanel_dep.get_variable(pkgconfig: 'indicatorsdir')
)

# Development-only driver for the connection logic; never installed.
executable(
    'connect-test',
    core_sources,
    files('src/core/TestHarness.vala'),
    dependencies: common_deps,
    install: false,
    build_by_default: false
)

# Development-only harness for the indicator popover; never installed.
executable(
    'indicator-preview',
    core_sources,
    shared_sources,
    files('src/indicator/Indicator.vala', 'src/indicator/Preview.vala'),
    dependencies: common_deps + [wingpanel_dep],
    install: false,
    build_by_default: false
)

subdir('data')

gnome.post_install(
    glib_compile_schemas: true,
    gtk_update_icon_cache: true,
    update_desktop_database: true
)
