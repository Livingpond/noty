import AppKit
import CoreText

/// The open-source CJK faces shipped in Contents/Resources/Fonts (see
/// scripts/fetch-fonts.sh). They are registered for this process at launch, so
/// the faces Ink offers resolve without installing anything system-wide —
/// each font travels with its OFL licence beside it in the bundle.
enum BundledFonts {
    private static let extensions: Set<String> = ["otf", "ttf", "ttc"]

    /// Must run before anything resolves an Ink face. Any file that fails to
    /// register simply stays hidden by Ink's installed check.
    static func registerAll() {
        guard let fontsURL = Bundle.main.resourceURL?
            .appendingPathComponent("Fonts", isDirectory: true),
            let items = try? FileManager.default
                .contentsOfDirectory(at: fontsURL, includingPropertiesForKeys: nil)
        else { return }

        let fonts = items.filter { extensions.contains($0.pathExtension.lowercased()) }
        guard !fonts.isEmpty else { return }
        // .process keeps the fonts private to this app; nothing is installed.
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true) { _, _ in true }
    }
}
