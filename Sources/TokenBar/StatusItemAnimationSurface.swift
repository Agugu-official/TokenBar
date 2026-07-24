/*
 StatusItemAnimationSurface.swift
 TokenBar

 Adapted and modified for TokenBar from RunCat Neo's status-item rendering
 architecture.

 Copyright 2026 Kyome22 (Takuto Nakamura)
 Copyright 2026 Nanako

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import AppKit
import CoreImage.CIFilterBuiltins
import QuartzCore

private let tokenBarStatusButtonMarker = 0x5442_4152 // "TBAR"

@MainActor
final class StatusItemAnimationSurface {
    private weak var button: NSStatusBarButton?
    private let cutoutLayer = StatusItemStaticCutoutLayer()
    private let runnerLayer = StatusItemRunnerLayer()
    private var layoutTask: Task<Void, Never>?
    private var layoutGeneration = 0
    private var appearanceRegistration = 0
    private var isAnimated = false
    private var tornDown = false

    var onAppearanceChange: (() -> Void)?

    init(button: NSStatusBarButton) {
        self.button = button
        button.wantsLayer = true
        cutoutLayer.isHidden = true
        runnerLayer.isHidden = true
        button.layer?.addSublayer(cutoutLayer)
        button.layer?.addSublayer(runnerLayer)
        appearanceRegistration = StatusButtonAppearanceRouter.shared.register(
            button: button, surface: self)
        updateAppearance(button.effectiveAppearance)
    }

    func showAnimated(frames: [NSImage], speed: Float) {
        guard !tornDown, let button, let first = frames.first else { return }
        layoutGeneration += 1
        layoutTask?.cancel()
        cutoutLayer.isHidden = true
        runnerLayer.isHidden = true
        runnerLayer.stop()

        let staticImage = first.copy() as? NSImage ?? first
        staticImage.size = first.size
        staticImage.isTemplate = true
        staticImage.accessibilityDescription = "TokenBar"
        button.image = staticImage
        button.layoutSubtreeIfNeeded()

        let animationFrames = frames.map { frame -> NSImage in
            let image = frame.copy() as? NSImage ?? frame
            image.size = frame.size
            image.isTemplate = false
            return image
        }
        runnerLayer.setFrames(animationFrames, speed: speed)
        updateAppearance(button.effectiveAppearance)
        isAnimated = true
        scheduleLayout()
    }

    func setSpeed(_ speed: Float) {
        guard !tornDown, isAnimated else { return }
        runnerLayer.setSpeed(speed)
    }

    func showStatic(_ image: NSImage, isTemplate: Bool) {
        guard !tornDown, let button else { return }
        layoutGeneration += 1
        layoutTask?.cancel()
        isAnimated = false
        runnerLayer.stop()
        runnerLayer.isHidden = true
        cutoutLayer.isHidden = true

        let staticImage = image.copy() as? NSImage ?? image
        staticImage.size = image.size
        staticImage.isTemplate = isTemplate
        staticImage.accessibilityDescription = "TokenBar"
        button.image = staticImage
        button.layoutSubtreeIfNeeded()
    }

    func stopAnimation() {
        guard !tornDown else { return }
        layoutGeneration += 1
        layoutTask?.cancel()
        isAnimated = false
        runnerLayer.stop()
        runnerLayer.isHidden = true
        cutoutLayer.isHidden = true
    }

    func scheduleLayout() {
        guard !tornDown, isAnimated else { return }
        layoutGeneration += 1
        let generation = layoutGeneration
        layoutTask?.cancel()
        layoutTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled,
                  !self.tornDown, self.isAnimated,
                  generation == self.layoutGeneration,
                  let button = self.button
            else { return }
            button.layoutSubtreeIfNeeded()
            guard let rect = button.cell?.imageRect(forBounds: button.bounds),
                  rect.width > 0, rect.height > 0
            else { return }
            let scale = button.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2
            self.cutoutLayer.update(frame: rect, contentsScale: scale)
            self.runnerLayer.update(frame: rect)
            self.cutoutLayer.isHidden = false
            self.runnerLayer.isHidden = false
        }
    }

    func updateAppearance(_ appearance: NSAppearance? = nil) {
        guard !tornDown else { return }
        let appearance = appearance ?? button?.effectiveAppearance ?? NSApp.effectiveAppearance
        var tint = NSColor.textColor.cgColor
        appearance.performAsCurrentDrawingAppearance {
            tint = NSColor.textColor.cgColor
        }
        runnerLayer.setColor(tint)
    }

    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        layoutGeneration += 1
        layoutTask?.cancel()
        layoutTask = nil
        onAppearanceChange = nil
        if let button {
            StatusButtonAppearanceRouter.shared.unregister(
                button: button, generation: appearanceRegistration)
        }
        appearanceRegistration = 0
        runnerLayer.stop()
        runnerLayer.removeFromSuperlayer()
        cutoutLayer.backgroundFilters = nil
        cutoutLayer.removeFromSuperlayer()
    }

    fileprivate func buttonAppearanceDidChange(_ button: NSStatusBarButton) {
        guard !tornDown, self.button === button else { return }
        updateAppearance(button.effectiveAppearance)
        scheduleLayout()
        onAppearanceChange?()
    }
}

private final class StatusItemStaticCutoutLayer: CALayer {
    override init() {
        super.init()
        contentsGravity = .left
        masksToBounds = true
        contentsScale = 2
        let filter = CIFilter.sourceOutCompositing()
        let rect = CGRect(x: 0, y: 0, width: 600, height: 22)
        filter.backgroundImage = CIImage(color: CIColor.blue).cropped(to: rect)
        backgroundFilters = [filter]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(frame: CGRect, contentsScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        self.contentsScale = contentsScale
        CATransaction.commit()
    }
}

private final class StatusItemRunnerLayer: CALayer {
    private static let frameSize = NSSize(width: 18, height: 18)

    private var frameMasks: [CGImage] = []
    private var frames: [CGImage] = []
    private var frameIndex = 0
    private var frameTimer: DispatchSourceTimer?
    private var frameInterval = 0.5
    private var tintColor = NSColor.textColor.cgColor

    override init() {
        super.init()
        contentsGravity = .left
        masksToBounds = true
        contentsScale = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func rasterizedFrame(_ source: NSImage) -> CGImage? {
        let canvasSize = frameSize
        guard let sourceRep = source.representations.max(by: {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }), sourceRep.pixelsWide > 0, sourceRep.pixelsHigh > 0 else { return nil }
        let sourceSize = NSSize(
            width: sourceRep.pixelsWide,
            height: sourceRep.pixelsHigh)
        let fit = min(
            canvasSize.width / sourceSize.width,
            canvasSize.height / sourceSize.height)
        let drawSize = NSSize(
            width: (sourceSize.width * fit).rounded(),
            height: (sourceSize.height * fit).rounded())
        let drawRect = NSRect(
            x: ((canvasSize.width - drawSize.width) / 2).rounded(.down),
            y: ((canvasSize.height - drawSize.height) / 2).rounded(.down),
            width: drawSize.width,
            height: drawSize.height)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSize.width),
            pixelsHigh: Int(canvasSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = canvasSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: nil)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private static func tintedFrame(_ mask: CGImage, color: CGColor) -> CGImage? {
        let size = frameSize
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = size
        let cgContext = context.cgContext
        cgContext.setFillColor(color)
        cgContext.fill(CGRect(origin: .zero, size: size))
        cgContext.setBlendMode(.destinationIn)
        cgContext.draw(mask, in: CGRect(origin: .zero, size: size))
        context.flushGraphics()
        return rep.cgImage
    }

    private func applyTint() {
        let tinted = frameMasks.compactMap {
            Self.tintedFrame($0, color: tintColor)
        }
        guard tinted.count == frameMasks.count else { return }
        frames = tinted
        guard frames.indices.contains(frameIndex) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents = frames[frameIndex]
        CATransaction.commit()
    }

    func setFrames(_ images: [NSImage], speed: Float) {
        guard !images.isEmpty else { return }
        let values = images.compactMap(Self.rasterizedFrame)
        guard values.count == images.count else { return }
        frameMasks = values
        frameIndex = 0
        applyTint()
        setSpeed(speed)
    }

    func setSpeed(_ speed: Float) {
        guard !frames.isEmpty else { return }
        let interval = 0.5 / Double(max(speed, 1))
        guard frameTimer == nil || abs(interval - frameInterval) > 0.000_001 else { return }
        frameInterval = interval
        frameTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, !self.frames.isEmpty else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frames.count
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.contents = self.frames[self.frameIndex]
            CATransaction.commit()
        }
        frameTimer = timer
        timer.resume()
    }

    func setColor(_ color: CGColor) {
        tintColor = color
        applyTint()
    }

    func update(frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        contentsScale = 1
        CATransaction.commit()
    }

    func stop() {
        frameTimer?.cancel()
        frameTimer = nil
        frameMasks = []
        frames = []
        frameIndex = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents = nil
        CATransaction.commit()
    }
}

@MainActor
private final class StatusButtonAppearanceRouter {
    static let shared = StatusButtonAppearanceRouter()

    private weak var button: NSStatusBarButton?
    private weak var surface: StatusItemAnimationSurface?
    private var generation = 0

    func register(
        button: NSStatusBarButton,
        surface: StatusItemAnimationSurface
    ) -> Int {
        generation += 1
        self.button = button
        self.surface = surface
        button.tag = tokenBarStatusButtonMarker
        return generation
    }

    func unregister(button: NSStatusBarButton, generation: Int) {
        guard self.button === button, self.generation == generation else { return }
        button.tag = 0
        self.button = nil
        surface = nil
    }

    func send(_ button: NSStatusBarButton) {
        guard button.tag == tokenBarStatusButtonMarker,
              self.button === button,
              let surface
        else { return }
        surface.buttonAppearanceDidChange(button)
    }
}

extension NSStatusBarButton {
    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard tag == tokenBarStatusButtonMarker else { return }
        MainActor.assumeIsolated {
            StatusButtonAppearanceRouter.shared.send(self)
        }
    }
}
