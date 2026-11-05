//
//  DustRenderer.swift
//  LongScreenshot
//

import CoreGraphics
import Metal
import QuartzCore

/// One snapshot to dissolve, and where it sits in the dust layer.
struct DustPiece {
    let image: CGImage
    /// y-down, in points, relative to the layer.
    let frame: CGRect
}

/// Owns the Metal state for the dust effect and drives any number of
/// simultaneously dissolving pieces.
///
/// The renderer knows nothing about AppKit. It is handed snapshot images and
/// the rects those snapshots occupied, both in the coordinate space of the
/// layer it draws into.
final class DustRenderer {
    /// Mirrors `DustConfig` in DustEffect.metal - a flat list of floats, in the
    /// same order, so the two cannot disagree about layout.
    private struct Config {
        var itemWidth: Float = 0
        var itemHeight: Float = 0
        var gridWidth: Float = 0
        var gridHeight: Float = 0
        var gravity: Float = 0
        var minSpeed: Float = 0
        var maxSpeed: Float = 0
        var minLifetime: Float = 0
        var maxLifetime: Float = 0
        var waveWidth: Float = 0
        var waveDuration: Float = 0
        var fadeDuration: Float = 0
        var verticalDirection: Float = 1
        var phase: Float = 0
        var timeStep: Float = 0
        var seed: Float = 0
        var sweepStart: Float = 0
        var sweepSpan: Float = 0
    }

    private final class Item {
        let texture: MTLTexture
        /// y-down, in points, relative to the layer.
        let frame: CGRect
        let columns: Int
        let rows: Int
        let particles: MTLBuffer
        let settings: DustSettings
        let seed: Float
        let sweepStart: Float
        let sweepSpan: Float
        var phase: Float = 0
        var isInitialized = false

        var particleCount: Int { columns * rows }

        init(texture: MTLTexture,
             frame: CGRect,
             columns: Int,
             rows: Int,
             particles: MTLBuffer,
             settings: DustSettings,
             seed: Float,
             sweepStart: Float,
             sweepSpan: Float) {
            self.texture = texture
            self.frame = frame
            self.columns = columns
            self.rows = rows
            self.particles = particles
            self.settings = settings
            self.seed = seed
            self.sweepStart = sweepStart
            self.sweepSpan = sweepSpan
        }
    }

    /// Guards against a runaway particle count on a large piece.
    private static let maximumParticleCount = 400_000

    private static let particleStride = MemoryLayout<Float>.stride * 5

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let initializePipeline: MTLComputePipelineState
    private let updatePipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState

    private var items: [Item] = []
    private var nextSeed: Float = 1
    /// Set after the last item goes away so we present one empty frame instead
    /// of leaving the final particles stuck on screen.
    private var needsFinalClear = false

    var isActive: Bool { !items.isEmpty || needsFinalClear }

    init?(pixelFormat: MTLPixelFormat) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let initializeFunction = library.makeFunction(name: "dustInitialize"),
              let updateFunction = library.makeFunction(name: "dustUpdate"),
              let vertexFunction = library.makeFunction(name: "dustVertex"),
              let fragmentFunction = library.makeFunction(name: "dustFragment"),
              let initializePipeline = try? device.makeComputePipelineState(function: initializeFunction),
              let updatePipeline = try? device.makeComputePipelineState(function: updateFunction)
        else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction

        guard let attachment = descriptor.colorAttachments[0] else {
            return nil
        }
        attachment.pixelFormat = pixelFormat
        // Standard "source over" with premultiplied alpha - the snapshot comes
        // in premultiplied and the fragment shader keeps it that way.
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let renderPipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.initializePipeline = initializePipeline
        self.updatePipeline = updatePipeline
        self.renderPipeline = renderPipeline
    }

    // MARK: - Items

    /// Adds a set of pieces that dissolve together under one wave front.
    ///
    /// The sweep axis is normalized across the group's bounding box rather than
    /// each piece, so the pieces crumble in the order they are stacked on
    /// screen instead of every piece starting at its own top edge.
    @discardableResult
    func addGroup(_ pieces: [DustPiece], settings: DustSettings) -> Bool {
        let bounds = DustSweep.bounds(of: pieces.map(\.frame))
        var added = false
        for piece in pieces {
            let sweep = DustSweep.normalization(for: piece.frame, in: bounds)
            if addItem(piece, settings: settings, sweep: sweep) {
                added = true
            }
        }
        return added
    }

    private func addItem(
        _ piece: DustPiece,
        settings: DustSettings,
        sweep: (start: Float, span: Float)
    ) -> Bool {
        let frame = piece.frame
        guard frame.width >= 1, frame.height >= 1 else { return false }
        guard let texture = makeTexture(from: piece.image) else { return false }

        let density = max(settings.density, 0.05)
        var columns = max(1, Int((frame.width * CGFloat(density)).rounded()))
        var rows = max(1, Int((frame.height * CGFloat(density)).rounded()))

        if columns * rows > Self.maximumParticleCount {
            let scale = (Double(Self.maximumParticleCount) / Double(columns * rows)).squareRoot()
            columns = max(1, Int(Double(columns) * scale))
            rows = max(1, Int(Double(rows) * scale))
        }

        guard let particles = device.makeBuffer(length: columns * rows * Self.particleStride,
                                                options: .storageModePrivate) else {
            return false
        }
        particles.label = "DustParticles"

        // Every piece needs its own seed, not one per group. Particle direction
        // is hashed from the seed and the cell index, so two pieces sharing a
        // seed and a grid size scatter identically - and the border's opposite
        // edges are exactly that pair.
        nextSeed += 1

        items.append(Item(texture: texture,
                          frame: frame,
                          columns: columns,
                          rows: rows,
                          particles: particles,
                          settings: settings,
                          seed: nextSeed,
                          sweepStart: sweep.start,
                          sweepSpan: sweep.span))
        return true
    }

    /// Redraws the snapshot into a known BGRA8 premultiplied layout rather than
    /// trusting whatever `CGImage` variant the caller happened to produce.
    private func makeTexture(from image: CGImage) -> MTLTexture? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4

        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                  | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data
        else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: data,
                        bytesPerRow: bytesPerRow)
        return texture
    }

    func removeAllItems() {
        if !items.isEmpty {
            items.removeAll()
            needsFinalClear = true
        }
    }

    // MARK: - Frame

    /// Advances every item and drops the ones that have burned out.
    func advance(deltaTime: Float) {
        guard !items.isEmpty else { return }

        items.removeAll { item in
            item.phase += deltaTime * max(item.settings.speed, 0)
            return item.phase >= item.settings.phaseLifespan
        }

        if items.isEmpty {
            needsFinalClear = true
        }
    }

    /// Draws the current state into a layer's next drawable and presents it.
    func render(in layer: CAMetalLayer, viewSize: CGSize, deltaTime: Float) {
        guard !items.isEmpty || needsFinalClear else { return }
        guard let drawable = layer.nextDrawable() else { return }
        guard let commandBuffer = makeFrameCommandBuffer(target: drawable.texture,
                                                         viewSize: viewSize,
                                                         deltaTime: deltaTime) else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        needsFinalClear = false
    }

    /// Draws the current state into an arbitrary texture and waits for it, so a
    /// test can read the result back.
    func render(into texture: MTLTexture, viewSize: CGSize, deltaTime: Float) {
        guard let commandBuffer = makeFrameCommandBuffer(target: texture,
                                                         viewSize: viewSize,
                                                         deltaTime: deltaTime) else { return }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        needsFinalClear = false
    }

    private func makeFrameCommandBuffer(target: MTLTexture,
                                        viewSize: CGSize,
                                        deltaTime: Float) -> MTLCommandBuffer? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        if !items.isEmpty, let compute = commandBuffer.makeComputeCommandEncoder() {
            for item in items {
                var config = self.config(for: item, deltaTime: deltaTime)
                compute.setBuffer(item.particles, offset: 0, index: 0)
                compute.setBytes(&config, length: MemoryLayout<Config>.stride, index: 1)

                let threadgroupSize = MTLSize(width: 64, height: 1, depth: 1)
                let threadgroups = MTLSize(
                    width: (item.particleCount + threadgroupSize.width - 1) / threadgroupSize.width,
                    height: 1,
                    depth: 1
                )

                if !item.isInitialized {
                    item.isInitialized = true
                    compute.setComputePipelineState(initializePipeline)
                    compute.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
                }

                if config.timeStep > 0 {
                    compute.setComputePipelineState(updatePipeline)
                    compute.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
                }
            }
            compute.endEncoding()
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = target
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
            encoder.setRenderPipelineState(renderPipeline)

            for item in items {
                // The item's slot in the layer, normalized and y-up.
                var rect = SIMD4<Float>(
                    Float(item.frame.minX / viewSize.width),
                    Float((viewSize.height - item.frame.maxY) / viewSize.height),
                    Float(item.frame.width / viewSize.width),
                    Float(item.frame.height / viewSize.height)
                )
                var config = self.config(for: item, deltaTime: deltaTime)

                encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.setVertexBytes(&config, length: MemoryLayout<Config>.stride, index: 1)
                encoder.setVertexBuffer(item.particles, offset: 0, index: 2)
                encoder.setFragmentTexture(item.texture, index: 0)

                encoder.drawPrimitives(type: .triangle,
                                       vertexStart: 0,
                                       vertexCount: 6,
                                       instanceCount: item.particleCount)
            }

            encoder.endEncoding()
        }

        return commandBuffer
    }

    private func config(for item: Item, deltaTime: Float) -> Config {
        let settings = item.settings
        var config = Config()
        config.itemWidth = Float(item.frame.width)
        config.itemHeight = Float(item.frame.height)
        config.gridWidth = Float(item.columns)
        config.gridHeight = Float(item.rows)
        config.gravity = settings.gravity
        config.minSpeed = settings.minSpeed
        config.maxSpeed = settings.maxSpeed
        config.minLifetime = settings.minLifetime
        config.maxLifetime = max(settings.maxLifetime, settings.minLifetime)
        config.waveWidth = settings.waveWidth
        config.waveDuration = settings.waveDuration
        config.fadeDuration = settings.fadeDuration
        config.verticalDirection = settings.driftsUp ? 1 : -1
        config.phase = item.phase
        config.timeStep = deltaTime * max(settings.speed, 0) * DustSettings.simulationSpeedMultiplier
        config.seed = item.seed
        config.sweepStart = item.sweepStart
        config.sweepSpan = item.sweepSpan
        return config
    }
}
