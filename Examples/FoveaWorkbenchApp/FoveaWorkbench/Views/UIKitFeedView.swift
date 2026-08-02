import FoveaCore
import FoveaUIKit
import ImageCraftCore
import SwiftUI
import UIKit

enum WorkbenchFeedHost: String, CaseIterable, Identifiable {
    case swiftUI
    case uiKit

    var id: String { rawValue }
    var title: String { self == .swiftUI ? "SwiftUI" : "UIKit" }
}

struct UIKitFeedScrollCommand: Equatable {
    enum Anchor: Equatable {
        case top
        case center
        case bottom
    }

    let generation: Int
    let item: Int
    let anchor: Anchor
}

/// 将同一 Feed 工作负载接入 UICollectionView，用于比较宿主生命周期与复用。
/// Cell 重用时必须先取消旧订阅，再以稳定资源身份绑定新请求。
struct UIKitFeedView: UIViewControllerRepresentable {
    let items: [WorkbenchFeedItem]
    let layout: WorkbenchFeedLayout
    let pipeline: FoveaPipeline?
    let configuration: WorkbenchConfiguration
    let revision: String
    let scrollCommand: UIKitFeedScrollCommand?

    func makeUIViewController(context: Context) -> WorkbenchFeedCollectionViewController {
        WorkbenchFeedCollectionViewController(
            items: items,
            layout: layout,
            pipeline: pipeline,
            configuration: configuration,
            revision: revision
        )
    }

    func updateUIViewController(
        _ controller: WorkbenchFeedCollectionViewController,
        context: Context
    ) {
        controller.update(
            items: items,
            layout: layout,
            pipeline: pipeline,
            configuration: configuration,
            revision: revision
        )
        controller.apply(scrollCommand: scrollCommand)
    }
}

@MainActor
final class WorkbenchFeedCollectionViewController: UICollectionViewController,
    UICollectionViewDelegateFlowLayout
{
    private var items: [WorkbenchFeedItem]
    private var feedLayout: WorkbenchFeedLayout
    private var pipeline: FoveaPipeline?
    private var configuration: WorkbenchConfiguration
    private var revision: String
    private var lastScrollCommandGeneration: Int?

    init(
        items: [WorkbenchFeedItem],
        layout: WorkbenchFeedLayout,
        pipeline: FoveaPipeline?,
        configuration: WorkbenchConfiguration,
        revision: String
    ) {
        self.items = items
        self.feedLayout = layout
        self.pipeline = pipeline
        self.configuration = configuration
        self.revision = revision
        super.init(collectionViewLayout: Self.makeLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.register(
            WorkbenchFeedCollectionCell.self,
            forCellWithReuseIdentifier: WorkbenchFeedCollectionCell.reuseIdentifier
        )
        collectionView.accessibilityIdentifier = "feed.uikit.collection"
    }

    func update(
        items: [WorkbenchFeedItem],
        layout: WorkbenchFeedLayout,
        pipeline: FoveaPipeline?,
        configuration: WorkbenchConfiguration,
        revision: String
    ) {
        let requiresReload =
            self.items != items
            || feedLayout != layout
            || self.revision != revision
            || self.configuration != configuration
            || self.pipeline?.id != pipeline?.id

        self.items = items
        self.pipeline = pipeline
        self.configuration = configuration
        self.revision = revision

        if feedLayout != layout {
            feedLayout = layout
            collectionView.collectionViewLayout.invalidateLayout()
        }
        if requiresReload { collectionView.reloadData() }
    }

    func apply(scrollCommand: UIKitFeedScrollCommand?) {
        guard let scrollCommand,
            lastScrollCommandGeneration != scrollCommand.generation,
            !items.isEmpty
        else { return }
        lastScrollCommandGeneration = scrollCommand.generation
        let index = min(items.count - 1, max(0, scrollCommand.item))
        let position: UICollectionView.ScrollPosition
        switch scrollCommand.anchor {
        case .top:
            position = .top
        case .center:
            position = .centeredVertically
        case .bottom:
            position = .bottom
        }
        collectionView.scrollToItem(
            at: IndexPath(item: index, section: 0),
            at: position,
            animated: false
        )
    }

    override func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

    override func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        items.count
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: WorkbenchFeedCollectionCell.reuseIdentifier,
                for: indexPath
            ) as? WorkbenchFeedCollectionCell
        else {
            return UICollectionViewCell()
        }
        cell.configure(
            item: items[indexPath.item],
            layout: feedLayout,
            pipeline: pipeline,
            configuration: configuration,
            revision: revision
        )
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = collectionView.bounds.width - 24
        switch feedLayout {
        case .list:
            return CGSize(width: max(1, width), height: 112)
        case .grid:
            let columnWidth = max(140, (width - 12) / 2)
            return CGSize(width: columnWidth, height: 190)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        insetForSectionAt section: Int
    ) -> UIEdgeInsets {
        UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    }

    private static func makeLayout() -> UICollectionViewFlowLayout {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 12
        return layout
    }
}

@MainActor
private final class WorkbenchFeedCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "WorkbenchFeedCollectionCell"

    private let foveaImageView = FoveaImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let textStack = UIStackView()
    private var horizontalConstraints: [NSLayoutConstraint] = []
    private var verticalConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        foveaImageView.prepareForReuse()
        accessibilityIdentifier = nil
        titleLabel.text = nil
        detailLabel.text = nil
    }

    func configure(
        item: WorkbenchFeedItem,
        layout: WorkbenchFeedLayout,
        pipeline: FoveaPipeline?,
        configuration: WorkbenchConfiguration,
        revision: String
    ) {
        accessibilityIdentifier = "feed.uikit.cell.\(item.id)"
        titleLabel.text = "Cell \(item.id)"
        detailLabel.text =
            "asset-\(item.assetID) · \(item.expectedVariantTitle) · \(item.delayMilliseconds) ms"
        apply(layout: layout)

        guard let pipeline else {
            foveaImageView.image = nil
            detailLabel.text = "图片管线尚未就绪"
            return
        }

        do {
            let target = try TargetPixels(
                width: layout == .list ? 264 : 320,
                height: layout == .list ? 176 : 240
            )
            let request = try WorkbenchRequestFactory.makeFeedRequest(
                item: item,
                target: target,
                configuration: configuration,
                identityRevision: revision
            )
            foveaImageView.contentMode =
                configuration.contentMode == .fit
                ? .scaleAspectFit : .scaleAspectFill
            foveaImageView.setImage(
                request: request,
                loader: pipeline,
                accessibility: .label("Cell \(item.id)，预期\(item.expectedVariantTitle)图片"),
                retention: .retainSuccessfulImageUntilReplacement
            )
        } catch {
            foveaImageView.image = nil
            detailLabel.text = "request-validation-failed"
        }
    }

    private func configureViewHierarchy() {
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        foveaImageView.translatesAutoresizingMaskIntoConstraints = false
        foveaImageView.clipsToBounds = true
        foveaImageView.backgroundColor = .tertiarySystemFill

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.textColor = .secondaryLabel
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.numberOfLines = 2

        textStack.axis = .vertical
        textStack.spacing = 5
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)

        contentView.addSubview(foveaImageView)
        contentView.addSubview(textStack)

        horizontalConstraints = [
            foveaImageView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 10),
            foveaImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            foveaImageView.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -10),
            foveaImageView.widthAnchor.constraint(equalToConstant: 132),
            textStack.leadingAnchor.constraint(
                equalTo: foveaImageView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ]
        verticalConstraints = [
            foveaImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            foveaImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            foveaImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            foveaImageView.heightAnchor.constraint(
                equalTo: contentView.heightAnchor, multiplier: 0.68),
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            textStack.topAnchor.constraint(equalTo: foveaImageView.bottomAnchor, constant: 7),
            textStack.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor, constant: -7),
        ]
    }

    private func apply(layout: WorkbenchFeedLayout) {
        NSLayoutConstraint.deactivate(horizontalConstraints + verticalConstraints)
        NSLayoutConstraint.activate(layout == .list ? horizontalConstraints : verticalConstraints)
    }
}
