/*
 * VpnController.vala — the piece that both the app and the indicator drive.
 *
 * It owns the connection to the OpenVPN 3 services, answers the backend's
 * credential questions from the keyring, and publishes a simple connection
 * state per profile.
 */

namespace Ovpn3Gui {

    public enum ConnState {
        DISCONNECTED,
        CONNECTING,
        CONNECTED,
        DISCONNECTING,
        PAUSED,
        AUTH_FAILED,
        FAILED;

        public bool is_busy () {
            return this == CONNECTING || this == DISCONNECTING;
        }

        public bool is_up () {
            return this == CONNECTED || this == PAUSED;
        }

        public string icon_name () {
            switch (this) {
                case CONNECTED:
                    return "network-vpn-symbolic";
                case CONNECTING:
                case DISCONNECTING:
                    return "network-vpn-acquiring-symbolic";
                case PAUSED:
                    return "network-vpn-acquiring-symbolic";
                case AUTH_FAILED:
                case FAILED:
                    return "network-vpn-no-route-symbolic";
                default:
                    return "network-vpn-disconnected-symbolic";
            }
        }

        public string to_label () {
            switch (this) {
                case CONNECTED:     return _("Connected");
                case CONNECTING:    return _("Connecting…");
                case DISCONNECTING: return _("Disconnecting…");
                case PAUSED:        return _("Paused");
                case AUTH_FAILED:   return _("Authentication failed");
                case FAILED:        return _("Connection failed");
                default:            return _("Not connected");
            }
        }
    }

    public class Profile : GLib.Object {
        public string config_path { get; set; }
        public string name { get; set; }
    }

    public class VpnController : GLib.Object {
        private static VpnController? instance = null;

        public DBusConnection connection { get; private set; }
        public Ovpn3.ConfigManager configs { get; private set; }
        public Ovpn3.SessionManager sessions { get; private set; }

        /* Emitted when profiles are added, removed or renamed. */
        public signal void profiles_changed ();
        /* Emitted whenever a profile's connection state changes. */
        public signal void state_changed (string config_path, ConnState state, string message);
        /* Emitted when something went wrong that the user should see. */
        public signal void error_occurred (string config_path, string message);
        /*
         * Asks the front end for a value the keyring could not supply — a
         * missing username, or a one time challenge code. Returning null
         * aborts the connection attempt.
         */
        public signal string? input_requested (string config_path, string profile_name,
                                               string field, string label, bool masked);

        private HashTable<string, ConnState> states;
        private HashTable<string, string> messages;
        private uint poll_id = 0;
        /*
         * The openvpn3 services exit when idle, so only poll while there is
         * actually a session to watch; otherwise we would keep them alive for
         * the whole login session for nothing.
         */
        private bool polling_wanted = false;
        /*
         * Profiles with a connection attempt in flight. The attempt publishes
         * their state itself, so the poller must not second-guess it.
         */
        private GenericSet<string> connecting;
        private List<Profile>? profile_cache = null;

        public static VpnController get_default () throws GLib.Error {
            if (instance == null) {
                instance = new VpnController ();
            }
            return instance;
        }

        private VpnController () throws GLib.Error {
            states = new HashTable<string, ConnState> (str_hash, str_equal);
            messages = new HashTable<string, string> (str_hash, str_equal);
            connecting = new GenericSet<string> (str_hash, str_equal);

            connection = Bus.get_sync (BusType.SYSTEM, null);
            configs = new Ovpn3.ConfigManager (connection);
            sessions = new Ovpn3.SessionManager (connection);

            configs.changed.connect (() => invalidate_profiles ());
            sessions.changed.connect (() => {
                refresh_states ();
                start_polling ();
            });

            refresh_states ();
            if (polling_wanted) {
                start_polling ();
            }
        }

        ~VpnController () {
            if (poll_id != 0) {
                Source.remove (poll_id);
            }
        }

        private void start_polling () {
            polling_wanted = true;
            if (poll_id != 0) {
                return;
            }
            poll_id = Timeout.add_seconds (2, () => {
                refresh_states ();
                if (!polling_wanted) {
                    poll_id = 0;
                    return Source.REMOVE;
                }
                return Source.CONTINUE;
            });
        }

        /* ---------------------------------------------------------------- */
        /* Profiles                                                          */
        /* ---------------------------------------------------------------- */

        /*
         * The panel asks for this on every state change, so the list is built
         * once per change to the configuration manager and cached. Each
         * profile costs a single GetAll rather than one call per property.
         */
        public unowned List<Profile> list_profiles () {
            if (profile_cache != null) {
                return profile_cache;
            }

            var result = new List<Profile> ();
            try {
                foreach (var path in configs.list ()) {
                    var props = configs.get_config (path).get_all_props ();
                    var name = Ovpn3.RemoteObject.dict_lookup (props, "name");

                    result.append (new Profile () {
                        config_path = path,
                        name = name != null ? name.get_string () : path
                    });
                }
            } catch (GLib.Error e) {
                if (Ovpn3.RemoteObject.is_absent (e)) {
                    debug ("Configuration manager is not running; no profiles to show");
                } else {
                    warning ("Could not list profiles: %s", e.message);
                }
            }

            result.sort ((a, b) => a.name.collate (b.name));
            profile_cache = (owned) result;
            return profile_cache;
        }

        /*
         * Whether the OpenVPN 3 services exist at all. They are D-Bus
         * activated and exit when idle, so "not currently running" says
         * nothing; only the activatable name list distinguishes an idle
         * service from a package that was never installed.
         */
        public bool backend_installed () {
            try {
                var reply = connection.call_sync (
                    "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "ListActivatableNames", null, new VariantType ("(as)"),
                    DBusCallFlags.NONE, 10000, null
                );
                var names = reply.get_child_value (0);
                for (size_t i = 0; i < names.n_children (); i++) {
                    if (names.get_child_value (i).get_string () == Ovpn3.CONFIG_BUS) {
                        return true;
                    }
                }
            } catch (GLib.Error e) {
                warning ("Could not ask the bus for activatable names: %s", e.message);
                /* Assume it is there rather than block the user on our own doubt. */
                return true;
            }
            return false;
        }

        public Profile? profile_for (string config_path) {
            foreach (unowned Profile profile in list_profiles ()) {
                if (profile.config_path == config_path) {
                    return profile;
                }
            }
            return null;
        }

        private void invalidate_profiles () {
            profile_cache = null;
            profiles_changed ();
        }

        /*
         * Imports an .ovpn file. Profiles are imported persistently so they
         * survive a reboot and the openvpn3 services being restarted.
         */
        public string import_file (File file, string? name = null) throws GLib.Error {
            uint8[] contents;
            file.load_contents (null, out contents, null);

            var profile = (string) contents;
            var display_name = name;
            if (display_name == null || display_name.strip () == "") {
                display_name = file.get_basename ();
                var dot = display_name.last_index_of_char ('.');
                if (dot > 0) {
                    display_name = display_name.substring (0, dot);
                }
            }

            var path = configs.import (display_name, profile, true);
            invalidate_profiles ();
            return path;
        }

        public void remove_profile (string config_path) throws GLib.Error {
            var session = sessions.session_for_config (config_path);
            if (session != null) {
                try {
                    session.disconnect_tunnel ();
                } catch (GLib.Error e) {
                    warning ("Could not disconnect before removal: %s", e.message);
                }
            }

            configs.get_config (config_path).remove ();
            ProfileStore.forget (config_path);
            invalidate_profiles ();
        }

        public void rename_profile (string config_path, string name) throws GLib.Error {
            configs.get_config (config_path).profile_name = name;
            invalidate_profiles ();
        }

        /* ---------------------------------------------------------------- */
        /* State tracking                                                    */
        /* ---------------------------------------------------------------- */

        public ConnState state_for (string config_path) {
            if (states.contains (config_path)) {
                return states.lookup (config_path);
            }
            return ConnState.DISCONNECTED;
        }

        public string message_for (string config_path) {
            var msg = messages.lookup (config_path);
            return msg != null ? msg : "";
        }

        public string? default_profile_path () {
            var path = ProfileStore.default_profile;
            if (path == "") {
                return null;
            }

            /* A stale default (profile removed elsewhere) is treated as unset. */
            try {
                foreach (var candidate in configs.list ()) {
                    if (candidate == path) {
                        return path;
                    }
                }
            } catch (GLib.Error e) {
                return path;
            }
            return null;
        }

        private static ConnState map_status (Ovpn3.Status status) {
            switch (status.minor) {
                case Ovpn3.StatusMinor.CONN_CONNECTED:
                    return ConnState.CONNECTED;
                case Ovpn3.StatusMinor.CONN_INIT:
                case Ovpn3.StatusMinor.CONN_CONNECTING:
                case Ovpn3.StatusMinor.CONN_RECONNECTING:
                case Ovpn3.StatusMinor.CONN_RESUMING:
                case Ovpn3.StatusMinor.SESS_NEW:
                case Ovpn3.StatusMinor.CFG_REQUIRE_USER:
                case Ovpn3.StatusMinor.SESS_AUTH_USERPASS:
                case Ovpn3.StatusMinor.SESS_AUTH_CHALLENGE:
                case Ovpn3.StatusMinor.SESS_AUTH_URL:
                case Ovpn3.StatusMinor.PROC_STARTED:
                    return ConnState.CONNECTING;
                case Ovpn3.StatusMinor.CONN_DISCONNECTING:
                case Ovpn3.StatusMinor.CONN_PAUSING:
                    return ConnState.DISCONNECTING;
                case Ovpn3.StatusMinor.CONN_PAUSED:
                    return ConnState.PAUSED;
                case Ovpn3.StatusMinor.CONN_AUTH_FAILED:
                    return ConnState.AUTH_FAILED;
                case Ovpn3.StatusMinor.CONN_FAILED:
                case Ovpn3.StatusMinor.CFG_ERROR:
                case Ovpn3.StatusMinor.PROC_KILLED:
                    return ConnState.FAILED;
                default:
                    return ConnState.DISCONNECTED;
            }
        }

        /* Reads every live session once and republishes the states that moved. */
        public void refresh_states () {
            var seen = new HashTable<string, ConnState> (str_hash, str_equal);
            var seen_msg = new HashTable<string, string> (str_hash, str_equal);

            string[] session_paths = {};
            try {
                session_paths = sessions.list ();
            } catch (GLib.Error e) {
                if (!Ovpn3.RemoteObject.is_absent (e)) {
                    /* Keep what we have; a transient failure is not proof of anything. */
                    debug ("Could not list sessions: %s", e.message);
                    return;
                }
                /* No session manager running means there are no sessions. */
            }

            {
                foreach (var session_path in session_paths) {
                    var session = sessions.get_session (session_path);

                    try {
                        var props = session.get_all_props ();

                        var config = Ovpn3.RemoteObject.dict_lookup (props, "config_path");
                        if (config == null || config.get_string () == "") {
                            continue;
                        }
                        var config_path = config.get_string ();

                        var raw = Ovpn3.RemoteObject.dict_lookup (props, "status");
                        if (raw == null) {
                            seen.insert (config_path, ConnState.CONNECTING);
                            seen_msg.insert (config_path, "");
                            continue;
                        }

                        var status = Ovpn3.Status () {
                            major = raw.get_child_value (0).get_uint32 (),
                            minor = raw.get_child_value (1).get_uint32 (),
                            message = raw.get_child_value (2).get_string ()
                        };
                        seen.insert (config_path, map_status (status));
                        seen_msg.insert (config_path, status.message);
                    } catch (GLib.Error e) {
                        /* The session went away between listing and reading. */
                        continue;
                    }
                }
            }

            /* Anything we knew about that no longer has a session is down. */
            string[] dropped = {};
            foreach (unowned string config_path in states.get_keys_as_array ()) {
                if (seen.contains (config_path) || connecting.contains (config_path)) {
                    continue;
                }
                var previous = states.lookup (config_path);
                /* Keep a terminal failure visible until the user acts on it. */
                if (previous == ConnState.AUTH_FAILED || previous == ConnState.FAILED) {
                    continue;
                }
                if (previous != ConnState.DISCONNECTED) {
                    dropped += config_path;
                }
            }
            foreach (var config_path in dropped) {
                publish (config_path, ConnState.DISCONNECTED, "");
            }

            string[] updated = {};
            foreach (unowned string config_path in seen.get_keys_as_array ()) {
                if (connecting.contains (config_path)) {
                    continue;
                }
                if (!states.contains (config_path) || states.lookup (config_path) != seen.lookup (config_path)) {
                    updated += config_path;
                }
            }
            foreach (var config_path in updated) {
                publish (config_path, seen.lookup (config_path), seen_msg.lookup (config_path));
            }

            polling_wanted = seen.size () > 0;
        }

        private void publish (string config_path, ConnState state, string message = "") {
            states.insert (config_path, state);
            messages.insert (config_path, message);
            state_changed (config_path, state, message);
        }

        /* ---------------------------------------------------------------- */
        /* Connecting                                                        */
        /* ---------------------------------------------------------------- */

        private async void nap (uint ms) {
            Timeout.add (ms, () => {
                nap.callback ();
                return Source.REMOVE;
            });
            yield;
        }

        /*
         * Answers one backend question. Known fields come from settings and
         * the keyring; anything else is passed up to the front end.
         */
        private async string? resolve_slot (string config_path, string profile_name,
                                            Ovpn3.InputSlot slot) {
            string? value = null;

            switch (slot.name) {
                case "username":
                    value = ProfileStore.get_username (config_path);
                    if (value == "") {
                        value = null;
                    }
                    break;

                case "password":
                case "pk_passphrase":
                    try {
                        value = yield SecretStore.lookup (config_path, slot.name);
                    } catch (GLib.Error e) {
                        warning ("Keyring lookup failed: %s", e.message);
                    }
                    break;

                default:
                    /* dynamic challenges and anything new must be asked live */
                    break;
            }

            if (value != null) {
                debug ("answering '%s' from stored settings", slot.name);
                return value;
            }

            debug ("asking the front end for '%s'", slot.name);
            var answer = input_requested (config_path, profile_name, slot.name, slot.label, slot.masked);
            if (answer == null) {
                return null;
            }

            /* Remember what the user typed, except for one-shot challenges. */
            if (slot.name == "username") {
                ProfileStore.set_username (config_path, answer);
            } else if (slot.name == "password" || slot.name == "pk_passphrase") {
                try {
                    yield SecretStore.store (config_path, profile_name, answer, slot.name);
                } catch (GLib.Error e) {
                    warning ("Could not save password: %s", e.message);
                }
            }

            return answer;
        }

        public async void connect_profile (string config_path) {
            if (state_for (config_path).is_up () || state_for (config_path).is_busy ()) {
                return;
            }

            var profile_name = configs.get_config (config_path).profile_name;
            connecting.add (config_path);
            publish (config_path, ConnState.CONNECTING, _("Starting…"));
            start_polling ();

            Ovpn3.Session session;
            try {
                var existing = sessions.session_for_config (config_path);
                session = existing != null ? existing : sessions.get_session (sessions.new_tunnel (config_path));
            } catch (GLib.Error e) {
                fail (config_path, e.message);
                return;
            }

            /*
             * Ready() throws for as long as the backend still wants input, so
             * answer whatever it has queued and ask again.
             */
            var deadline = get_monotonic_time () + 60 * 1000000;
            while (true) {
                if (get_monotonic_time () > deadline) {
                    abort_session (session);
                    fail (config_path, _("Timed out waiting for the VPN backend"));
                    return;
                }

                try {
                    session.ready ();
                    debug ("session is ready, no further input needed");
                    break;
                } catch (GLib.Error ready_error) {
                    Ovpn3.InputSlot[] slots;
                    try {
                        slots = session.pending_input ();
                    } catch (GLib.Error e) {
                        abort_session (session);
                        fail (config_path, e.message);
                        return;
                    }

                    if (slots.length == 0) {
                        /* The backend is still starting up; give it a moment. */
                        yield nap (300);
                        continue;
                    }

                    debug ("backend is asking for %d value(s)", slots.length);

                    foreach (var slot in slots) {
                        var value = yield resolve_slot (config_path, profile_name, slot);
                        if (value == null) {
                            abort_session (session);
                            connecting.remove (config_path);
                            publish (config_path, ConnState.DISCONNECTED, "");
                            return;
                        }

                        try {
                            session.provide_input (slot, value);
                        } catch (GLib.Error e) {
                            abort_session (session);
                            fail (config_path, e.message);
                            return;
                        }
                    }
                }
            }

            try {
                debug ("credentials accepted, connecting the tunnel");
                session.enable_log_forward (true);
                session.connect_tunnel ();
            } catch (GLib.Error e) {
                abort_session (session);
                fail (config_path, e.message);
                return;
            }

            yield watch_startup (config_path, session);
        }

        /*
         * Follows the first seconds of a tunnel. Without this a backend that
         * dies straight away would simply drop back to "not connected" and the
         * user would never learn why.
         */
        private async void watch_startup (string config_path, Ovpn3.Session session) {
            var last_message = "";

            for (int i = 0; i < 24; i++) {
                yield nap (250);

                Ovpn3.Status status;
                try {
                    status = session.status ();
                } catch (GLib.Error e) {
                    /* The session object is gone: the backend gave up. */
                    var reason = last_message != "" ? last_message : _("The VPN backend stopped");
                    debug ("session vanished during startup: %s", reason);
                    fail (config_path, reason);
                    return;
                }

                if (status.message != "") {
                    last_message = status.message;
                }

                var state = map_status (status);
                if (state == ConnState.CONNECTED) {
                    connecting.remove (config_path);
                    publish (config_path, ConnState.CONNECTED, status.message);
                    return;
                }

                if (state == ConnState.FAILED || state == ConnState.AUTH_FAILED) {
                    var reason = session.last_log_message ();
                    if (reason == "") {
                        reason = last_message;
                    }
                    abort_session (session);
                    connecting.remove (config_path);
                    publish (config_path, state, reason);
                    error_occurred (config_path, reason != "" ? reason : state.to_label ());
                    return;
                }
            }

            /* Still negotiating after the watch window; hand back to the poller. */
            connecting.remove (config_path);
            refresh_states ();
        }

        private void fail (string config_path, string message) {
            connecting.remove (config_path);
            publish (config_path, ConnState.FAILED, message);
            error_occurred (config_path, message);
        }

        public async void disconnect_profile (string config_path) {
            connecting.remove (config_path);
            var session = sessions.session_for_config (config_path);
            if (session == null) {
                publish (config_path, ConnState.DISCONNECTED, "");
                return;
            }

            publish (config_path, ConnState.DISCONNECTING, "");
            try {
                session.disconnect_tunnel ();
            } catch (GLib.Error e) {
                warning ("Disconnect failed: %s", e.message);
                error_occurred (config_path, e.message);
            }

            yield nap (400);
            refresh_states ();
        }

        public async void toggle_profile (string config_path, bool active) {
            if (active) {
                yield connect_profile (config_path);
            } else {
                yield disconnect_profile (config_path);
            }
        }

        private void abort_session (Ovpn3.Session session) {
            try {
                session.disconnect_tunnel ();
            } catch (GLib.Error e) {
                /* the backend may already be gone */
            }
        }

        public void get_transfer (string config_path, out int64 bytes_in, out int64 bytes_out) {
            bytes_in = 0;
            bytes_out = 0;
            var session = sessions.session_for_config (config_path);
            if (session != null) {
                session.get_transfer (out bytes_in, out bytes_out);
            }
        }
    }
}
