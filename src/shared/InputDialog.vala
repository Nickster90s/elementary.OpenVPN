/*
 * InputDialog.vala — the prompt shown when the VPN backend asks for something
 * the keyring cannot answer.
 *
 * Shared by the app and the panel indicator: without it, flipping the panel
 * switch on a profile with no saved password would fail with no way to supply
 * one.
 */

namespace Ovpn3Gui {

    /*
     * A blocking one-shot prompt, used for anything the keyring cannot answer
     * such as a dynamic challenge code.
     */
    public class InputDialog : Granite.Dialog {
        private Gtk.Entry entry;

        private InputDialog (Gtk.Window? parent, string profile_name, string prompt, bool masked) {
            GLib.Object (transient_for: parent, modal: true, resizable: false);

            var heading = new Gtk.Label (profile_name) {
                halign = Gtk.Align.START,
                xalign = 0
            };
            heading.get_style_context ().add_class (Granite.STYLE_CLASS_H3_LABEL);

            var label = new Gtk.Label (prompt) {
                halign = Gtk.Align.START,
                wrap = true,
                max_width_chars = 40,
                xalign = 0
            };

            entry = new Gtk.Entry () {
                visibility = !masked,
                hexpand = true,
                activates_default = true
            };

            var grid = new Gtk.Grid () {
                orientation = Gtk.Orientation.VERTICAL,
                row_spacing = 6,
                margin_start = 12,
                margin_end = 12,
                margin_bottom = 12
            };
            grid.add (heading);
            grid.add (label);
            grid.add (entry);

            get_content_area ().add (grid);

            add_button (_("Cancel"), Gtk.ResponseType.CANCEL);
            var ok = add_button (_("Continue"), Gtk.ResponseType.ACCEPT);
            ok.get_style_context ().add_class (Gtk.STYLE_CLASS_SUGGESTED_ACTION);
            set_default_response (Gtk.ResponseType.ACCEPT);

            width_request = 380;
        }

        /* Returns the typed value, or null when the user cancelled. */
        public static string? ask (Gtk.Window? parent, string profile_name, string prompt, bool masked) {
            var dialog = new InputDialog (parent, profile_name, prompt, masked);
            dialog.show_all ();
            var response = dialog.run ();
            string? result = null;
            if (response == Gtk.ResponseType.ACCEPT) {
                result = dialog.entry.text;
            }
            dialog.destroy ();
            return result;
        }
    }
}
