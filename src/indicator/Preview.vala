/*
 * Preview.vala — development harness. Renders the indicator's popover in a
 * plain window so it can be checked without restarting Wingpanel.
 */

public static int main (string[] args) {
    Gtk.init (ref args);

    var indicator = new Ovpn3Gui.Indicator ();

    var window = new Gtk.Window () {
        title = "Indicator preview",
        default_width = 300,
        default_height = 240,
        border_width = 12
    };

    var box = new Gtk.Grid () {
        orientation = Gtk.Orientation.VERTICAL,
        row_spacing = 12
    };
    box.add (indicator.get_display_widget ());

    var popover = indicator.get_widget ();
    if (popover != null) {
        box.add (popover);
    }

    window.add (box);
    window.destroy.connect (Gtk.main_quit);
    window.show_all ();

    indicator.opened ();

    Gtk.main ();
    return 0;
}
