/*
 * TestHarness.vala — development-only driver for the connection logic.
 *
 * Usage: connect-test <profile name> <username> <password>
 *
 * It runs the same VpnController path the app and the indicator use, so the
 * credential hand-off to the OpenVPN 3 backend can be checked without a GUI.
 */

private static MainLoop loop;

public static int main (string[] args) {
    if (args.length < 4) {
        stderr.printf ("usage: %s <profile name> <username> <password>\n", args[0]);
        return 2;
    }

    var profile_name = args[1];
    var username = args[2];
    var password = args[3];

    Ovpn3Gui.VpnController controller;
    try {
        controller = Ovpn3Gui.VpnController.get_default ();
    } catch (GLib.Error e) {
        stderr.printf ("cannot reach the openvpn3 services: %s\n", e.message);
        return 1;
    }

    string? config_path = null;
    foreach (var profile in controller.list_profiles ()) {
        if (profile.name == profile_name) {
            config_path = profile.config_path;
        }
    }

    if (config_path == null) {
        stderr.printf ("no profile named '%s'\n", profile_name);
        return 1;
    }

    print ("profile: %s\n", config_path);

    Ovpn3Gui.ProfileStore.set_username (config_path, username);

    controller.state_changed.connect ((path, state, message) => {
        print ("  state: %-22s %s\n", state.to_label (), message);
    });

    controller.error_occurred.connect ((path, message) => {
        print ("  error: %s\n", message);
    });

    controller.input_requested.connect ((path, name, field, label, masked) => {
        print ("  !! unanswered prompt: %s (%s)\n", field, label);
        return null;
    });

    loop = new MainLoop ();

    Ovpn3Gui.SecretStore.store.begin (config_path, profile_name, password, "password", (obj, res) => {
        try {
            Ovpn3Gui.SecretStore.store.end (res);
            print ("password stored in the keyring\n");
        } catch (GLib.Error e) {
            print ("keyring store failed: %s\n", e.message);
        }

        print ("connecting…\n");
        controller.connect_profile.begin (config_path, (o, r) => {
            controller.connect_profile.end (r);
            print ("connect_profile returned\n");
        });
    });

    /* Give the backend a while to work, then tear the session down again. */
    Timeout.add_seconds (20, () => {
        print ("disconnecting…\n");
        controller.disconnect_profile.begin (config_path, (o, r) => {
            controller.disconnect_profile.end (r);
            loop.quit ();
        });
        return Source.REMOVE;
    });

    loop.run ();
    return 0;
}
