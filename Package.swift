// swift-tools-version:5.9
import PackageDescription

/// libmariadb (MariaDB Connector/C with OpenSSL), built by scripts/build-mariadb.sh (build.sh and test.sh run it when
/// it's missing or stale). The app carries it in Contents/Frameworks.
let mariadb = Context.packageDirectory + "/vendor/out/universal/lib"
/// libmongoc2 (libmongoc and libbson with OpenSSL inside), built by scripts/build-mongoc.sh, as libmariadb is. Its
/// headers include each other as <bson/…> and <mongoc/…>: every target that sees CMongoC gets its include folder.
let mongoc = Context.packageDirectory + "/vendor/mongoc/universal"
let mongocHeaders: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(mongoc)/include"])]

let package = Package(
    name: "AirSQL",
    platforms: [.macOS(.v13)],
    targets: [
        // Runs a program on a pseudo-terminal (ported from AirSCP). Swift can't fork, and posix_spawn can't give the
        // child a controlling terminal, so this one function is C.
        .target(name: "CPTY"),
        // libmariadb's headers (module.modulemap names them in vendor/out) and `-lmariadb`.
        .systemLibrary(name: "CMariaDB"),
        // libmongoc2's headers (in vendor/mongoc) and `-lmongoc2`.
        .systemLibrary(name: "CMongoC"),
        .target(name: "AirSQLCore", dependencies: ["CPTY", "CMariaDB", "CMongoC"], swiftSettings: mongocHeaders,
                linkerSettings: [.unsafeFlags(["-L\(mariadb)", "-L\(mongoc)/lib"])]),
        .executableTarget(
            name: "AirSQL", dependencies: ["AirSQLCore"], swiftSettings: mongocHeaders,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        // The app's own checks share the core tests' harness, so one target tests both. They load libmariadb and
        // libmongoc2 from vendor/.
        .testTarget(
            name: "AirSQLTests", dependencies: ["AirSQLCore", "AirSQL"], swiftSettings: mongocHeaders,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", mariadb,
                                           "-Xlinker", "-rpath", "-Xlinker", mongoc + "/lib"])]),
    ]
)
