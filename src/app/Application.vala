/*
 * Application.vala — entry point for the OpenVPN 3 profile manager.
 */

namespace Ovpn3Gui {

    public class Application : Gtk.Application {
        private MainWindow? window = null;

        public Application () {
            GLib.Object (
                application_id: APP_ID,
                flags: ApplicationFlags.HANDLES_OPEN
            );
        }

        protected override void startup () {
            base.startup ();

            Environment.set_application_name (_("OpenVPN 3"));
            Gtk.Window.set_default_icon_name (APP_ID);

            /* Follow the system-wide light/dark preference. */
            var granite_settings = Granite.Settings.get_default ();
            var gtk_settings = Gtk.Settings.get_default ();
            gtk_settings.gtk_application_prefer_dark_theme =
                granite_settings.prefers_color_scheme == Granite.Settings.ColorScheme.DARK;

            granite_settings.notify["prefers-color-scheme"].connect (() => {
                gtk_settings.gtk_application_prefer_dark_theme =
                    granite_settings.prefers_color_scheme == Granite.Settings.ColorScheme.DARK;
            });

            var quit_action = new SimpleAction ("quit", null);
            quit_action.activate.connect (() => quit ());
            add_action (quit_action);
            set_accels_for_action ("app.quit", { "<Control>q", "<Control>w" });
        }

        private MainWindow ensure_window () {
            if (window == null) {
                window = new MainWindow (this);
                window.destroy.connect (() => window = null);
            }
            return window;
        }

        protected override void activate () {
            ensure_window ().present ();
        }

        protected override void open (File[] files, string hint) {
            var win = ensure_window ();
            win.present ();
            win.import_files (files);
        }

        public static int main (string[] args) {
            return new Application ().run (args);
        }
    }
}
