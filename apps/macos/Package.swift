// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeedBasket",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FeedBasket", targets: ["FeedBasket"])],
    targets: [.executableTarget(name: "FeedBasket")]
)
