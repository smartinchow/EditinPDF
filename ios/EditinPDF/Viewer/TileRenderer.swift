import CoreGraphics
import EditinPDFCore
import Foundation

/// Turns the engine's pixels into an image Core Graphics can draw.
enum TileRenderer {
    /// `tile` as an image, sharing its bytes: premultiplied RGBA, 8 bits a channel, sRGB, the first
    /// row at the top. Nil when the bytes do not fill `width * height` pixels exactly.
    static func image(for tile: RenderedTile) -> CGImage? {
        let width = Int(tile.width)
        let height = Int(tile.height)
        guard width > 0, height > 0, tile.rgba.count == width * height * 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              // The provider keeps the `Data` alive; the pixels are not copied.
              let provider = CGDataProvider(data: tile.rgba as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
