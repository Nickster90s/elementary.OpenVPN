/*
 * ProfileStore.vala — per profile settings (GSettings) and passwords (libsecret).
 *
 * Settings live in GSettings so that the app and the Wingpanel indicator see
 * each other's changes immediately, without any extra IPC.
 */

namespace Ovpn3Gui {

    public const string APP_ID = "io.github.nick.openvpn3gui";
    public const string PROFILE_SCHEMA = "io.github.nick.openvpn3gui.profile";
    public const string PROFILE_BASE_PATH = "/io/github/nick/openvpn3gui/profiles/";

    public class ProfileStore : GLib.Object {
        private static Settings? _root = null;
        private static HashTable<string, Settings>? _cache = null;

        /*
         * Vala only runs static field initialisers from class_init, which
         * never fires for a class that is used through static methods alone,
         * so every static field here is created on first use instead.
         */
        private static HashTable<string, Settings> cache {
            get {
                if (_cache == null) {
                    _cache = new HashTable<string, Settings> (str_hash, str_equal);
                }
                return _cache;
            }
        }

        public static Settings root {
            get {
                if (_root == null) {
                    _root = new Settings (APP_ID);
                }
                return _root;
            }
        }

        /* Turns /net/openvpn/v3/configuration/<uuid> into <uuid>. */
        public static string id_for (string config_path) {
            var idx = config_path.last_index_of_char ('/');
            return idx >= 0 ? config_path.substring (idx + 1) : config_path;
        }

        public static Settings for_profile (string config_path) {
            var id = id_for (config_path);
            var cached = cache.lookup (id);
            if (cached != null) {
                return cached;
            }

            var settings = new Settings.with_path (PROFILE_SCHEMA, PROFILE_BASE_PATH + id + "/");
            cache.insert (id, settings);
            return settings;
        }

        public static string default_profile {
            owned get { return root.get_string ("default-profile"); }
            set { root.set_string ("default-profile", value); }
        }

        public static string get_username (string config_path) {
            return for_profile (config_path).get_string ("username");
        }

        public static void set_username (string config_path, string username) {
            for_profile (config_path).set_string ("username", username);
        }

        /* Drops every stored setting and the saved password for a profile. */
        public static void forget (string config_path) {
            var id = id_for (config_path);
            var settings = for_profile (config_path);
            foreach (var key in settings.settings_schema.list_keys ()) {
                settings.reset (key);
            }
            cache.remove (id);

            if (default_profile == config_path) {
                default_profile = "";
            }

            SecretStore.clear.begin (config_path, "password", (obj, res) => {
                try {
                    SecretStore.clear.end (res);
                } catch (GLib.Error e) {
                    warning ("Could not remove stored password: %s", e.message);
                }
            });
        }
    }

    /*
     * Passwords are kept in the login keyring rather than on disk.
     */
    public class SecretStore : GLib.Object {
        private static Secret.Schema? _schema = null;

        private static Secret.Schema schema {
            get {
                if (_schema == null) {
                    _schema = new Secret.Schema (
                        "io.github.nick.openvpn3gui.Password", Secret.SchemaFlags.NONE,
                        "profile", Secret.SchemaAttributeType.STRING,
                        "kind", Secret.SchemaAttributeType.STRING
                    );
                }
                return _schema;
            }
        }

        public static async void store (string config_path, string profile_name,
                                        string password, string kind = "password") throws GLib.Error {
            var label = "OpenVPN 3 — %s (%s)".printf (profile_name, kind);
            yield Secret.password_store (
                schema, Secret.COLLECTION_DEFAULT, label, password, null,
                "profile", ProfileStore.id_for (config_path),
                "kind", kind
            );
        }

        public static async string? lookup (string config_path, string kind = "password") throws GLib.Error {
            return yield Secret.password_lookup (
                schema, null,
                "profile", ProfileStore.id_for (config_path),
                "kind", kind
            );
        }

        public static async void clear (string config_path, string kind = "password") throws GLib.Error {
            yield Secret.password_clear (
                schema, null,
                "profile", ProfileStore.id_for (config_path),
                "kind", kind
            );
        }
    }
}
