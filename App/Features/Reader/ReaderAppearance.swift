import CoreText
import ImageIO
import SwiftUI
import UIKit

private struct ReaderPositionPreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ReaderStylePreset: Identifiable {
    let id: String
    let name: String
    let background: UIColor
    let foreground: UIColor

    static let legadoDefaults: [ReaderStylePreset] = [
        .init(id: "wechat", name: "微信读书", background: UIColor(hex: 0xC0EDC6), foreground: UIColor(hex: 0x0B0B0B)),
        .init(id: "preset1", name: "预设1", background: UIColor(hex: 0xFFFFFF), foreground: UIColor(hex: 0x000000)),
        .init(id: "preset2", name: "预设2", background: UIColor(hex: 0xDDC090), foreground: UIColor(hex: 0x3E3422)),
        .init(id: "preset3", name: "预设3", background: UIColor(hex: 0xC2D8AA), foreground: UIColor(hex: 0x596C44)),
        .init(id: "preset4", name: "预设4", background: UIColor(hex: 0xDBB8E2), foreground: UIColor(hex: 0x68516C)),
        .init(id: "preset5", name: "预设5", background: UIColor(hex: 0xABCEE0), foreground: UIColor(hex: 0x3D4C54)),
        .init(id: "night", name: "夜间", background: UIColor(hex: 0x000000), foreground: UIColor(hex: 0xADADAD))
    ]
    static let eInk = ReaderStylePreset(
        id: "eink",
        name: "E-Ink",
        background: UIColor(hex: 0xFFFFFF),
        foreground: UIColor(hex: 0x000000)
    )

    static func resolve(_ id: String) -> ReaderStylePreset {
        let migratedID = switch id {
        case "dark": "night"
        case "light": "preset1"
        case "paper": "preset2"
        default: id
        }
        return legadoDefaults.first(where: { $0.id == migratedID }) ?? legadoDefaults[0]
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

enum ReaderBackgroundStore {
    static let maximumPixelSize = 2560

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/reader-background.jpg")
    }

    static func load(from source: URL = url) -> UIImage? {
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return nil }
        return try? downsample(data)
    }

    static func save(_ data: Data, to target: URL = url) throws -> UIImage {
        let image = try downsample(data)
        guard let encoded = image.jpegData(compressionQuality: 0.9) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: target, options: .atomic)
        return image
    }

    private static func downsample(_ data: Data) throws -> UIImage {
        // Decode only the size used by the reader, including backgrounds saved
        // by older versions. Full-resolution camera photos can exhaust memory.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return UIImage(cgImage: image)
    }

    static func remove() { try? FileManager.default.removeItem(at: url) }
}

enum ReaderFontError: LocalizedError, Equatable {
    case invalidFontFile

    var errorDescription: String? {
        switch self {
        case .invalidFontFile:
            "所选文件不是有效的字体文件，请选择 .ttf、.otf 或 .ttc 字体文件。"
        }
    }
}

enum ReaderFontStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/fonts", isDirectory: true)
    }

    static func install(from source: URL) throws -> String {
        let file = SecurityScopedImportURL(url: source)
        guard !file.isDirectory else { throw ReaderFontError.invalidFontFile }
        let data = try file.readData()
        return try install(data: data, filename: source.lastPathComponent, sourceURL: source)
    }

    static func install(data: Data, filename: String, sourceURL: URL? = nil) throws -> String {
        let trimmedName = URL(fileURLWithPath: filename).lastPathComponent
        guard !trimmedName.isEmpty, trimmedName != "/",
              font(data: data, size: 20, weight: 0) != nil else {
            throw ReaderFontError.invalidFontFile
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(trimmedName)
        if target != sourceURL {
            try data.write(to: target, options: .atomic)
        }
        return target.lastPathComponent
    }

    static func font(at path: String, size: CGFloat, weight: Int) -> UIFont? {
        guard !path.isEmpty else { return nil }
        // Older versions saved the absolute sandbox path. Resolve managed fonts
        // against the current container, including after an app update or restore.
        let url = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        if let provider = CGDataProvider(url: url as CFURL),
           let graphicsFont = CGFont(provider) {
            return styledFont(from: CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil) as UIFont, size: size, weight: weight)
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return collectionFont(from: data, size: size, weight: weight)
    }

    private static func font(data: Data, size: CGFloat, weight: Int) -> UIFont? {
        if let provider = CGDataProvider(data: data as CFData),
           let graphicsFont = CGFont(provider) {
            return styledFont(from: CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil) as UIFont, size: size, weight: weight)
        }
        return collectionFont(from: data, size: size, weight: weight)
    }

    private static func collectionFont(from data: Data, size: CGFloat, weight: Int) -> UIFont? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        let base = CTFontCreateWithFontDescriptor(first, size, nil) as UIFont
        return styledFont(from: base, size: size, weight: weight)
    }

    private static func styledFont(from base: UIFont, size: CGFloat, weight: Int) -> UIFont {
        // Use the selected face even when its PostScript name matches an installed font.
        if weight == 1,
           let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: size)
        }
        if weight == 2 {
            let descriptor = base.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.light.rawValue]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}

struct ReadingPalettePreference: DynamicProperty {
    @Environment(\.colorScheme) private var systemAppearance
    @AppStorage("themeMode") private var applicationMode = "0"
    @AppStorage("readerTheme") private var preset = "wechat"
    @AppStorage("readerPreviousDayTheme") private var savedDay = "wechat"
    @AppStorage("linkReadingAppearance") var linked = false

    var day: String { savedDay == "night" ? "wechat" : savedDay }
    var resolved: ReaderStylePreset {
        if applicationMode == "3" { return .eInk }
        guard linked else { return .resolve(preset) }
        let dark = applicationMode == "2" || (applicationMode == "0" && systemAppearance == .dark)
        return .resolve(dark ? "night" : (preset == "night" ? day : preset))
    }

    func choose(_ id: String) {
        if id != "night" { savedDay = id }
        else if resolved.id != "night" && resolved.id != "eink" { savedDay = resolved.id }
        preset = id
        guard linked else { return }
        if applicationMode == "0" {
            if (id == "night") != (systemAppearance == .dark) { linked = false }
        } else if applicationMode != "3" {
            applicationMode = id == "night" ? "2" : "1"
        }
    }
}
