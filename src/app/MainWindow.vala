/*
 * MainWindow.vala — the profile list.
 */

namespace Ovpn3Gui {

    public class MainWindow : Gtk.ApplicationWindow {
        private VpnController controller;
        private Gtk.ListBox list;
        private Gtk.Stack stack;
        private Granite.Widgets.Toast toast;
        private HashTable<string, ProfileRow> rows;
        private Settings settings;

        private const Gtk.TargetEntry[] DND_TARGETS = {
            { "text/uri-list", 0, 0 }
        };

        public MainWindow (Gtk.Application app) {
            GLib.Object (application: app);
        }

        construct {
            rows = new HashTable<string, ProfileRow> (str_hash, str_equal);
            settings = ProfileStore.root;

            try {
                controller = VpnController.get_default ();
            } catch (GLib.Error e) {
                build_service_error (e.message);
                return;
            }

            if (!controller.backend_installed ()) {
                build_missing_backend ();
                return;
            }

            build_ui ();
            wire_controller ();
            reload ();
        }

        /* ------------------------------------------------------------------ */
        /* Construction                                                        */
        /* ------------------------------------------------------------------ */

        private void build_service_error (string message) {
            var alert = new Granite.Widgets.AlertView (
                _("The OpenVPN 3 service is unavailable"),
                _("Check that openvpn3 is installed and that the system D-Bus services are running.\n\n%s").printf (message),
                "dialog-error"
            );
            alert.show_all ();

            var header = new Gtk.HeaderBar () { show_close_button = true, title = _("OpenVPN 3") };
            header.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);
            set_titlebar (header);

            add (alert);
            default_width = 520;
            default_height = 400;
            show_all ();
        }

        /*
         * Without openvpn3 there is nothing to manage. Saying so here beats
         * looking healthy and then failing on the first import.
         */
        private void build_missing_backend () {
            var alert = new Granite.Widgets.AlertView (
                _("OpenVPN 3 Is Not Installed"),
                _("This app is a front end for the OpenVPN 3 Linux client, which does not appear to be installed.\n\nInstall the openvpn3-client package, then reopen this window."),
                "dialog-error"
            );
            alert.show_all ();

            var header = new Gtk.HeaderBar () { show_close_button = true, title = _("OpenVPN 3") };
            header.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);
            set_titlebar (header);

            add (alert);
            default_width = 520;
            default_height = 400;
            show_all ();
        }

        private void build_ui () {
            var import_button = new Gtk.Button.from_icon_name ("document-import-symbolic", Gtk.IconSize.LARGE_TOOLBAR) {
                tooltip_text = _("Import an OpenVPN profile…")
            };
            import_button.clicked.connect (choose_file);

            var header = new Gtk.HeaderBar () {
                show_close_button = true,
                title = _("OpenVPN 3")
            };
            header.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);
            header.pack_start (import_button);
            set_titlebar (header);

            list = new Gtk.ListBox () {
                selection_mode = Gtk.SelectionMode.NONE,
                activate_on_single_click = false
            };
            list.set_header_func (add_separator);

            var scrolled = new Gtk.ScrolledWindow (null, null) {
                hexpand = true,
                vexpand = true,
                hscrollbar_policy = Gtk.PolicyType.NEVER
            };
            scrolled.add (list);

            var empty = new Granite.Widgets.AlertView (
                _("No VPN Profiles"),
                _("Drag an .ovpn file onto this window, or use the import button to add one."),
                "network-vpn"
            );

            stack = new Gtk.Stack ();
            stack.add_named (empty, "empty");
            stack.add_named (scrolled, "list");

            toast = new Granite.Widgets.Toast ("");

            var overlay = new Gtk.Overlay ();
            overlay.add (stack);
            overlay.add_overlay (toast);

            add (overlay);

            default_width = settings.get_int ("window-width");
            default_height = settings.get_int ("window-height");

            Gtk.drag_dest_set (this, Gtk.DestDefaults.ALL, DND_TARGETS, Gdk.DragAction.COPY);
            drag_data_received.connect (on_drag_data_received);

            delete_event.connect (() => {
                int width, height;
                get_size (out width, out height);
                settings.set_int ("window-width", width);
                settings.set_int ("window-height", height);
                return false;
            });

            show_all ();
        }

        private static void add_separator (Gtk.ListBoxRow row, Gtk.ListBoxRow? before) {
            if (before != null && row.get_header () == null) {
                row.set_header (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
            }
        }

        private void wire_controller () {
            controller.profiles_changed.connect (reload);

            controller.state_changed.connect ((config_path, state, message) => {
                var row = rows.lookup (config_path);
                if (row != null) {
                    row.update_state (state, message, subtitle_for (config_path, state));
                }
            });

            controller.error_occurred.connect ((config_path, message) => {
                toast.title = message;
                toast.send_notification ();
            });

            controller.input_requested.connect ((config_path, profile_name, field, label, masked) => {
                return InputDialog.ask (this, profile_name, label, masked);
            });
        }

        /* ------------------------------------------------------------------ */
        /* Profile list                                                        */
        /* ------------------------------------------------------------------ */

        private string subtitle_for (string config_path, ConnState state) {
            if (state == ConnState.CONNECTED) {
                int64 bytes_in, bytes_out;
                controller.get_transfer (config_path, out bytes_in, out bytes_out);
                if (bytes_in > 0 || bytes_out > 0) {
                    return "↓ %s  ↑ %s".printf (format_size ((uint64) bytes_in), format_size ((uint64) bytes_out));
                }
            }
            return "";
        }

        public void reload () {
            foreach (var child in list.get_children ()) {
                list.remove (child);
            }
            rows.remove_all ();

            unowned List<Profile> profiles = controller.list_profiles ();
            var default_path = controller.default_profile_path ();

            foreach (var profile in profiles) {
                var row = new ProfileRow (profile.config_path, profile.name);
                var path = profile.config_path;

                row.toggled.connect ((active) => {
                    controller.toggle_profile.begin (path, active);
                });

                row.default_toggled.connect ((active) => {
                    ProfileStore.default_profile = active ? path : "";
                    refresh_default_markers ();
                });

                row.edit_requested.connect (() => edit_profile (path));
                row.options_requested.connect (() => edit_options (path));
                row.rename_requested.connect (() => rename_profile (path));
                row.remove_requested.connect (() => confirm_remove (path));

                var state = controller.state_for (path);
                row.update_state (state, controller.message_for (path), subtitle_for (path, state));
                row.set_is_default (path == default_path);

                rows.insert (path, row);
                list.add (row);
            }

            list.show_all ();
            stack.visible_child_name = profiles.length () > 0 ? "list" : "empty";
        }

        private void refresh_default_markers () {
            var default_path = controller.default_profile_path ();
            foreach (var path in rows.get_keys_as_array ()) {
                var row = rows.lookup (path);
                if (row != null) {
                    row.set_is_default (path == default_path);
                }
            }
        }

        /* ------------------------------------------------------------------ */
        /* Importing                                                           */
        /* ------------------------------------------------------------------ */

        private void choose_file () {
            var chooser = new Gtk.FileChooserNative (
                _("Import OpenVPN Profile"), this, Gtk.FileChooserAction.OPEN,
                _("Import"), _("Cancel")
            );
            chooser.select_multiple = true;

            var filter = new Gtk.FileFilter ();
            filter.set_filter_name (_("OpenVPN profiles"));
            filter.add_pattern ("*.ovpn");
            filter.add_pattern ("*.conf");
            chooser.add_filter (filter);

            var all = new Gtk.FileFilter ();
            all.set_filter_name (_("All files"));
            all.add_pattern ("*");
            chooser.add_filter (all);

            if (chooser.run () == Gtk.ResponseType.ACCEPT) {
                File[] files = {};
                foreach (var uri in chooser.get_uris ()) {
                    files += File.new_for_uri (uri);
                }
                import_files (files);
            }
            chooser.destroy ();
        }

        private void on_drag_data_received (Gdk.DragContext ctx, int x, int y,
                                            Gtk.SelectionData data, uint info, uint time) {
            File[] files = {};
            foreach (var uri in data.get_uris ()) {
                files += File.new_for_uri (uri);
            }
            Gtk.drag_finish (ctx, files.length > 0, false, time);

            if (files.length > 0) {
                import_files (files);
            }
        }

        public void import_files (File[] files) {
            string? last_path = null;
            int imported = 0;

            foreach (var file in files) {
                try {
                    last_path = controller.import_file (file);
                    imported++;
                } catch (GLib.Error e) {
                    toast.title = _("Could not import %s: %s").printf (file.get_basename (), e.message);
                    toast.send_notification ();
                }
            }

            reload ();

            /* A freshly imported profile almost always needs credentials. */
            if (imported == 1 && last_path != null) {
                edit_profile (last_path);
            } else if (imported > 1) {
                toast.title = _("Imported %d profiles").printf (imported);
                toast.send_notification ();
            }
        }

        /* ------------------------------------------------------------------ */
        /* Profile actions                                                     */
        /* ------------------------------------------------------------------ */

        private void edit_profile (string config_path) {
            var name = controller.configs.get_config (config_path).profile_name;
            var dialog = new CredentialsDialog (this, config_path, name);
            dialog.show_all ();

            dialog.load_password.begin ((obj, res) => {
                dialog.load_password.end (res);
            });

            dialog.response.connect ((response_id) => {
                if (response_id == Gtk.ResponseType.ACCEPT) {
                    dialog.apply.begin ((obj, res) => {
                        try {
                            dialog.apply.end (res);
                        } catch (GLib.Error e) {
                            toast.title = _("Could not save: %s").printf (e.message);
                            toast.send_notification ();
                        }
                        reload ();
                        dialog.destroy ();
                    });
                } else {
                    dialog.destroy ();
                }
            });
        }

        private void edit_options (string config_path) {
            var name = controller.configs.get_config (config_path).profile_name;
            var dialog = new ConnectionOptionsDialog (this, config_path, name);
            dialog.load ();
            dialog.show_all ();

            dialog.response.connect ((response_id) => {
                if (response_id == Gtk.ResponseType.ACCEPT) {
                    try {
                        dialog.apply ();
                    } catch (GLib.Error e) {
                        toast.title = _("Could not save: %s").printf (e.message);
                        toast.send_notification ();
                    }
                }
                dialog.destroy ();
            });
        }

        private void rename_profile (string config_path) {
            var current = controller.configs.get_config (config_path).profile_name;
            var name = InputDialog.ask (this, current, _("New name for this profile:"), false);
            if (name == null || name.strip () == "") {
                return;
            }

            try {
                controller.rename_profile (config_path, name.strip ());
                reload ();
            } catch (GLib.Error e) {
                toast.title = _("Could not rename: %s").printf (e.message);
                toast.send_notification ();
            }
        }

        private void confirm_remove (string config_path) {
            var name = controller.configs.get_config (config_path).profile_name;

            var dialog = new Granite.MessageDialog.with_image_from_icon_name (
                _("Remove “%s”?").printf (name),
                _("The profile and its saved password will be deleted. This cannot be undone."),
                "dialog-warning",
                Gtk.ButtonsType.CANCEL
            ) {
                transient_for = this,
                modal = true
            };

            var remove_button = dialog.add_button (_("Remove Profile"), Gtk.ResponseType.ACCEPT);
            remove_button.get_style_context ().add_class (Gtk.STYLE_CLASS_DESTRUCTIVE_ACTION);

            if (dialog.run () == Gtk.ResponseType.ACCEPT) {
                try {
                    controller.remove_profile (config_path);
                    reload ();
                } catch (GLib.Error e) {
                    toast.title = _("Could not remove: %s").printf (e.message);
                    toast.send_notification ();
                }
            }
            dialog.destroy ();
        }
    }
}
