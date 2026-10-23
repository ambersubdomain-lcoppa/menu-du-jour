import Foundation

/// Decides whether what landed on the pasteboard after a synthetic ⌘C is a
/// *text selection* we may transform and paste back.
///
/// The pasteboard's `changeCount` advancing proves only that the app's Copy
/// command produced something. It does not prove the user had text selected:
/// a Finder file copy, a copied image, a copied link and a copied contact all
/// advance it too, and several of them carry a plain-text flavour as a
/// courtesy — a Finder file copy puts the filename there. Pasting a
/// case-transformed filename back into Finder is not a change-case operation.
///
/// So the test is two-sided: there must be a text flavour, *and* there must be
/// no flavour that marks the payload as an object which merely describes
/// itself in text.
public enum ClipboardPayloadPolicy {

    /// Flavours that mean "this is text".
    private static let textTypes: Set<String> = [
        "public.utf8-plain-text",
        "public.plain-text",
        "public.utf16-external-plain-text",
        "public.rtf",
        "com.apple.flat-rtfd",
        "public.html",
        "nsstringpboardtype",
        "nsrtfpboardtype",
    ]

    /// Flavours that mean "this is an object, not a text selection" — whatever
    /// else is alongside them.
    private static let objectTypes: Set<String> = [
        "public.file-url",
        "public.url",
        "nsfilenamespboardtype",
        "nsurlpboardtype",
        "public.vcard",
        "public.png",
        "public.tiff",
        "public.jpeg",
        "com.adobe.pdf",
        "nspasteboardtypepng",
        "nstiffpboardtype",
    ]

    /// True when `types` describes a text selection safe to transform.
    /// Unrecognised flavours are ignored: apps routinely attach private
    /// flavours to ordinary text, and vetoing on those would disable the path
    /// almost everywhere.
    public static func isTransformableText(types: [String]) -> Bool {
        let normalized = Set(types.map { $0.lowercased() })
        guard normalized.contains(where: { textTypes.contains($0) }) else { return false }
        return !normalized.contains(where: { objectTypes.contains($0) })
    }
}
