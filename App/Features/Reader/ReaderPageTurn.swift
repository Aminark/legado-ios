import CoreImage.CIFilterBuiltins
import MetalKit
import UIKit

enum ReaderPageTurnStyle: Int {
    case cover, slide, curl
}

/// The moving leaf is always the earlier page. Turning back plays the same
/// geometry in reverse, so the shadow and the print stay on the same sheet.
final class ReaderPageTurnView: UIView {
    let direction: Int
    private let style: ReaderPageTurnStyle
    private let leaf: UIImageView
    private let underneath: UIImageView
    private let edge = CAGradientLayer()
    private let curl: ReaderPaperCurl?
    private let grabHeight: CGFloat
    private var touchHeight: CGFloat
    private(set) var progress: CGFloat = 0
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var startProgress: CGFloat = 0
    private var endProgress: CGFloat = 0
    private var duration: TimeInterval = 0
    private var completion: (() -> Void)?

    init(frame: CGRect, style: ReaderPageTurnStyle, direction: Int, current: UIImage, target: UIImage,
         paper: UIColor, touchHeight: CGFloat) {
        self.style = style
        self.direction = direction
        grabHeight = touchHeight
        self.touchHeight = touchHeight
        let front = direction > 0 ? current : target
        let base = direction > 0 ? target : current
        leaf = UIImageView(image: front)
        underneath = UIImageView(image: base)
        curl = style == .curl ? ReaderPaperCurl(front: front, base: base, paper: paper) : nil
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        underneath.frame = bounds
        leaf.frame = bounds
        leaf.clipsToBounds = false
        addSubview(underneath)
        addSubview(leaf)
        if style == .cover {
            edge.colors = [UIColor.black.withAlphaComponent(0.24).cgColor, UIColor.clear.cgColor]
            edge.startPoint = CGPoint(x: 0, y: 0.5)
            edge.endPoint = CGPoint(x: 1, y: 0.5)
            edge.frame = CGRect(x: bounds.width, y: 0, width: min(24, bounds.width * 0.045), height: bounds.height)
            leaf.layer.addSublayer(edge)
        }
        if let curl {
            curl.frame = bounds
            addSubview(curl)
        }
        update(progress: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(progress: CGFloat, touchHeight: CGFloat? = nil) {
        self.progress = min(1, max(0, progress))
        if let touchHeight { self.touchHeight = touchHeight }
        let fraction = direction > 0 ? self.progress : 1 - self.progress
        if let curl, fraction > 0, fraction < 1 {
            curl.isHidden = false
            // Pulling a lower corner upward (or an upper corner downward)
            // increases the inclination. A horizontal drag near the middle stays straight.
            let inclination = (2 * grabHeight - 1) + (grabHeight - self.touchHeight) * 2.5
            curl.display(fraction: fraction, inclination: inclination)
            return
        }
        curl?.isHidden = true
        leaf.transform = CGAffineTransform(translationX: -bounds.width * fraction, y: 0)
        if style == .slide {
            underneath.transform = CGAffineTransform(translationX: bounds.width * (1 - fraction), y: 0)
        }
    }

    func settle(to end: CGFloat, velocity: CGFloat, completion: @escaping () -> Void) {
        cancelAnimation()
        let remaining = abs(end - progress)
        guard remaining > 0.001 else {
            update(progress: end)
            completion()
            return
        }
        self.completion = completion
        startProgress = progress
        endProgress = end
        startTime = CACurrentMediaTime()
        let baseDuration = style == .curl ? 0.46 : 0.30
        duration = max(0.11, baseDuration * Double(remaining) / max(1, Double(abs(velocity) / bounds.width) * 0.26))
        let link = CADisplayLink(target: self, selector: #selector(advance(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func advance(_ link: CADisplayLink) {
        let t = min(1, max(0, (link.targetTimestamp - startTime) / duration))
        let eased = startProgress == 0 && endProgress == 1 ? t * t * (3 - 2 * t) : 1 - pow(1 - t, 2)
        update(progress: startProgress + (endProgress - startProgress) * eased)
        if t >= 1 {
            let finished = completion
            cancelAnimation()
            finished?()
        }
    }

    func cancelAnimation() {
        link?.invalidate()
        link = nil
        completion = nil
    }
}

/// Core Image bends the front and reverse textures around a cylinder and
/// projects its shadow onto the underlying page. Render straight into the
/// display texture so dragging does not read pixels back from the GPU.
private final class ReaderPaperCurl: UIView, MTKViewDelegate {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    private static let context = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) } ?? CIContext()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let filter = CIFilter.pageCurlWithShadowTransition()
    private let extent: CGRect
    private let surface: MTKView?

    init?(front: UIImage, base: UIImage, paper: UIColor) {
        guard let frontCG = front.cgImage, let baseCG = base.cgImage else { return nil }
        let image = CIImage(cgImage: frontCG)
        extent = image.extent
        if let device = Self.device, Self.queue != nil {
            let surface = MTKView(frame: CGRect(origin: .zero, size: front.size), device: device)
            surface.framebufferOnly = false
            surface.isPaused = true
            surface.autoResizeDrawable = false
            surface.drawableSize = extent.size
            surface.isUserInteractionEnabled = false
            self.surface = surface
        } else {
            surface = nil
        }
        super.init(frame: CGRect(origin: .zero, size: front.size))
        filter.inputImage = image
        filter.targetImage = CIImage(cgImage: baseCG)
        let tint = CIImage(color: CIColor(color: paper.withAlphaComponent(0.82)))
        let reverse = tint.cropped(to: extent).composited(over: image)
        let reflectedLight = CIImage(color: CIColor(red: 1, green: 0.98, blue: 0.94, alpha: 0.085))
        filter.backsideImage = reflectedLight.cropped(to: extent).composited(over: reverse)
        let rect = CIVector(cgRect: extent)
        filter.setValue(rect, forKey: "inputExtent")
        filter.setValue(rect, forKey: "inputShadowExtent")
        filter.shadowAmount = 0.68
        filter.shadowSize = 0.42
        if let surface {
            surface.frame = bounds
            surface.delegate = self
            addSubview(surface)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(fraction: CGFloat, inclination: CGFloat) {
        let tilt = min(0.75, atan(extent.width / extent.height))
        filter.angle = .pi - Float(tilt * min(1, max(-1, inclination)))
        filter.radius = Float(extent.width * (0.05 + 0.055 * sin(.pi * fraction)))
        filter.time = Float(fraction)
        if let surface {
            surface.draw()
        } else if let frame = filter.outputImage {
            layer.contents = Self.context.createCGImage(frame, from: extent)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let frame = filter.outputImage, let drawable = view.currentDrawable,
              let buffer = Self.queue?.makeCommandBuffer() else { return }
        Self.context.render(frame, to: drawable.texture, commandBuffer: buffer, bounds: extent, colorSpace: Self.colorSpace)
        buffer.present(drawable)
        buffer.commit()
    }
}
