import CoreGraphics
import Foundation
import Metal
import Testing
@testable import LongScreenshot

/// Exercises the real GPU pipeline. Everything here needs a Metal device and
/// the app's compiled shader library, so these also stand in as the check that
/// DustEffect.metal made it into the bundle at all.
struct DustRendererTests {
    private static let color = (blue: UInt8(255), green: UInt8(128), red: UInt8(0), alpha: UInt8(255))

    @Test func rendererLinksEveryShaderFunctionFromTheAppsMetalLibrary() throws {
        try requireMetal()

        #expect(DustRenderer(pixelFormat: .bgra8Unorm) != nil)
    }

    @Test func theFirstFrameIsPixelIdenticalToTheSnapshotItReplaces() throws {
        try requireMetal()
        let renderer = try #require(DustRenderer(pixelFormat: .bgra8Unorm))
        let size = CGSize(width: 40, height: 20)
        let image = try #require(Self.makeImage(size: size))
        let target = try #require(Self.makeTarget(device: renderer.device, size: size))

        #expect(renderer.addGroup(
            [DustPiece(image: image, frame: CGRect(origin: .zero, size: size))],
            settings: DustSettings()
        ))
        // Zero elapsed time: the sweep has not started, so every particle is
        // still sitting in its own cell at full alpha. This frame is the one the
        // dissolve swaps in underneath the real views, and if it does not match
        // them exactly the hand-off flickers.
        renderer.render(into: target, viewSize: size, deltaTime: 0)

        let pixels = Self.readBack(target)
        #expect(pixels.count == 40 * 20 * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            #expect(pixels[index] == Self.color.blue)
            #expect(pixels[index + 1] == Self.color.green)
            #expect(pixels[index + 2] == Self.color.red)
            #expect(pixels[index + 3] == Self.color.alpha)
        }
    }

    @Test func theLayerIsEmptyOnceTheParticlesBurnOut() throws {
        try requireMetal()
        let renderer = try #require(DustRenderer(pixelFormat: .bgra8Unorm))
        let size = CGSize(width: 40, height: 20)
        let image = try #require(Self.makeImage(size: size))
        let target = try #require(Self.makeTarget(device: renderer.device, size: size))
        let settings = DustSettings()
        renderer.addGroup(
            [DustPiece(image: image, frame: CGRect(origin: .zero, size: size))],
            settings: settings
        )

        renderer.advance(deltaTime: settings.phaseLifespan / 2)
        #expect(renderer.isActive)

        renderer.advance(deltaTime: settings.phaseLifespan)
        renderer.render(into: target, viewSize: size, deltaTime: 0)

        // One last frame is drawn to clear the layer, and only then does the
        // renderer go idle so the display link and the panel can be torn down.
        #expect(!renderer.isActive)
        #expect(Self.readBack(target).allSatisfy { $0 == 0 })
    }

    @Test func aGroupWithNothingInItStagesNothing() throws {
        try requireMetal()
        let renderer = try #require(DustRenderer(pixelFormat: .bgra8Unorm))

        #expect(!renderer.addGroup([], settings: DustSettings()))
        #expect(!renderer.isActive)
    }

    @Test func aPieceTooSmallToHoldAParticleIsRejectedRatherThanDrawn() throws {
        try requireMetal()
        let renderer = try #require(DustRenderer(pixelFormat: .bgra8Unorm))
        let image = try #require(Self.makeImage(size: CGSize(width: 40, height: 20)))

        let staged = renderer.addGroup(
            [DustPiece(image: image, frame: CGRect(x: 0, y: 0, width: 0.5, height: 20))],
            settings: DustSettings()
        )

        #expect(!staged)
        #expect(!renderer.isActive)
    }

    // MARK: - Helpers

    private func requireMetal() throws {
        try #require(
            MTLCreateSystemDefaultDevice() != nil,
            "the dust effect needs a Metal device"
        )
    }

    private static func makeImage(size: CGSize) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: Int(size.width) * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }
        context.setFillColor(
            red: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: CGFloat(color.alpha) / 255
        )
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    private static func makeTarget(device: MTLDevice, size: CGSize) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    private static func readBack(_ texture: MTLTexture) -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        pixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        return pixels
    }
}
