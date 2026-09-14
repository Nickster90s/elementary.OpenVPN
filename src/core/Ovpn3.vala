/*
 * Ovpn3.vala — low level bindings for the OpenVPN 3 Linux D-Bus services.
 *
 * The openvpn3 services expose lower case D-Bus property names, which do not
 * survive Vala's automatic name mangling for [DBus] interfaces, so everything
 * goes through explicit org.freedesktop.DBus.Properties calls instead.
 */

namespace Ovpn3 {

    public const string CONFIG_BUS = "net.openvpn.v3.configuration";
    public const string CONFIG_PATH = "/net/openvpn/v3/configuration";
    public const string CONFIG_IFACE = "net.openvpn.v3.configuration";

    public const string SESSION_BUS = "net.openvpn.v3.sessions";
    public const string SESSION_PATH = "/net/openvpn/v3/sessions";
    public const string SESSION_IFACE = "net.openvpn.v3.sessions";

    /* Mirrors openvpn3/constants.py (v27.1) */
    public enum StatusMajor {
        UNSET = 0,
        CFG_ERROR = 1,
        CONNECTION = 2,
        SESSION = 3,
        PKCS11 = 4,
        PROCESS = 5
    }

    public enum StatusMinor {
        UNSET = 0,
        CFG_ERROR = 1,
        CFG_OK = 2,
        CFG_INLINE_MISSING = 3,
        CFG_REQUIRE_USER = 4,
        CONN_INIT = 5,
        CONN_CONNECTING = 6,
        CONN_CONNECTED = 7,
        CONN_DISCONNECTING = 8,
        CONN_DISCONNECTED = 9,
        CONN_FAILED = 10,
        CONN_AUTH_FAILED = 11,
        CONN_RECONNECTING = 12,
        CONN_PAUSING = 13,
        CONN_PAUSED = 14,
        CONN_RESUMING = 15,
        CONN_DONE = 16,
        SESS_NEW = 17,
        SESS_BACKEND_COMPLETED = 18,
        SESS_REMOVED = 19,
        SESS_AUTH_USERPASS = 20,
        SESS_AUTH_CHALLENGE = 21,
        SESS_AUTH_URL = 22,
        PKCS11_SIGN = 23,
        PKCS11_ENCRYPT = 24,
        PKCS11_DECRYPT = 25,
        PKCS11_VERIFY = 26,
        PROC_STARTED = 27,
        PROC_STOPPED = 28,
        PROC_KILLED = 29
    }

    /* A single outstanding question from the VPN backend. */
    public struct InputSlot {
        public uint32 qtype;
        public uint32 qgroup;
        public uint32 qid;
        public string name;
        public string label;
        public bool masked;
    }

    public struct Status {
        public uint32 major;
        public uint32 minor;
        public string message;
    }

    /*
     * Thin wrapper around one remote object on the system bus.
     */
    public class RemoteObject : GLib.Object {
        public DBusConnection connection { get; construct; }
        public string bus_name { get; construct; }
        public string object_path { get; construct; }
        public string iface { get; construct; }

        public RemoteObject (DBusConnection conn, string bus_name, string object_path, string iface) {
            GLib.Object (connection: conn, bus_name: bus_name, object_path: object_path, iface: iface);
        }

        public Variant call (string method, Variant? args, string? reply_sig) throws GLib.Error {
            return connection.call_sync (
                bus_name, object_path, iface, method, args,
                reply_sig != null ? new VariantType (reply_sig) : null,
                DBusCallFlags.NONE, 30000, null
            );
        }

        /*
         * True when the reply means the service or object simply is not there.
         * The openvpn3 services exit when idle, so this is a normal condition
         * rather than a failure.
         */
        public static bool is_absent (GLib.Error e) {
            var name = DBusError.get_remote_error (e);
            return name == "org.freedesktop.DBus.Error.ServiceUnknown"
                || name == "org.freedesktop.DBus.Error.UnknownObject"
                || name == "org.freedesktop.DBus.Error.UnknownMethod"
                || name == "org.freedesktop.DBus.Error.NameHasNoOwner";
        }

        /*
         * Activating an idle service can return before it has exported its
         * objects, so a call that finds nothing there is retried briefly
         * before it is believed.
         */
        public Variant call_retrying (string method, Variant? args, string? reply_sig) throws GLib.Error {
            for (int attempt = 0; ; attempt++) {
                try {
                    return call (method, args, reply_sig);
                } catch (GLib.Error e) {
                    if (attempt >= 3 || !is_absent (e)) {
                        throw e;
                    }
                    debug ("%s is still starting up, retrying %s", bus_name, method);
                    Thread.usleep (200000);
                }
            }
        }

        public async Variant call_async (string method, Variant? args, string? reply_sig) throws GLib.Error {
            return yield connection.call (
                bus_name, object_path, iface, method, args,
                reply_sig != null ? new VariantType (reply_sig) : null,
                DBusCallFlags.NONE, 30000, null
            );
        }

        public Variant get_prop (string property) throws GLib.Error {
            var reply = connection.call_sync (
                bus_name, object_path, "org.freedesktop.DBus.Properties", "Get",
                new Variant ("(ss)", iface, property),
                new VariantType ("(v)"), DBusCallFlags.NONE, 30000, null
            );
            return reply.get_child_value (0).get_variant ();
        }

        public void set_prop (string property, Variant value) throws GLib.Error {
            connection.call_sync (
                bus_name, object_path, "org.freedesktop.DBus.Properties", "Set",
                new Variant ("(ssv)", iface, property, value),
                null, DBusCallFlags.NONE, 30000, null
            );
        }

        /* One round trip for every property on the object. */
        public Variant get_all_props () throws GLib.Error {
            var reply = connection.call_sync (
                bus_name, object_path, "org.freedesktop.DBus.Properties", "GetAll",
                new Variant ("(s)", iface),
                new VariantType ("(a{sv})"), DBusCallFlags.NONE, 30000, null
            );
            return reply.get_child_value (0);
        }

        /* Reads one entry out of an a{sv} returned by get_all_props(). */
        public static Variant? dict_lookup (Variant dict, string key) {
            for (size_t i = 0; i < dict.n_children (); i++) {
                var entry = dict.get_child_value (i);
                if (entry.get_child_value (0).get_string () == key) {
                    return entry.get_child_value (1).get_variant ();
                }
            }
            return null;
        }

        public string get_string_prop (string property) throws GLib.Error {
            return get_prop (property).get_string ();
        }

        public bool get_bool_prop (string property) throws GLib.Error {
            return get_prop (property).get_boolean ();
        }

        protected static string[] unpack_paths (Variant reply) {
            string[] result = {};
            var arr = reply.get_child_value (0);
            for (size_t i = 0; i < arr.n_children (); i++) {
                result += arr.get_child_value (i).get_string ();
            }
            return result;
        }
    }

    /*
     * A configuration profile stored in the OpenVPN 3 configuration manager.
     */
    public class Config : RemoteObject {
        public Config (DBusConnection conn, string path) {
            base (conn, CONFIG_BUS, path, CONFIG_IFACE);
        }

        public string profile_name {
            owned get {
                try {
                    return get_string_prop ("name");
                } catch (GLib.Error e) {
                    return "";
                }
            }
            set {
                try {
                    set_prop ("name", new Variant.string (value));
                } catch (GLib.Error e) {
                    warning ("Could not rename profile: %s", e.message);
                }
            }
        }

        public void remove () throws GLib.Error {
            call ("Remove", null, null);
        }

        /*
         * Overrides are how OpenVPN 3 relaxes its defaults for one profile —
         * compression and the legacy algorithms an OpenVPN 2 profile needs.
         */
        public Variant overrides () throws GLib.Error {
            return get_prop ("overrides");
        }

        public void set_override (string name, Variant value) throws GLib.Error {
            call ("SetOverride", new Variant ("(sv)", name, value), null);
        }

        public void unset_override (string name) throws GLib.Error {
            call ("UnsetOverride", new Variant ("(s)", name), null);
        }

    }

    /*
     * The configuration manager: import, list and look up profiles.
     */
    public class ConfigManager : RemoteObject {
        public signal void changed ();

        private uint sub_id = 0;

        public ConfigManager (DBusConnection conn) {
            base (conn, CONFIG_BUS, CONFIG_PATH, CONFIG_IFACE);

            sub_id = conn.signal_subscribe (
                null, CONFIG_IFACE, "ConfigurationManagerEvent", CONFIG_PATH, null,
                DBusSignalFlags.NONE,
                (c, sender, path, ifc, sig, parameters) => {
                    changed ();
                }
            );
        }

        ~ConfigManager () {
            if (sub_id != 0) {
                connection.signal_unsubscribe (sub_id);
            }
        }

        public string[] list () throws GLib.Error {
            return unpack_paths (call_retrying ("FetchAvailableConfigs", null, "(ao)"));
        }

        public string import (string name, string profile, bool persistent) throws GLib.Error {
            var reply = call ("Import", new Variant ("(ssbb)", name, profile, false, persistent), "(o)");
            return reply.get_child_value (0).get_string ();
        }

        public Config get_config (string path) {
            return new Config (connection, path);
        }
    }

    /*
     * A single VPN session (a running or starting tunnel).
     */
    public class Session : RemoteObject {
        public Session (DBusConnection conn, string path) {
            base (conn, SESSION_BUS, path, SESSION_IFACE);
        }

        public string config_path {
            owned get {
                try {
                    return get_string_prop ("config_path");
                } catch (GLib.Error e) {
                    return "";
                }
            }
        }

        public Status status () throws GLib.Error {
            var v = get_prop ("status");
            return Status () {
                major = v.get_child_value (0).get_uint32 (),
                minor = v.get_child_value (1).get_uint32 (),
                message = v.get_child_value (2).get_string ()
            };
        }

        public void ready () throws GLib.Error {
            call ("Ready", null, null);
        }

        public void connect_tunnel () throws GLib.Error {
            call ("Connect", null, null);
        }

        public void disconnect_tunnel () throws GLib.Error {
            call ("Disconnect", null, null);
        }

        /* Every question the backend is currently waiting on. */
        public InputSlot[] pending_input () throws GLib.Error {
            InputSlot[] slots = {};
            var groups = call ("UserInputQueueGetTypeGroup", null, "(a(uu))").get_child_value (0);

            for (size_t g = 0; g < groups.n_children (); g++) {
                var tg = groups.get_child_value (g);
                uint32 qtype = tg.get_child_value (0).get_uint32 ();
                uint32 qgroup = tg.get_child_value (1).get_uint32 ();

                var ids = call ("UserInputQueueCheck",
                                new Variant ("(uu)", qtype, qgroup), "(au)").get_child_value (0);

                for (size_t i = 0; i < ids.n_children (); i++) {
                    uint32 qid = ids.get_child_value (i).get_uint32 ();
                    var slot = call ("UserInputQueueFetch",
                                     new Variant ("(uuu)", qtype, qgroup, qid), "(uuussb)");
                    slots += InputSlot () {
                        qtype = slot.get_child_value (0).get_uint32 (),
                        qgroup = slot.get_child_value (1).get_uint32 (),
                        qid = slot.get_child_value (2).get_uint32 (),
                        name = slot.get_child_value (3).get_string (),
                        label = slot.get_child_value (4).get_string (),
                        masked = slot.get_child_value (5).get_boolean ()
                    };
                }
            }
            return slots;
        }

        public void provide_input (InputSlot slot, string value) throws GLib.Error {
            call ("UserInputProvide",
                  new Variant ("(uuus)", slot.qtype, slot.qgroup, slot.qid, value), null);
        }

        /* The most recent log line, which usually explains a failure. */
        public string last_log_message () {
            try {
                var v = get_prop ("last_log");
                for (size_t i = 0; i < v.n_children (); i++) {
                    var entry = v.get_child_value (i);
                    if (entry.get_child_value (0).get_string () == "log_message") {
                        return entry.get_child_value (1).get_variant ().get_string ();
                    }
                }
            } catch (GLib.Error e) {
                /* the session may already be gone */
            }
            return "";
        }

        /* Asks the backend to publish log events, which fills in last_log. */
        public void enable_log_forward (bool enable) {
            try {
                call ("LogForward", new Variant ("(b)", enable), null);
            } catch (GLib.Error e) {
                debug ("LogForward failed: %s", e.message);
            }
        }

        public void get_transfer (out int64 bytes_in, out int64 bytes_out) {
            bytes_in = 0;
            bytes_out = 0;
            try {
                var stats = get_prop ("statistics");
                for (size_t i = 0; i < stats.n_children (); i++) {
                    var entry = stats.get_child_value (i);
                    var key = entry.get_child_value (0).get_string ();
                    var val = entry.get_child_value (1).get_int64 ();
                    if (key == "BYTES_IN" || key == "TUN_BYTES_IN") {
                        bytes_in = val;
                    } else if (key == "BYTES_OUT" || key == "TUN_BYTES_OUT") {
                        bytes_out = val;
                    }
                }
            } catch (GLib.Error e) {
                /* statistics are unavailable until the tunnel is up */
            }
        }
    }

    /*
     * The session manager: create tunnels and enumerate running ones.
     */
    public class SessionManager : RemoteObject {
        public signal void changed ();

        private uint sub_id = 0;

        public SessionManager (DBusConnection conn) {
            base (conn, SESSION_BUS, SESSION_PATH, SESSION_IFACE);

            sub_id = conn.signal_subscribe (
                null, SESSION_IFACE, "SessionManagerEvent", SESSION_PATH, null,
                DBusSignalFlags.NONE,
                (c, sender, path, ifc, sig, parameters) => {
                    changed ();
                }
            );
        }

        ~SessionManager () {
            if (sub_id != 0) {
                connection.signal_unsubscribe (sub_id);
            }
        }

        public string[] list () throws GLib.Error {
            return unpack_paths (call_retrying ("FetchAvailableSessions", null, "(ao)"));
        }

        public string new_tunnel (string config_path) throws GLib.Error {
            var reply = call ("NewTunnel", new Variant ("(o)", config_path), "(o)");
            return reply.get_child_value (0).get_string ();
        }

        public Session get_session (string path) {
            return new Session (connection, path);
        }

        /* Returns the live session for a profile, or null when it is not running. */
        public Session? session_for_config (string config_path) {
            try {
                foreach (var path in list ()) {
                    var session = get_session (path);
                    if (session.config_path == config_path) {
                        return session;
                    }
                }
            } catch (GLib.Error e) {
                if (!is_absent (e)) {
                    warning ("Could not enumerate sessions: %s", e.message);
                }
            }
            return null;
        }
    }
}
