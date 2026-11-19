// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0

import PackageDescription
import Foundation

// Resolve archives inside this checkout, including an isolated release snapshot.
// The distributed app never loads a Homebrew library.
let rawStreamLibraries = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Vendor/QPDF/lib/macos-arm64")

// Swift Package Manager(SwiftPM)는 이 파일을 읽어 어떤 운영 체제에서,
// 어떤 실행 파일과 테스트를 빌드할지 결정한다. Xcode 프로젝트 파일을 따로
// 커밋하지 않아도 `swift build`, `swift run`, `swift test`가 같은 구성을
// 공유하는 이유가 바로 이 선언형 manifest 덕분이다.
let package = Package(
    name: "EmberPDF",
    // 번역 키가 누락되었을 때 기준이 되는 언어다. 실제 앱에서는 사용자가
    // 설정에서 선택한 언어 bundle을 `L10n`이 명시적으로 사용한다.
    defaultLocalization: "ko",
    platforms: [
        // PDFKit/SwiftUI API와 보안 bookmark 동작을 이 최소 버전에 맞춘다.
        .macOS(.v14)
    ],
    products: [
        // 배포 제품은 EmberPDF이며 기존 소스와 테스트의 Swift 모듈 이름은 유지한다.
        .executable(name: "EmberPDF", targets: ["HwattakPDF"]),
        .executable(name: "EmberPluginWorker", targets: ["EmberPluginWorker"])
    ],
    targets: [
        // Native page-content editing; PDFKit remains the viewer and document owner.
        .binaryTarget(name: "CPDFium", path: "Vendor/PDFium/CPDFium.xcframework"),
        .target(
            name: "CEmberPDFRawStreams",
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("../../Vendor/QPDF/include")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", rawStreamLibraries.appendingPathComponent("libqpdf.a").path,
                    "-Xlinker", rawStreamLibraries.appendingPathComponent("libjpeg.a").path
                ]),
                .linkedLibrary("z"),
                .linkedLibrary("c++")
            ]
        ),
        // Untrusted JavaScript runs in a disposable helper, never the PDF UI.
        .executableTarget(name: "EmberPluginWorker", dependencies: ["CEmberPDFRawStreams"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // Sources/HwattakPDF 아래의 앱 코드를 하나의 macOS 실행 파일로 묶는다.
        .executableTarget(
            name: "HwattakPDF",
            dependencies: ["CPDFium", "CEmberPDFRawStreams"],
            swiftSettings: [
                // 도구 체인은 Swift 6이지만 기존 AppKit/PDFKit delegate와의
                // 점진적 동시성 마이그레이션을 위해 언어 모드는 Swift 5다.
                .swiftLanguageMode(.v5)
            ]
        ),
        // Tests/HwattakPDFTests의 테스트가 앱 target을 `@testable import`하여
        // 내부 상태 머신과 보안 경계를 실제 제품 코드 그대로 검증한다.
        .testTarget(
            name: "HwattakPDFTests",
            dependencies: ["HwattakPDF"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ],
    cxxLanguageStandard: .cxx20
)
