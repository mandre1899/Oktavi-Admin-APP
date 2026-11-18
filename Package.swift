// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OktaviStaff",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OktaviStaff", targets: ["OktaviStaff"])
    ],
    targets: [
        .executableTarget(
            name: "OktaviStaff",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("EventKit")
            ]
        ),
        .testTarget(
            name: "OktaviStaffTests",
            dependencies: ["OktaviStaff"]
        )
    ]
)
