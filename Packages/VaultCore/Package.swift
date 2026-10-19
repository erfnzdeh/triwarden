// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VaultCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TriCrypto", targets: ["TriCrypto"]),
        .library(name: "VaultwardenAPI", targets: ["VaultwardenAPI"]),
        .library(name: "SSHAgent", targets: ["SSHAgent"]),
        .library(name: "SecretsAgent", targets: ["SecretsAgent"]),
    ],
    dependencies: [
        // Reference Argon2 (CC0 / Apache-2.0), pinned.
        .package(url: "https://github.com/P-H-C/phc-winner-argon2", revision: "f57e61e19229e23c4445b85494dbf7c07de721cb"),
    ],
    targets: [
        .target(name: "TriCrypto", dependencies: [.product(name: "argon2", package: "phc-winner-argon2")],
                // EFF Large Wordlist (CC BY 3.0, https://www.eff.org/dice) for passphrases and usernames.
                resources: [.copy("Resources/eff_large_wordlist.txt")]),
        .target(name: "VaultwardenAPI", dependencies: ["TriCrypto"]),
        .target(name: "SSHAgent"),
        .target(name: "SecretsAgent", dependencies: ["SSHAgent"]),
        .executableTarget(name: "SecretsAgentFixture", dependencies: ["SecretsAgent"], path: "Tests/Fixtures/SecretsAgentFixture"),
        .testTarget(name: "SecretsAgentTests", dependencies: ["SecretsAgent", "SecretsAgentFixture"]),
        .testTarget(name: "SSHAgentTests", dependencies: ["SSHAgent"]),
        .testTarget(name: "TriCryptoTests", dependencies: ["TriCrypto"]),
        .testTarget(name: "VaultwardenAPITests", dependencies: ["VaultwardenAPI"]),
    ]
)
