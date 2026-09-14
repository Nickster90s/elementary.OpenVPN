install_data(
    '@0@.gschema.xml'.format(app_id),
    install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data(
    '@0@.desktop'.format(app_id),
    install_dir: get_option('datadir') / 'applications'
)

# Application icon. Generated from icons/openvpn_logo.png by tools/make-icons.py.
foreach size : ['16', '24', '32', '48', '64', '128', '256']
    install_data(
        'icons' / size + '.png',
        rename: '@0@.png'.format(app_id),
        install_dir: get_option('datadir') / 'icons' / 'hicolor' / '@0@x@0@'.format(size) / 'apps'
    )
endforeach

# Panel icon. Symbolic, so Wingpanel recolours it with the panel foreground.
install_data(
    'icons' / 'openvpn3-symbolic.svg',
    install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'symbolic' / 'apps'
)
