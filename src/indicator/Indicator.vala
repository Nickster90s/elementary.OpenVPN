/*
 * Indicator.vala — the Wingpanel plugin.
 *
 * The panel shows the state of the default profile and offers a switch to
 * bring it up or down. The other profiles are listed underneath so a tunnel
 * started elsewhere can still be turned off from here.
 */

namespace Ovpn3Gui {

    /* Shipped with the app; recoloured by Wingpanel like every other indicator. */
    private const string PANEL_ICON = "openvpn3-symbolic";

    /*
     * One line in the popover: state icon, profile name, state text, switch.
     *
     * Granite.SwitchModelButton would be the obvious choice, but its
     * description label never renders in Granite 6, so the row is assembled
     * by hand.
     */
    private class ProfileMenuRow : Gtk.Grid {
        public string config_path { get; construct; }
        public Gtk.Switch toggle { get; private set; }

        public signal void switched (bool active);

        private Gtk.Image icon;
        private Gtk.Label name_label;
        private Gtk.Label state_label;
        private bool syncing = false;
        private bool is_default = false;

        public ProfileMenuRow (string config_path, string name, bool is_default) {
            GLib.Object (config_path: config_path);
            this.is_default = is_default;
            name_label.label = name;
        }

        construct {
            icon = new Gtk.Image.from_icon_name ("network-vpn-disconnected-symbolic", Gtk.IconSize.MENU) {
                valign = Gtk.Align.CENTER
            };

            name_label = new Gtk.Label ("") {
                halign = Gtk.Align.START,
                ellipsize = Pango.EllipsizeMode.END,
                hexpand = true,
                xalign = 0
            };

            state_label = new Gtk.Label ("") {
                halign = Gtk.Align.START,
                ellipsize = Pango.EllipsizeMode.END,
                xalign = 0
            };
            state_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
            state_label.get_style_context ().add_class (Granite.STYLE_CLASS_SMALL_LABEL);

            toggle = new Gtk.Switch () {
                valign = Gtk.Align.CENTER
            };

            var text = new Gtk.Grid () {
                orientation = Gtk.Orientation.VERTICAL,
                valign = Gtk.Align.CENTER,
                hexpand = true
            };
            text.add (name_label);
            text.add (state_label);

            column_spacing = 8;
            margin_start = 12;
            margin_end = 12;
            margin_top = 4;
            margin_bottom = 4;

            add (icon);
            add (text);
            add (toggle);

            toggle.notify["active"].connect (() => {
                if (!syncing) {
                    switched (toggle.active);
                }
            });
        }

        public void sync (ConnState state, string message) {
            syncing = true;

            icon.icon_name = state.icon_name ();
            toggle.active = state.is_up () || state.is_busy ();
            toggle.sensitive = !state.is_busy ();

            var text = state.to_label ();
            state_label.label = is_default
                ? "%s · %s".printf (_("Default"), text)
                : text;

            /* The reason a tunnel failed is usually too long for the row. */
            tooltip_text = message != "" ? message : null;

            syncing = false;
        }
    }

    public class Indicator : Wingpanel.Indicator {
        private Gtk.Image? display_icon = null;
        private Gtk.Grid? popover_grid = null;
        private Gtk.Grid? profile_grid = null;
        private Gtk.Label? empty_label = null;

        private VpnController? controller = null;
        private HashTable<string, ProfileMenuRow> rows;
        private bool popover_open = false;

        public Indicator () {
            GLib.Object (code_name: "openvpn3");
        }

        construct {
            rows = new HashTable<string, ProfileMenuRow> (str_hash, str_equal);

            try {
                controller = VpnController.get_default ();
            } catch (GLib.Error e) {
                warning ("OpenVPN 3 indicator: %s", e.message);
                visible = false;
                return;
            }

            /*
             * Without this the panel switch would be dead for any profile
             * whose password is not in the keyring: the backend asks, nobody
             * answers, and the attempt is abandoned.
             */
            controller.input_requested.connect ((config_path, name, field, label, masked) => {
                return InputDialog.ask (null, name, label, masked);
            });

            controller.state_changed.connect (() => {
                update_display ();
                /* While the popover is closed its rows are rebuilt on open. */
                if (popover_open) {
                    sync_rows ();
                }
            });

            controller.profiles_changed.connect (() => {
                rebuild_profiles ();
                update_display ();
            });

            ProfileStore.root.changed["default-profile"].connect (() => {
                rebuild_profiles ();
                update_display ();
            });

            update_display ();
        }

        /* ------------------------------------------------------------------ */
        /* Panel icon                                                          */
        /* ------------------------------------------------------------------ */

        public override Gtk.Widget get_display_widget () {
            if (display_icon == null) {
                display_icon = new Gtk.Image.from_icon_name (PANEL_ICON, Gtk.IconSize.MENU);
                update_display ();
            }
            return display_icon;
        }

        /* The panel reflects whichever profile is in the most "active" state. */
        private ConnState overall_state () {
            if (controller == null) {
                return ConnState.DISCONNECTED;
            }

            var best = ConnState.DISCONNECTED;
            foreach (var profile in controller.list_profiles ()) {
                var state = controller.state_for (profile.config_path);
                if (state == ConnState.CONNECTED) {
                    return ConnState.CONNECTED;
                }
                if (state.is_busy () || state == ConnState.PAUSED) {
                    best = state;
                }
            }
            return best;
        }

        private void update_display () {
            if (controller == null) {
                visible = false;
                return;
            }

            visible = true;
            if (display_icon == null) {
                return;
            }

            var state = overall_state ();
            display_icon.tooltip_text = tooltip_for (state);

            /*
             * There is a single mark rather than one icon per state, so the
             * panel shows the state by weight instead: solid when the tunnel
             * is up, faded when it is not, and tinted on a failure.
             */
            switch (state) {
                case ConnState.CONNECTED:
                    display_icon.opacity = 1.0;
                    break;
                case ConnState.CONNECTING:
                case ConnState.DISCONNECTING:
                case ConnState.PAUSED:
                    display_icon.opacity = 0.75;
                    break;
                default:
                    display_icon.opacity = 0.45;
                    break;
            }

            /* A live tunnel elsewhere outranks a stale failure. */
            var ctx = display_icon.get_style_context ();
            if (state != ConnState.CONNECTED && state != ConnState.CONNECTING && failed_state ()) {
                display_icon.opacity = 1.0;
                ctx.add_class (Gtk.STYLE_CLASS_ERROR);
            } else {
                ctx.remove_class (Gtk.STYLE_CLASS_ERROR);
            }
        }

        /* True when any profile ended in a failure the user has not cleared. */
        private bool failed_state () {
            foreach (var profile in controller.list_profiles ()) {
                var state = controller.state_for (profile.config_path);
                if (state == ConnState.FAILED || state == ConnState.AUTH_FAILED) {
                    return true;
                }
            }
            return false;
        }

        private string tooltip_for (ConnState state) {
            var default_path = controller.default_profile_path ();
            if (default_path == null) {
                return state == ConnState.CONNECTED ? _("VPN connected") : _("No default VPN profile");
            }

            var name = controller.configs.get_config (default_path).profile_name;
            var default_state = controller.state_for (default_path);

            if (default_state == ConnState.DISCONNECTED && state == ConnState.CONNECTED) {
                return _("Another VPN profile is connected");
            }
            return "%s — %s".printf (name, default_state.to_label ());
        }

        /* ------------------------------------------------------------------ */
        /* Popover                                                             */
        /* ------------------------------------------------------------------ */

        public override Gtk.Widget? get_widget () {
            if (popover_grid != null) {
                return popover_grid;
            }

            empty_label = new Gtk.Label (_("No VPN profiles yet")) {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12,
                margin_top = 6,
                margin_bottom = 6,
                xalign = 0,
                no_show_all = true
            };
            empty_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);

            profile_grid = new Gtk.Grid () {
                orientation = Gtk.Orientation.VERTICAL
            };

            var settings_button = new Gtk.ModelButton () {
                text = _("VPN Settings…")
            };
            settings_button.clicked.connect (() => {
                close ();
                launch_app ();
            });

            popover_grid = new Gtk.Grid () {
                orientation = Gtk.Orientation.VERTICAL,
                margin_top = 3,
                margin_bottom = 3
            };
            popover_grid.add (empty_label);
            popover_grid.add (profile_grid);
            popover_grid.add (new Gtk.Separator (Gtk.Orientation.HORIZONTAL) {
                margin_top = 3,
                margin_bottom = 3
            });
            popover_grid.add (settings_button);
            popover_grid.show_all ();

            rebuild_profiles ();
            update_display ();

            return popover_grid;
        }

        private void rebuild_profiles () {
            if (profile_grid == null) {
                return;
            }

            foreach (var child in profile_grid.get_children ()) {
                profile_grid.remove (child);
            }
            rows.remove_all ();

            var default_path = controller.default_profile_path ();
            unowned List<Profile> profiles = controller.list_profiles ();
            uint count = 0;

            /* The profile the panel switch controls always comes first. */
            foreach (var profile in profiles) {
                if (profile.config_path == default_path) {
                    add_profile_row (profile, true);
                    count++;
                }
            }

            bool needs_separator = count > 0;
            foreach (var profile in profiles) {
                if (profile.config_path == default_path) {
                    continue;
                }
                if (needs_separator) {
                    profile_grid.add (new Gtk.Separator (Gtk.Orientation.HORIZONTAL) {
                        margin_top = 3,
                        margin_bottom = 3
                    });
                    needs_separator = false;
                }
                add_profile_row (profile, false);
                count++;
            }

            if (empty_label != null) {
                empty_label.visible = count == 0;
            }

            sync_rows ();
            profile_grid.show_all ();
        }

        private void add_profile_row (Profile profile, bool is_default) {
            var path = profile.config_path;
            var row = new ProfileMenuRow (path, profile.name, is_default);

            row.switched.connect ((active) => {
                controller.toggle_profile.begin (path, active);
            });

            rows.insert (path, row);
            profile_grid.add (row);
        }

        private void sync_rows () {
            foreach (var path in rows.get_keys_as_array ()) {
                var row = rows.lookup (path);
                if (row != null) {
                    row.sync (controller.state_for (path), controller.message_for (path));
                }
            }
        }

        private void launch_app () {
            var info = new DesktopAppInfo (APP_ID + ".desktop");
            if (info != null) {
                try {
                    info.launch (null, null);
                    return;
                } catch (GLib.Error e) {
                    warning ("Could not launch the settings app: %s", e.message);
                }
            }

            try {
                Process.spawn_command_line_async (APP_ID);
            } catch (SpawnError e) {
                warning ("Could not launch %s: %s", APP_ID, e.message);
            }
        }

        public override void opened () {
            popover_open = true;
            if (controller != null) {
                controller.refresh_states ();
            }
            rebuild_profiles ();
            update_display ();
        }

        public override void closed () {
            popover_open = false;
        }
    }
}

public Wingpanel.Indicator? get_indicator (Module module, Wingpanel.IndicatorManager.ServerType server_type) {
    if (server_type != Wingpanel.IndicatorManager.ServerType.SESSION) {
        return null;
    }

    debug ("Activating the OpenVPN 3 indicator");
    return new Ovpn3Gui.Indicator ();
}
