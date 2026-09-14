/*
 * ProfileRow.vala — one VPN profile in the main list.
 */

namespace Ovpn3Gui {

    public class ProfileRow : Gtk.ListBoxRow {
        public string config_path { get; construct; }
        public string profile_name { get; set; }

        /* The switch was flipped by the user. */
        public signal void toggled (bool active);
        /* The star was clicked; true when this profile should become default. */
        public signal void default_toggled (bool active);
        public signal void edit_requested ();
        public signal void options_requested ();
        public signal void rename_requested ();
        public signal void remove_requested ();

        private Gtk.Image icon;
        private Gtk.Label title_label;
        private Gtk.Label subtitle_label;
        private Gtk.Switch power;
        private Gtk.ToggleButton star;
        private Gtk.Image star_image;
        private Gtk.Spinner spinner;

        /* Guards against re-emitting while we update the widgets ourselves. */
        private bool syncing = false;

        public ProfileRow (string config_path, string name) {
            GLib.Object (config_path: config_path);
            profile_name = name;
            title_label.label = name;
        }

        construct {
            icon = new Gtk.Image.from_icon_name ("network-vpn-disconnected-symbolic", Gtk.IconSize.DND) {
                pixel_size = 32,
                valign = Gtk.Align.CENTER
            };

            title_label = new Gtk.Label ("") {
                halign = Gtk.Align.START,
                ellipsize = Pango.EllipsizeMode.END,
                xalign = 0
            };
            title_label.get_style_context ().add_class (Granite.STYLE_CLASS_H3_LABEL);

            subtitle_label = new Gtk.Label (_("Not connected")) {
                halign = Gtk.Align.START,
                ellipsize = Pango.EllipsizeMode.END,
                xalign = 0
            };
            subtitle_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
            subtitle_label.get_style_context ().add_class (Granite.STYLE_CLASS_SMALL_LABEL);

            spinner = new Gtk.Spinner () {
                valign = Gtk.Align.CENTER,
                no_show_all = true,
                visible = false
            };

            star_image = new Gtk.Image.from_icon_name ("non-starred-symbolic", Gtk.IconSize.BUTTON);
            star = new Gtk.ToggleButton () {
                image = star_image,
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Use this profile for the panel switch")
            };
            star.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);

            power = new Gtk.Switch () {
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Connect or disconnect this profile")
            };

            var menu_button = new Gtk.MenuButton () {
                image = new Gtk.Image.from_icon_name ("view-more-symbolic", Gtk.IconSize.BUTTON),
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Profile options")
            };
            menu_button.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);
            menu_button.popover = build_menu ();

            var text_grid = new Gtk.Grid () {
                orientation = Gtk.Orientation.VERTICAL,
                valign = Gtk.Align.CENTER,
                hexpand = true
            };
            text_grid.add (title_label);
            text_grid.add (subtitle_label);

            var grid = new Gtk.Grid () {
                column_spacing = 12,
                margin_top = 6,
                margin_bottom = 6,
                margin_start = 12,
                margin_end = 12
            };
            grid.add (icon);
            grid.add (text_grid);
            grid.add (spinner);
            grid.add (star);
            grid.add (power);
            grid.add (menu_button);

            add (grid);
            activatable = false;

            power.notify["active"].connect (() => {
                if (!syncing) {
                    toggled (power.active);
                }
            });

            star.toggled.connect (() => {
                if (!syncing) {
                    default_toggled (star.active);
                }
            });

            notify["profile-name"].connect (() => {
                title_label.label = profile_name;
            });
        }

        private Gtk.Popover build_menu () {
            var edit = new Gtk.ModelButton () { text = _("Account & Password…") };
            var options = new Gtk.ModelButton () { text = _("Connection Options…") };
            var rename = new Gtk.ModelButton () { text = _("Rename…") };
            var remove = new Gtk.ModelButton () { text = _("Remove Profile…") };

            edit.clicked.connect (() => edit_requested ());
            options.clicked.connect (() => options_requested ());
            rename.clicked.connect (() => rename_requested ());
            remove.clicked.connect (() => remove_requested ());

            var box = new Gtk.Grid () {
                orientation = Gtk.Orientation.VERTICAL,
                margin_top = 3,
                margin_bottom = 3
            };
            box.add (edit);
            box.add (options);
            box.add (rename);
            box.add (new Gtk.Separator (Gtk.Orientation.HORIZONTAL) { margin_top = 3, margin_bottom = 3 });
            box.add (remove);
            box.show_all ();

            var popover = new Gtk.Popover (null);
            popover.add (box);
            return popover;
        }

        public void update_state (ConnState state, string message, string subtitle_extra) {
            syncing = true;

            icon.icon_name = state.icon_name ();
            power.active = state.is_up () || state.is_busy ();
            power.sensitive = !state.is_busy ();

            if (state.is_busy ()) {
                spinner.visible = true;
                spinner.start ();
            } else {
                spinner.stop ();
                spinner.visible = false;
            }

            var text = state.to_label ();
            if ((state == ConnState.FAILED || state == ConnState.AUTH_FAILED) && message != "") {
                text = "%s — %s".printf (text, message);
            } else if (state == ConnState.CONNECTED && subtitle_extra != "") {
                text = "%s · %s".printf (text, subtitle_extra);
            } else if (!state.is_up () && !state.is_busy () && subtitle_extra != "") {
                text = subtitle_extra;
            }
            subtitle_label.label = text;

            var ctx = subtitle_label.get_style_context ();
            if (state == ConnState.FAILED || state == ConnState.AUTH_FAILED) {
                ctx.add_class (Gtk.STYLE_CLASS_ERROR);
            } else {
                ctx.remove_class (Gtk.STYLE_CLASS_ERROR);
            }

            syncing = false;
        }

        public void set_is_default (bool is_default) {
            syncing = true;
            star.active = is_default;
            star_image.icon_name = is_default ? "starred-symbolic" : "non-starred-symbolic";
            star.tooltip_text = is_default
                ? _("This profile is controlled by the panel switch")
                : _("Use this profile for the panel switch");
            syncing = false;
        }
    }
}
