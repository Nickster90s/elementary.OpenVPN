/*
 * Dialogs.vala — credential editing and the live prompts the VPN backend can
 * raise while a tunnel is being established.
 */

namespace Ovpn3Gui {

    /*
     * Edits the user name and password stored for a profile. The password is
     * written to the login keyring, never to disk.
     */
    public class CredentialsDialog : Granite.Dialog {
        public string config_path { get; construct; }
        public string profile_name { get; construct; }

        /* Emitted once the credentials have been written away. */
        public signal void saved (string username);

        private Gtk.Entry name_entry;
        private Gtk.Entry username_entry;
        private Gtk.Entry password_entry;
        private bool password_loaded = false;
        private string original_password = "";

        public CredentialsDialog (Gtk.Window parent, string config_path, string profile_name) {
            GLib.Object (
                transient_for: parent,
                config_path: config_path,
                profile_name: profile_name,
                modal: true,
                resizable: false
            );
        }

        construct {
            name_entry = new Gtk.Entry () {
                text = profile_name,
                hexpand = true,
                activates_default = true
            };

            username_entry = new Gtk.Entry () {
                text = ProfileStore.get_username (config_path),
                hexpand = true,
                activates_default = true,
                placeholder_text = _("Required by most VPN servers")
            };

            password_entry = new Gtk.Entry () {
                visibility = false,
                hexpand = true,
                activates_default = true,
                secondary_icon_name = "view-conceal-symbolic",
                secondary_icon_tooltip_text = _("Show password"),
                placeholder_text = _("Leave empty to be asked each time")
            };

            password_entry.icon_press.connect ((position) => {
                if (position == Gtk.EntryIconPosition.SECONDARY) {
                    password_entry.visibility = !password_entry.visibility;
                    password_entry.secondary_icon_name = password_entry.visibility
                        ? "view-reveal-symbolic" : "view-conceal-symbolic";
                }
            });

            var header = new Granite.HeaderLabel (_("Profile"));

            var auth_header = new Granite.HeaderLabel (_("Authentication")) {
                margin_top = 12
            };

            var hint = new Gtk.Label (_("The password is stored in your login keyring.")) {
                halign = Gtk.Align.START,
                margin_top = 6,
                wrap = true,
                max_width_chars = 40,
                xalign = 0
            };
            hint.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
            hint.get_style_context ().add_class (Granite.STYLE_CLASS_SMALL_LABEL);

            var grid = new Gtk.Grid () {
                column_spacing = 12,
                row_spacing = 6,
                margin_start = 12,
                margin_end = 12,
                margin_bottom = 12
            };

            grid.attach (header, 0, 0, 2);
            grid.attach (label_for (_("Name:")), 0, 1);
            grid.attach (name_entry, 1, 1);
            grid.attach (auth_header, 0, 2, 2);
            grid.attach (label_for (_("User name:")), 0, 3);
            grid.attach (username_entry, 1, 3);
            grid.attach (label_for (_("Password:")), 0, 4);
            grid.attach (password_entry, 1, 4);
            grid.attach (hint, 1, 5);

            get_content_area ().add (grid);

            add_button (_("Cancel"), Gtk.ResponseType.CANCEL);
            var save_button = add_button (_("Save"), Gtk.ResponseType.ACCEPT);
            save_button.get_style_context ().add_class (Gtk.STYLE_CLASS_SUGGESTED_ACTION);
            set_default_response (Gtk.ResponseType.ACCEPT);

            width_request = 480;
        }

        private static Gtk.Label label_for (string text) {
            var label = new Gtk.Label (text) {
                halign = Gtk.Align.END,
                xalign = 1
            };
            label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
            return label;
        }

        /* Fills the password field from the keyring without blocking the UI. */
        public async void load_password () {
            try {
                var stored = yield SecretStore.lookup (config_path, "password");
                if (stored != null) {
                    original_password = stored;
                    /* Never clobber something the user typed while we waited. */
                    if (password_entry.text == "") {
                        password_entry.text = stored;
                    }
                }
            } catch (GLib.Error e) {
                warning ("Could not read the stored password: %s", e.message);
            }
            password_loaded = true;
        }

        public async void apply () throws GLib.Error {
            var new_name = name_entry.text.strip ();
            if (new_name != "" && new_name != profile_name) {
                VpnController.get_default ().rename_profile (config_path, new_name);
            }

            ProfileStore.set_username (config_path, username_entry.text.strip ());

            /* Do not touch the keyring if the field never got populated. */
            if (!password_loaded) {
                saved (username_entry.text.strip ());
                return;
            }

            var password = password_entry.text;
            if (password == original_password) {
                saved (username_entry.text.strip ());
                return;
            }

            if (password == "") {
                yield SecretStore.clear (config_path, "password");
            } else {
                yield SecretStore.store (config_path, new_name != "" ? new_name : profile_name,
                                         password, "password");
            }

            saved (username_entry.text.strip ());
        }
    }

    /*
     * OpenVPN 3 refuses compression and several older algorithms by default,
     * so a profile written for OpenVPN 2 often will not connect until those
     * defaults are relaxed for it. These are the per-profile overrides the
     * configuration manager keeps alongside the profile.
     */
    public class ConnectionOptionsDialog : Granite.Dialog {
        public string config_path { get; construct; }
        public string profile_name { get; construct; }

        private Gtk.ComboBoxText compression;
        private Gtk.Switch legacy_algorithms;
        private Gtk.ComboBoxText cert_profile;
        private Gtk.ComboBoxText tls_min;

        private const string OV_COMPRESSION = "allow-compression";
        private const string OV_LEGACY = "enable-legacy-algorithms";
        private const string OV_CERT_PROFILE = "tls-cert-profile";
        private const string OV_TLS_MIN = "tls-version-min";

        public ConnectionOptionsDialog (Gtk.Window parent, string config_path, string profile_name) {
            GLib.Object (
                transient_for: parent,
                config_path: config_path,
                profile_name: profile_name,
                modal: true,
                resizable: false
            );
        }

        construct {
            compression = new Gtk.ComboBoxText () { hexpand = true };
            compression.append ("no", _("Never"));
            compression.append ("asym", _("Only from the server"));
            compression.append ("yes", _("Allow"));
            compression.active_id = "no";

            legacy_algorithms = new Gtk.Switch () {
                halign = Gtk.Align.START,
                valign = Gtk.Align.CENTER
            };

            cert_profile = new Gtk.ComboBoxText () { hexpand = true };
            cert_profile.append ("preferred", _("Preferred"));
            cert_profile.append ("legacy", _("Legacy"));
            cert_profile.append ("suiteb", _("Suite B"));
            cert_profile.active_id = "preferred";

            tls_min = new Gtk.ComboBoxText () { hexpand = true };
            tls_min.append ("default", _("Profile default"));
            tls_min.append ("tls_1_0", "TLS 1.0");
            tls_min.append ("tls_1_1", "TLS 1.1");
            tls_min.append ("tls_1_2", "TLS 1.2");
            tls_min.append ("tls_1_3", "TLS 1.3");
            tls_min.active_id = "default";

            var hint = new Gtk.Label (
                _("Compression is off by default because it can leak the contents of a tunnel. Turn it on only if the server requires comp-lzo.")
            ) {
                halign = Gtk.Align.START,
                wrap = true,
                max_width_chars = 46,
                xalign = 0,
                margin_top = 3
            };
            hint.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
            hint.get_style_context ().add_class (Granite.STYLE_CLASS_SMALL_LABEL);

            var preset = new Gtk.Button.with_label (_("Use settings for an OpenVPN 2 profile")) {
                halign = Gtk.Align.START,
                margin_top = 6
            };
            preset.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);
            preset.clicked.connect (() => {
                compression.active_id = "asym";
                legacy_algorithms.active = true;
                cert_profile.active_id = "legacy";
                tls_min.active_id = "tls_1_0";
            });

            var grid = new Gtk.Grid () {
                column_spacing = 12,
                row_spacing = 6,
                margin_start = 12,
                margin_end = 12,
                margin_bottom = 12
            };

            grid.attach (new Granite.HeaderLabel (_("Compatibility")), 0, 0, 2);
            grid.attach (label_for (_("Compression:")), 0, 1);
            grid.attach (compression, 1, 1);
            grid.attach (label_for (_("Older algorithms:")), 0, 2);
            grid.attach (legacy_algorithms, 1, 2);
            grid.attach (label_for (_("Certificates:")), 0, 3);
            grid.attach (cert_profile, 1, 3);
            grid.attach (label_for (_("Minimum TLS:")), 0, 4);
            grid.attach (tls_min, 1, 4);
            grid.attach (hint, 1, 5);
            grid.attach (preset, 1, 6);

            get_content_area ().add (grid);

            add_button (_("Cancel"), Gtk.ResponseType.CANCEL);
            var save_button = add_button (_("Save"), Gtk.ResponseType.ACCEPT);
            save_button.get_style_context ().add_class (Gtk.STYLE_CLASS_SUGGESTED_ACTION);
            set_default_response (Gtk.ResponseType.ACCEPT);

            width_request = 460;
        }

        private static Gtk.Label label_for (string text) {
            var label = new Gtk.Label (text) {
                halign = Gtk.Align.END,
                xalign = 1
            };
            label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
            return label;
        }

        /* Reflects the overrides already stored on the profile. */
        public void load () {
            try {
                var config = VpnController.get_default ().configs.get_config (config_path);
                var current = config.overrides ();

                var v = Ovpn3.RemoteObject.dict_lookup (current, OV_COMPRESSION);
                if (v != null) {
                    compression.active_id = v.get_string ();
                }

                v = Ovpn3.RemoteObject.dict_lookup (current, OV_LEGACY);
                if (v != null) {
                    legacy_algorithms.active = v.get_boolean ();
                }

                v = Ovpn3.RemoteObject.dict_lookup (current, OV_CERT_PROFILE);
                if (v != null) {
                    cert_profile.active_id = v.get_string ();
                }

                v = Ovpn3.RemoteObject.dict_lookup (current, OV_TLS_MIN);
                if (v != null) {
                    tls_min.active_id = v.get_string ();
                }
            } catch (GLib.Error e) {
                warning ("Could not read connection options: %s", e.message);
            }
        }

        public void apply () throws GLib.Error {
            var config = VpnController.get_default ().configs.get_config (config_path);

            apply_string (config, OV_COMPRESSION, compression.active_id, "no");
            apply_string (config, OV_CERT_PROFILE, cert_profile.active_id, "preferred");
            apply_string (config, OV_TLS_MIN, tls_min.active_id, "default");

            if (legacy_algorithms.active) {
                config.set_override (OV_LEGACY, new Variant.boolean (true));
            } else {
                unset_quietly (config, OV_LEGACY);
            }
        }

        /* A value equal to the OpenVPN 3 default is stored as no override. */
        private static void apply_string (Ovpn3.Config config, string name,
                                          string? value, string default_value) throws GLib.Error {
            if (value == null || value == default_value) {
                unset_quietly (config, name);
            } else {
                config.set_override (name, new Variant.string (value));
            }
        }

        private static void unset_quietly (Ovpn3.Config config, string name) {
            try {
                config.unset_override (name);
            } catch (GLib.Error e) {
                /* Unsetting something that was never set is not an error here. */
            }
        }
    }
}
