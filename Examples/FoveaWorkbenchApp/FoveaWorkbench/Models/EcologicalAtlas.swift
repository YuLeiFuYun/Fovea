import Foundation

/// 生态超载大众叙事的当前内容契约。
///
/// 该模型不承担学术综合报告的职责，而是把专题、证据、争议、图片负载和来源追踪
/// 组织成可机器校验的数据。schema 只接受当前版本；旧内容必须先迁移再进入 App。
struct EcologicalAtlasDocument: Decodable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let title: String
    let deck: String
    let reviewedAt: String
    let editorialPrinciples: [String]
    let mediaPolicy: EcologicalMediaPolicy
    let sources: [EcologicalSource]
    let volumes: [EcologicalVolume]
    let stories: [EcologicalStory]
    let featuredStoryIDs: [String]
    let caseStudyStoryIDs: [String]
    let glossary: [EcologicalGlossaryEntry]

    static let current: EcologicalAtlasDocument = {
        guard
            let url = Bundle.main.url(forResource: "ecological-atlas", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let document = try? JSONDecoder().decode(Self.self, from: data),
            document.schemaVersion == Self.currentSchemaVersion,
            !document.volumes.isEmpty,
            !document.stories.isEmpty
        else {
            preconditionFailure("生态图谱缺失、损坏或 schema 不是当前版本")
        }
        return document
    }()

    var sourcesByID: [String: EcologicalSource] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    }

    var storiesByID: [String: EcologicalStory] {
        Dictionary(uniqueKeysWithValues: stories.map { ($0.id, $0) })
    }

    func stories(in volume: EcologicalVolume) -> [EcologicalStory] {
        volume.storyIDs.compactMap { storiesByID[$0] }
    }
}

struct EcologicalMediaPolicy: Decodable, Hashable {
    let principle: String
    let contextualTopics: [String]
    let requiredChecks: [String]
    let prohibitedUses: [String]
}

struct EcologicalSource: Decodable, Identifiable, Hashable {
    let id: String
    let organization: String
    let title: String
    let year: Int
    let url: URL
    let sourceClass: EcologicalSourceClass
}

enum EcologicalSourceClass: String, Decodable, CaseIterable {
    case intergovernmentalAssessment
    case officialAssessment
    case officialGuidance
    case peerReviewedResearch
    case theoreticalResearch
    case legalPolicy
    case foundationalText

    var title: String {
        switch self {
        case .intergovernmentalAssessment: "政府间评估"
        case .officialAssessment: "官方评估"
        case .officialGuidance: "官方指南"
        case .peerReviewedResearch: "同行评审研究"
        case .theoreticalResearch: "理论研究"
        case .legalPolicy: "法律与政策"
        case .foundationalText: "基础文本"
        }
    }
}

struct EcologicalVolume: Decodable, Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    let subtitle: String
    let summary: String
    let storyIDs: [String]
}

struct EcologicalStory: Decodable, Identifiable, Hashable {
    let id: String
    let volumeID: String
    let eyebrow: String
    let title: String
    let summary: String
    let readingMinutes: Int
    let epistemicStatus: EcologicalEpistemicStatus
    let layout: EcologicalStoryLayout
    let heroAssetID: String
    let galleryAssetIDs: [String]
    let mechanism: String
    let distribution: String
    let debate: EcologicalDebate
    let claims: [EcologicalClaim]
    let metrics: [EcologicalMetric]
    let timeline: [EcologicalTimelineEvent]
    let questions: [String]
    let imageScenario: EcologicalImageScenario
}

enum EcologicalStoryLayout: String, Decodable, CaseIterable {
    case editorial
    case mosaic
    case timeline
    case comparison
    case atlas
    case dossier
    case fieldNotes
    case immersive

    var title: String {
        switch self {
        case .editorial: "长文导览"
        case .mosaic: "图像拼贴"
        case .timeline: "时间线"
        case .comparison: "对照阅读"
        case .atlas: "图谱网格"
        case .dossier: "资料档案"
        case .fieldNotes: "田野札记"
        case .immersive: "沉浸叙事"
        }
    }
}

struct EcologicalDebate: Decodable, Hashable {
    let proposition: String
    let challenge: String
    let synthesis: String
}

struct EcologicalClaim: Decodable, Identifiable, Hashable {
    let id: String
    let text: String
    let sourceIDs: [String]
}

struct EcologicalMetric: Decodable, Identifiable, Hashable {
    let id: String
    let value: String
    let label: String
    let context: String
    let sourceIDs: [String]
}

struct EcologicalTimelineEvent: Decodable, Identifiable, Hashable {
    let id: String
    let marker: String
    let title: String
    let body: String
    let assetID: String?
    let sourceIDs: [String]
}

struct EcologicalImageScenario: Decodable, Hashable {
    let name: String
    let sourceMix: String
    let targetVariants: [String]
    let interactions: [String]
    let expectedBehaviors: [String]
}

struct EcologicalGlossaryEntry: Decodable, Identifiable, Hashable {
    let id: String
    let term: String
    let definition: String
    let relatedStoryIDs: [String]
}

enum EcologicalEpistemicStatus: String, Decodable, CaseIterable {
    case assessedConsensus
    case observedSynthesis
    case modelledScenario
    case interpretiveLens
    case normativePosition
    case contestedEvidence

    var title: String {
        switch self {
        case .assessedConsensus: "评估共识"
        case .observedSynthesis: "观测综合"
        case .modelledScenario: "模型与情景"
        case .interpretiveLens: "理论镜头"
        case .normativePosition: "规范性立场"
        case .contestedEvidence: "证据争议"
        }
    }

    var explanation: String {
        switch self {
        case .assessedConsensus:
            "由跨学科或政府间评估综合大量研究；共识不等于每个局部参数都确定。"
        case .observedSynthesis:
            "主要概括观测、统计和案例；结论受口径、覆盖范围和数据质量限制。"
        case .modelledScenario:
            "用于比较条件化路径，不是对唯一未来的预言。"
        case .interpretiveLens:
            "用于组织因果和权力问题的理论框架，应与竞争解释和反例共同阅读。"
        case .normativePosition:
            "关于权利、责任和应然秩序的价值判断，不伪装成自然定律。"
        case .contestedEvidence:
            "相关机制或规模仍有实质争论，页面同时呈现支持证据、反例和未知。"
        }
    }
}
