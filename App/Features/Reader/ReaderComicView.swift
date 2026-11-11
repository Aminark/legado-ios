import SwiftUI
import UIKit
import ImageIO

/// Reusable rows keep long image chapters from retaining every decoded page.
struct ReaderComicView: UIViewRepresentable {
    let blocks: [ChapterContentBlock]
    let source: BookSource
    let book: Book
    let chapter: BookChapter
    let background: UIColor
    let foreground: UIColor
    let fontSize: CGFloat
    let requestedPosition: Int
    let jumpPosition: Int?
    let onPosition: (Int, Int, Int) -> Void
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITableView {
        let table = ComicTableView(frame: .zero, style: .plain)
        table.accessibilityIdentifier = "reader.comic"
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.register(ComicCell.self, forCellReuseIdentifier: "comic")
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.estimatedRowHeight = 0
        table.isPrefetchingEnabled = false
        table.onWidthChanged = { [weak coordinator = context.coordinator] in coordinator?.resize() }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.delegate = context.coordinator
        table.addGestureRecognizer(tap)
        context.coordinator.table = table
        return table
    }

    func updateUIView(_ table: UITableView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.owner.chapter != chapter || coordinator.owner.blocks != blocks
        let styleChanged = coordinator.owner.fontSize != fontSize || coordinator.owner.foreground != foreground
        coordinator.owner = self
        table.backgroundColor = background
        if changed || !coordinator.configured {
            coordinator.configured = true
            coordinator.restorePosition = requestedPosition
            coordinator.ratios = [:]
            coordinator.lastJump = nil
            coordinator.lastPublished = []
            table.reloadData()
        } else if styleChanged {
            table.reloadData()
        }
        if let jumpPosition, coordinator.lastJump != jumpPosition {
            coordinator.lastJump = jumpPosition
            coordinator.restorePosition = jumpPosition
        } else if jumpPosition == nil {
            coordinator.lastJump = nil
        }
        DispatchQueue.main.async { [weak coordinator] in coordinator?.restore() }
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
        var owner: ReaderComicView
        weak var table: UITableView?
        var configured = false
        var ratios: [Int: CGFloat] = [:]
        var restorePosition: Int?
        var lastJump: Int?
        var lastPublished: [Int] = []
        private let images = NSCache<NSString, UIImage>()

        init(_ owner: ReaderComicView) {
            self.owner = owner
            super.init()
            images.totalCostLimit = 48 * 1024 * 1024
        }

        @objc func tapped() { owner.onTap() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { owner.blocks.count }
        func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            switch owner.blocks[indexPath.row].content {
            case .image:
                return max(100, tableView.bounds.width * (ratios[indexPath.row] ?? 1.4))
            case .text(let text):
                let rect = (text as NSString).boundingRect(with: CGSize(width: max(1, tableView.bounds.width - 32), height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: UIFont.systemFont(ofSize: owner.fontSize)], context: nil)
                return ceil(rect.height) + 24
            }
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "comic", for: indexPath) as! ComicCell
            cell.reset()
            cell.backgroundColor = owner.background
            cell.caption.textColor = owner.foreground
            cell.caption.font = .systemFont(ofSize: owner.fontSize)
            switch owner.blocks[indexPath.row].content {
            case .text(let text): cell.caption.text = text
            case .image(let address):
                let page = owner.blocks.prefix(indexPath.row + 1).filter { if case .image = $0.content { return true }; return false }.count
                cell.picture.accessibilityLabel = "漫画第\(page)张"
                cell.picture.accessibilityIdentifier = "reader.comic.image.\(page)"
                cell.retryIdentifier = "reader.comic.retry.\(page)"
                cell.onRetry = { [weak self, weak cell] in
                    guard let self, let cell else { return }
                    self.load(address, row: indexPath.row, cell: cell)
                }
                load(address, row: indexPath.row, cell: cell)
            }
            return cell
        }

        private func load(_ address: String, row: Int, cell: ComicCell) {
            cell.task?.cancel()
            cell.setRetryVisible(false)
            cell.caption.text = nil
            let source = owner.source, book = owner.book, chapter = owner.chapter
            let key = "\(source.id)|\(chapter.url)|\(address)" as NSString
            if let image = images.object(forKey: key) {
                cell.show(image)
                updateSize(image, row: row)
                return
            }
            cell.spinner.startAnimating()
            cell.task = Task { [weak self, weak cell] in
                do {
                    let data = try await ChapterImageLoader().load(address, source: source, book: book, chapter: chapter)
                    let image = try await Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: 4096,
                                kCGImageSourceShouldCacheImmediately: true
                              ] as CFDictionary) else { throw ChapterImageError.emptyImage }
                        return UIImage(cgImage: decoded)
                    }.value
                    try Task.checkCancellation()
                    guard let self, let cell else { return }
                    guard self.owner.chapter == chapter else { return }
                    self.images.setObject(image, forKey: key, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
                    cell.show(image)
                    self.updateSize(image, row: row)
                } catch {
                    guard !Task.isCancelled, let cell else { return }
                    cell.spinner.stopAnimating()
                    cell.caption.text = "图片加载失败\n\(error.localizedDescription)"
                    cell.setRetryVisible(true)
                }
            }
        }

        private func updateSize(_ image: UIImage, row: Int) {
            let ratio = image.size.height / max(image.size.width, 1)
            guard ratios[row] != ratio else { return }
            ratios[row] = ratio
            // Do not update table geometry from cellForRowAt.
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table else { return }
                let anchor = table.indexPathsForVisibleRows?.first
                let offset = anchor.map { table.contentOffset.y - table.rectForRow(at: $0).minY } ?? 0
                UIView.performWithoutAnimation {
                    table.beginUpdates()
                    table.endUpdates()
                    if let anchor, anchor.row < self.owner.blocks.count, self.restorePosition == nil {
                        table.contentOffset.y = max(0, min(table.rectForRow(at: anchor).minY + offset,
                            max(0, table.contentSize.height - table.bounds.height)))
                    }
                }
                self.restore()
                self.publishPosition()
            }
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            if let cell = cell as? ComicCell, cell.task?.isCancelled == true { cell.onRetry?() }
        }
        func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            DispatchQueue.main.async { [weak tableView, weak cell] in
                guard let cell, tableView?.visibleCells.contains(where: { $0 === cell }) != true else { return }
                (cell as? ComicCell)?.task?.cancel()
            }
        }
        func resize() {
            guard let table else { return }
            let position = restorePosition ?? lastPublished.first ?? owner.requestedPosition
            table.reloadData()
            restorePosition = position
            restore()
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { restorePosition = nil }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard restorePosition == nil else { return }
            publishPosition()
        }
        func restore() {
            guard let table, table.bounds.width > 0, let position = restorePosition, !owner.blocks.isEmpty else { return }
            let row = owner.blocks.lastIndex(where: { $0.range.location <= position }) ?? 0
            table.layoutIfNeeded()
            let range = owner.blocks[row].range
            let fraction = min(max(CGFloat(position - range.location) / CGFloat(max(range.length, 1)), 0), 0.999)
            let rect = table.rectForRow(at: IndexPath(row: row, section: 0))
            table.setContentOffset(CGPoint(x: 0, y: min(rect.minY + rect.height * fraction,
                max(0, table.contentSize.height - table.bounds.height))), animated: false)
            publishPosition()
        }
        private func publishPosition() {
            guard let table, let row = table.indexPathForRow(at: CGPoint(x: 1, y: table.contentOffset.y + 1))?.row,
                  owner.blocks.indices.contains(row) else { return }
            let rect = table.rectForRow(at: IndexPath(row: row, section: 0))
            let range = owner.blocks[row].range
            let fraction = min(max((table.contentOffset.y - rect.minY) / max(rect.height, 1), 0), 0.999)
            let position = range.location + Int(CGFloat(range.length) * fraction)
            let images = owner.blocks.enumerated().filter { if case .image = $0.element.content { return true }; return false }
            let page = max(1, images.filter { $0.offset <= row }.count)
            let values = [position, page, images.count]
            guard lastPublished != values else { return }
            lastPublished = values
            let chapter = owner.chapter
            let callback = owner.onPosition
            DispatchQueue.main.async { [weak self] in
                guard self?.owner.chapter == chapter else { return }
                callback(position, page, images.count)
            }
        }
    }
}

private final class ComicCell: UITableViewCell {
    let picture = UIImageView()
    let caption = UILabel()
    let spinner = UIActivityIndicatorView(style: .medium)
    let retry = UIButton(type: .system)
    var task: Task<Void, Never>?
    var onRetry: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        picture.contentMode = .scaleAspectFit
        picture.isAccessibilityElement = true
        caption.numberOfLines = 0
        caption.textAlignment = .center
        retry.setTitle("重试图片", for: .normal)
        retry.addTarget(self, action: #selector(retryImage), for: .touchUpInside)
        for view in [picture, caption, spinner, retry] { contentView.addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        picture.frame = contentView.bounds
        caption.frame = contentView.bounds.insetBy(dx: 16, dy: 12)
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        retry.frame = CGRect(x: 20, y: max(0, bounds.height - 56), width: bounds.width - 40, height: 44)
    }
    override func prepareForReuse() { super.prepareForReuse(); reset() }
    func reset() {
        task?.cancel(); task = nil; onRetry = nil
        picture.image = nil; picture.isHidden = true
        caption.text = nil; setRetryVisible(false); spinner.stopAnimating()
    }
    func show(_ image: UIImage) {
        picture.image = image; picture.isHidden = false
        caption.text = nil; setRetryVisible(false); spinner.stopAnimating()
    }
    func setRetryVisible(_ visible: Bool) {
        retry.isHidden = !visible
        retry.isAccessibilityElement = visible
        retry.accessibilityElementsHidden = !visible
        retry.accessibilityIdentifier = visible ? retryIdentifier : nil
    }
    var retryIdentifier: String?
    @objc private func retryImage() { onRetry?() }
}

private final class ComicTableView: UITableView {
    var onWidthChanged: (() -> Void)?
    private var lastWidth: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        DispatchQueue.main.async { [weak self] in self?.onWidthChanged?() }
    }
}
