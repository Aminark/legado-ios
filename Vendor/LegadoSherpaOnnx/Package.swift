// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LegadoSherpaOnnx",
    platforms: [.iOS(.v15)],
    products: [.library(name: "LegadoSherpaOnnx", targets: ["SherpaOnnxIOS", "OnnxruntimeIOS"])],
    targets: [
        .binaryTarget(
            name: "SherpaOnnxIOS",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v2.0.3-ios-static.xcframework.zip",
            checksum: "36603efc0908a18a3b4b5ec1a81a15accddbe9948720bf4d931ee14506f42481"
        ),
        .binaryTarget(
            name: "OnnxruntimeIOS",
            url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-ios-static-xcframework-1.28.2.xcframework.zip",
            checksum: "2c2299acbb461d26d4bac4bc85985d40e7c7177ed6072703ae0846d88b0b4599"
        )
    ]
)
