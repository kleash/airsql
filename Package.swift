// swift-tools-version:5.9
import PackageDescription

/// libmariadb (MariaDB Connector/C with OpenSSL), built by scripts/build-mariadb.sh (build.sh and test.sh run it when
/// it's missing or stale). The app carries it in Contents/Frameworks.
let mariadb = Context.packageDirectory + "/vendor/out/universal/lib"

let package = Package(
    name: "AirSQL",
    platforms: [.macOS(.v13)],
    targets: [
        // Runs a program on a pseudo-terminal (ported from AirSCP). Swift can't fork, and posix_spawn can't give the
        // child a controlling terminal, so this one function is C.
        .target(name: "CPTY"),
        // libmariadb's headers (module.modulemap names them in vendor/out) and `-lmariadb`.
        .systemLibrary(name: "CMariaDB"),
        .target(name: "AirSQLCore", dependencies: ["CPTY", "CMariaDB"], linkerSettings: [.unsafeFlags(["-L\(mariadb)"])]),
        .executableTarget(
            name: "AirSQL", dependencies: ["AirSQLCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        // The app's own checks share the core tests' harness, so one target tests both. They load libmariadb from
        // vendor/out.
        .testTarget(
            name: "AirSQLTests", dependencies: ["AirSQLCore", "AirSQL"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", mariadb])]),
    ]
)
