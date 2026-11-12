import CMongoC

/// The MongoDB client library AirSQL ships: mongo-c-driver's libmongoc (scripts/build-mongoc.sh).
public enum MongoC {
    /// Its version, such as "2.5.8".
    public static var clientVersion: String { String(cString: mongoc_get_version()) }
}
