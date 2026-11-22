import AgentMemoryCore
import SwiftUI

// MARK: - Deterministic Cluster Layout Engine

struct GalaxyLayoutSnapshot {
    let positions: [String: CGPoint]       // normalized in [-1, 1] x [-1, 1]
    let clusterCenters: [(key: String, label: String, isGlobal: Bool, center: CGPoint, count: Int)]

    static func compute(graph: MemoryGraph) -> GalaxyLayoutSnapshot {
        let nodes = graph.nodes
        guard !nodes.isEmpty else {
            return GalaxyLayoutSnapshot(positions: [:], clusterCenters: [])
        }

        // Group by scope/project deterministically
        var grouped: [String: [MemoryGraphNode]] = [:]
        for node in nodes {
            let key = (node.scope == "global" || node.project == nil || node.project?.isEmpty == true)
                ? "__global__"
                : (node.project ?? "__global__")
            grouped[key, default: []].append(node)
        }

        let sortedKeys = grouped.keys.sorted { a, b in
            if a == "__global__" { return true }
            if b == "__global__" { return false }
            let countA = grouped[a]?.count ?? 0
            let countB = grouped[b]?.count ?? 0
            if countA != countB { return countA > countB }
            return a < b
        }

        // Assign cluster centers: global at center (if present), projects arranged around an ellipse
        var clusterMap: [String: CGPoint] = [:]
        var clusterMeta: [(key: String, label: String, isGlobal: Bool, center: CGPoint, count: Int)] = []
        let projectKeys = sortedKeys.filter { $0 != "__global__" }

        if let globalNodes = grouped["__global__"] {
            let center: CGPoint = projectKeys.isEmpty ? .zero : CGPoint(x: 0, y: 0)
            clusterMap["__global__"] = center
            clusterMeta.append(("__global__", "全局记忆", true, center, globalNodes.count))
        }

        let projectCount = projectKeys.count
        for (idx, key) in projectKeys.enumerated() {
            let angle = (Double(idx) / Double(max(projectCount, 1))) * (.pi * 2) - .pi / 2
            let rx: Double = projectCount == 1 ? 0.42 : 0.62
            let ry: Double = projectCount == 1 ? 0.25 : 0.56
            let cx = cos(angle) * rx
            let cy = sin(angle) * ry
            let center = CGPoint(x: cx, y: cy)
            clusterMap[key] = center
            let label = URL(fileURLWithPath: key).lastPathComponent
            clusterMeta.append((key, label.isEmpty ? key : label, false, center, grouped[key]?.count ?? 0))
        }

        // Initial deterministic spiral placement within each cluster
        var pos: [String: CGPoint] = [:]
        let goldenAngle = Double.pi * (3.0 - sqrt(5.0))
        for key in sortedKeys {
            guard let clusterNodes = grouped[key], let center = clusterMap[key] else { continue }
            let ordered = clusterNodes.sorted {
                if $0.hitCount != $1.hitCount { return $0.hitCount > $1.hitCount }
                if $0.updated != $1.updated { return $0.updated > $1.updated }
                return $0.id < $1.id
            }
            let spread: Double = sortedKeys.count <= 1 ? 0.68 : 0.28
            for (i, node) in ordered.enumerated() {
                if i == 0 && ordered.count == 1 {
                    pos[node.id] = center
                } else {
                    let frac = sqrt(Double(i + 1) / Double(ordered.count + 1))
                    let jitter = (stableUnitHash(node.id) - 0.5) * 0.22
                    let theta = Double(i) * goldenAngle + jitter
                    let r = spread * frac
                    pos[node.id] = CGPoint(
                        x: center.x + cos(theta) * r * 1.15,
                        y: center.y + sin(theta) * r * 0.95
                    )
                }
            }
        }

        // Lightweight deterministic force relaxation (keeps clusters cohesive & prevents node overlap)
        let nodeIDs = nodes.map(\.id)
        let nodeCount = nodeIDs.count
        let iterations = nodeCount > 180 ? 12 : 22
        let minDistance: Double = nodeCount > 150 ? 0.065 : 0.095
        var coords = nodeIDs.map { pos[$0] ?? .zero }
        let idToIndex = Dictionary(uniqueKeysWithValues: nodeIDs.enumerated().map { ($0.element, $0.offset) })
        let anchorByIndex: [CGPoint] = nodes.map { node in
            let key = (node.scope == "global" || node.project == nil || node.project?.isEmpty == true)
                ? "__global__" : (node.project ?? "__global__")
            return clusterMap[key] ?? .zero
        }

        let edgePairs: [(Int, Int, Double)] = graph.edges.compactMap { edge in
            guard let a = idToIndex[edge.sourceID], let b = idToIndex[edge.targetID] else { return nil }
            let strength: Double = switch edge.kind {
            case .duplicate: 0.09
            case .semantic: 0.035 * max(edge.weight, 0.3)
            case .sharedEvidence: 0.025
            }
            return (a, b, strength)
        }

        for _ in 0..<iterations {
            var disp = Array(repeating: CGPoint.zero, count: nodeCount)

            // Pairwise short-range repulsion
            for i in 0..<nodeCount {
                for j in (i + 1)..<nodeCount {
                    let dx = coords[i].x - coords[j].x
                    let dy = coords[i].y - coords[j].y
                    let distSq = dx * dx + dy * dy
                    if distSq < minDistance * minDistance {
                        let dist = max(sqrt(distSq), 0.002)
                        let push = (minDistance - dist) * 0.35 / dist
                        let fx = dx * push
                        let fy = dy * push
                        disp[i].x += fx
                        disp[i].y += fy
                        disp[j].x -= fx
                        disp[j].y -= fy
                    }
                }
            }

            // Edge attraction
            for (a, b, strength) in edgePairs {
                let dx = coords[b].x - coords[a].x
                let dy = coords[b].y - coords[a].y
                disp[a].x += dx * strength
                disp[a].y += dy * strength
                disp[b].x -= dx * strength
                disp[b].y -= dy * strength
            }

            // Gentle gravity toward cluster anchor
            for i in 0..<nodeCount {
                disp[i].x += (anchorByIndex[i].x - coords[i].x) * 0.08
                disp[i].y += (anchorByIndex[i].y - coords[i].y) * 0.08
                coords[i].x = min(max(coords[i].x + disp[i].x * 0.5, -0.94), 0.94)
                coords[i].y = min(max(coords[i].y + disp[i].y * 0.5, -0.92), 0.92)
            }
        }

        var finalPositions: [String: CGPoint] = [:]
        for (index, id) in nodeIDs.enumerated() {
            finalPositions[id] = coords[index]
        }

        return GalaxyLayoutSnapshot(positions: finalPositions, clusterCenters: clusterMeta)
    }

    private static func stableUnitHash(_ value: String) -> Double {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return Double(hash % 10_000) / 10_000.0
    }
}

// MARK: - Galaxy Filters & View State

private enum GalaxyScopeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case global = "仅全局"
    case project = "仅项目"

    var id: Self { self }
}

@MainActor
private final class GalaxyUIState: ObservableObject {
    @Published var scopeFilter: GalaxyScopeFilter = .all
    @Published var selectedProject: String? = nil
    @Published var showSemanticEdges = true
    @Published var showDuplicateEdges = true
    @Published var showSharedEvidenceEdges = true
    @Published var hideDormant = false
    @Published var searchText = ""

    @Published var scale: CGFloat = 1.0
    @Published var offset: CGSize = .zero
    @Published var dragTranslation: CGSize = .zero
    @Published var pinchMagnification: CGFloat = 1.0

    @Published var hoveredNodeID: String? = nil
    @Published var hoverLocation: CGPoint = .zero
    @Published var canvasSize: CGSize = CGSize(width: 800, height: 520)

    @Published var layout: GalaxyLayoutSnapshot = GalaxyLayoutSnapshot(positions: [:], clusterCenters: [])
    var layoutSignature: String = ""
}

// MARK: - Interactive Semantic Memory Galaxy View

struct MemoryGalaxyView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    let onSelectMemoryID: (String) -> Void

    @StateObject private var ui = GalaxyUIState()

    private let pulseDuration: TimeInterval = 3.6

    private var knownProjects: [String] {
        Array(Set(model.memoryGraph.nodes.compactMap(\.project).filter { !$0.isEmpty })).sorted()
    }

    private var visibleNodes: [MemoryGraphNode] {
        model.memoryGraph.nodes.filter { node in
            if ui.hideDormant && node.isDormant { return false }
            switch ui.scopeFilter {
            case .all:
                return true
            case .global:
                return node.scope == "global" || node.project == nil
            case .project:
                guard let project = node.project, !project.isEmpty else { return false }
                if let selectedProject = ui.selectedProject {
                    return project == selectedProject
                }
                return true
            }
        }
    }

    private var visibleNodeIDs: Set<String> {
        Set(visibleNodes.map(\.id))
    }

    private var visibleEdges: [MemoryGraphEdge] {
        let ids = visibleNodeIDs
        return model.memoryGraph.edges.filter { edge in
            guard ids.contains(edge.sourceID), ids.contains(edge.targetID) else { return false }
            switch edge.kind {
            case .semantic: return ui.showSemanticEdges
            case .duplicate: return ui.showDuplicateEdges
            case .sharedEvidence: return ui.showSharedEvidenceEdges
            }
        }
    }

    private var searchMatchedIDs: Set<String> {
        let q = ui.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return Set(visibleNodes.filter {
            $0.title.lowercased().contains(q) ||
            ($0.project?.lowercased().contains(q) ?? false)
        }.map(\.id))
    }

    private var effectiveScale: CGFloat {
        min(max(ui.scale * ui.pinchMagnification, 0.55), 3.6)
    }

    private var effectiveOffset: CGSize {
        CGSize(
            width: ui.offset.width + ui.dragTranslation.width,
            height: ui.offset.height + ui.dragTranslation.height
        )
    }

    private var isPulseActive: Bool {
        guard let pulseAt = model.lastPulseAt, !model.lastPulseMemoryIDs.isEmpty else { return false }
        return Date().timeIntervalSince(pulseAt) < pulseDuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlBar

            if model.memoryGraph.nodes.isEmpty {
                Spacer(minLength: 12)
                EmptyStateCard(
                    icon: "sparkles",
                    title: "星图等待记忆点亮",
                    description: "当 Agent 沉淀长期记忆并完成向量索引后，这里将以语义星图呈现记忆簇、相似连线与命中脉搏。",
                    actionTitle: "刷新星图"
                ) {
                    model.refreshMemoryGraph()
                }
                Spacer()
            } else {
                galaxyCanvasContainer
            }
        }
        .onAppear {
            syncLayoutIfNeeded()
            if model.memoryGraph.nodes.isEmpty {
                model.refreshMemoryGraph()
            }
        }
        .onChange(of: model.memoryGraph) { _, _ in
            syncLayoutIfNeeded()
        }
    }

    private func syncLayoutIfNeeded() {
        let sig = "\(model.memoryGraph.generatedAt.timeIntervalSince1970)-\(model.memoryGraph.nodes.count)-\(model.memoryGraph.edges.count)"
        guard sig != ui.layoutSignature else { return }
        ui.layoutSignature = sig
        ui.layout = GalaxyLayoutSnapshot.compute(graph: model.memoryGraph)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.textTertiary)
                    TextField("搜索星图节点标题或项目，回车聚焦…", text: $ui.searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { focusSearchMatches() }
                    if !ui.searchText.isEmpty {
                        Button {
                            ui.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    if !searchMatchedIDs.isEmpty {
                        Button("聚焦 (\(searchMatchedIDs.count))") {
                            focusSearchMatches()
                        }
                        .buttonStyle(SoftActionButtonStyle(tint: theme.accent, compact: true))
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.hairlineBorder, lineWidth: 1)
                )

                SegmentedPillBar(
                    options: GalaxyScopeFilter.allCases,
                    selection: $ui.scopeFilter,
                    label: { $0.rawValue },
                    compact: true
                )

                Button {
                    model.refreshMemoryGraph()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(SoftActionButtonStyle(compact: true))
                .help("重新计算语义星图")
            }

            HStack(spacing: 6) {
                edgeTogglePill("语义连线", isOn: $ui.showSemanticEdges, tint: theme.accent)
                edgeTogglePill("疑似重复", isOn: $ui.showDuplicateEdges, tint: theme.warning)
                edgeTogglePill("同源证据", isOn: $ui.showSharedEvidenceEdges, tint: theme.info)
                edgeTogglePill("隐藏沉睡", isOn: $ui.hideDormant, tint: theme.textSecondary)

                if ui.scopeFilter == .project && !knownProjects.isEmpty {
                    Divider().frame(height: 14).overlay(theme.hairlineBorder)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            projectChip(title: "全部项目", path: nil)
                            ForEach(knownProjects, id: \.self) { path in
                                projectChip(title: URL(fileURLWithPath: path).lastPathComponent, path: path)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func edgeTogglePill(_ title: String, isOn: Binding<Bool>, tint: Color) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                isOn.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(isOn.wrappedValue ? tint : theme.textTertiary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isOn.wrappedValue ? theme.textPrimary : theme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isOn.wrappedValue ? tint.opacity(theme.isDark ? 0.14 : 0.10) : theme.surfaceSecondary, in: Capsule())
            .overlay(
                Capsule().stroke(isOn.wrappedValue ? tint.opacity(0.32) : theme.hairlineBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func projectChip(title: String, path: String?) -> some View {
        let active = ui.selectedProject == path
        return Button {
            ui.selectedProject = path
        } label: {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(active ? theme.accent : theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(active ? theme.accentSoft : theme.surfacePrimary, in: Capsule())
                .overlay(Capsule().stroke(active ? theme.accentBorder : theme.hairlineBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(path ?? "显示所有项目记忆")
    }

    // MARK: - Interactive Canvas Container

    private var galaxyCanvasContainer: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if isPulseActive {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        galaxyCanvas(size: size, now: timeline.date)
                    }
                } else {
                    galaxyCanvas(size: size, now: Date())
                }

                // Hover tooltip
                if let hoveredID = ui.hoveredNodeID,
                   let node = visibleNodes.first(where: { $0.id == hoveredID }) {
                    hoverTooltip(for: node, in: size)
                }

                // Top-left stats & pulse HUD
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ScorePill(label: "节点", value: "\(visibleNodes.count)", tint: theme.accent)
                        ScorePill(label: "连线", value: "\(visibleEdges.count)", tint: theme.info)
                        let dupCount = visibleEdges.filter { $0.kind == .duplicate }.count
                        if dupCount > 0 {
                            ScorePill(label: "疑似重复", value: "\(dupCount)", tint: theme.warning)
                        }
                    }

                    if let pulseAt = model.lastPulseAt, !model.lastPulseMemoryIDs.isEmpty {
                        let agentBrand = model.lastPulseAgent?.brand
                        let pulseColor = agentBrand?.color(in: theme) ?? theme.accent
                        HStack(spacing: 6) {
                            Circle()
                                .fill(pulseColor)
                                .frame(width: 7, height: 7)
                                .shadow(color: pulseColor.opacity(0.75), radius: 4)
                            Text("\(agentBrand?.rawValue ?? "Agent") 命中 \(model.lastPulseMemoryIDs.count) 条")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(theme.textPrimary)
                            Text(pulseAt, format: .dateTime.hour().minute().second())
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(theme.textTertiary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(pulseColor.opacity(0.35), lineWidth: 1))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)

                // Bottom-left legend
                HStack(spacing: 10) {
                    legendDot("全局", color: theme.scopeGlobal)
                    legendDot("项目", color: theme.scopeProject)
                    legendLine("疑似重复", color: theme.warning, dashed: true)
                    legendLine("同源证据", color: theme.info, dashed: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(theme.hairlineBorder, lineWidth: 1))
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(false)

                // Bottom-right zoom HUD
                HStack(spacing: 4) {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            ui.scale = max(ui.scale / 1.25, 0.55)
                        }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("缩小")

                    Text("\(Int((effectiveScale * 100).rounded()))%")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 40)

                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            ui.scale = min(ui.scale * 1.25, 3.6)
                        }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("放大")

                    Divider().frame(height: 14).overlay(theme.hairlineBorder)

                    Button {
                        withAnimation(.easeOut(duration: 0.22)) {
                            ui.scale = 1.0
                            ui.offset = .zero
                        }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("重置视角")
                }
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(theme.hairlineBorder, lineWidth: 1))
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.hairlineBorder, lineWidth: 1)
            )
            .onAppear { ui.canvasSize = size }
            .onChange(of: size) { _, newSize in ui.canvasSize = newSize }
        }
        .frame(maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
    }

    private func galaxyCanvas(size: CGSize, now: Date) -> some View {
        let nodes = visibleNodes
        let edges = visibleEdges
        let matches = searchMatchedIDs
        let hasSearch = !ui.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let selectedID = model.selectedMemory?.id
        let hoveredID = ui.hoveredNodeID
        let focusID = hoveredID ?? selectedID

        // Neighbor lookup for hover/select highlighting
        var neighborIDs = Set<String>()
        if let focusID {
            neighborIDs.insert(focusID)
            for edge in edges {
                if edge.sourceID == focusID { neighborIDs.insert(edge.targetID) }
                else if edge.targetID == focusID { neighborIDs.insert(edge.sourceID) }
            }
        }

        // Pulse progress (0...1)
        let pulseIDs = Set(model.lastPulseMemoryIDs)
        let pulseElapsed: TimeInterval? = model.lastPulseAt.map { now.timeIntervalSince($0) }
        let pulseProgress: Double? = (pulseElapsed != nil && pulseElapsed! >= 0 && pulseElapsed! < pulseDuration)
            ? (pulseElapsed! / pulseDuration)
            : nil
        let pulseColor = model.lastPulseAgent?.brand.color(in: theme) ?? theme.accent

        return Canvas { context, canvasSize in
            // 1. Background + subtle dot matrix
            context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(theme.galaxyBackground))

            let step: CGFloat = 28
            var gx: CGFloat = step / 2
            while gx < canvasSize.width {
                var gy: CGFloat = step / 2
                while gy < canvasSize.height {
                    let dot = CGRect(x: gx - 0.75, y: gy - 0.75, width: 1.5, height: 1.5)
                    context.fill(Path(ellipseIn: dot), with: .color(theme.galaxyGrid))
                    gy += step
                }
                gx += step
            }

            // Compute screen positions
            var screenPoints: [String: CGPoint] = [:]
            for node in nodes {
                if let norm = ui.layout.positions[node.id] {
                    screenPoints[node.id] = screenPoint(for: norm, in: canvasSize)
                }
            }

            // 2. Subtle cluster labels (only when multiple clusters or zoomed nicely)
            for cluster in ui.layout.clusterCenters {
                if ui.scopeFilter == .global && !cluster.isGlobal { continue }
                if ui.scopeFilter == .project && cluster.isGlobal { continue }
                if let selectedProject = ui.selectedProject, !cluster.isGlobal, cluster.key != selectedProject { continue }

                let p = screenPoint(for: cluster.center, in: canvasSize)
                let labelColor = cluster.isGlobal ? theme.scopeGlobal : theme.scopeProject
                let resolved = context.resolve(
                    Text(cluster.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(labelColor.opacity(theme.isDark ? 0.34 : 0.42))
                )
                context.draw(resolved, at: CGPoint(x: p.x, y: p.y - 22 * effectiveScale), anchor: .center)
            }

            // 3. Edges
            for edge in edges {
                guard let p1 = screenPoints[edge.sourceID], let p2 = screenPoints[edge.targetID] else { continue }
                let touchesFocus = focusID != nil && (edge.sourceID == focusID || edge.targetID == focusID)
                let dimmed = (focusID != nil && !touchesFocus) || (hasSearch && !matches.contains(edge.sourceID) && !matches.contains(edge.targetID))

                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)

                switch edge.kind {
                case .semantic:
                    let baseAlpha = min(max(0.16 + edge.weight * 0.42, 0.16), 0.62)
                    let color = touchesFocus
                        ? theme.accent.opacity(0.75)
                        : theme.galaxyEdge.opacity(dimmed ? 0.12 : baseAlpha)
                    context.stroke(path, with: .color(color), lineWidth: touchesFocus ? 1.5 : 1.0)
                case .duplicate:
                    let color = theme.warning.opacity(dimmed ? 0.22 : (touchesFocus ? 0.95 : 0.72))
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: touchesFocus ? 2.0 : 1.35, dash: [5, 4])
                    )
                case .sharedEvidence:
                    let color = theme.info.opacity(dimmed ? 0.16 : (touchesFocus ? 0.85 : 0.45))
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: touchesFocus ? 1.6 : 1.05, dash: [2, 3])
                    )
                }
            }

            // 4. Nodes
            var drawnLabelRects: [CGRect] = []
            let sortedForDrawing = nodes.sorted { a, b in
                let prioA = (a.id == hoveredID ? 4 : 0) + (a.id == selectedID ? 3 : 0) + (matches.contains(a.id) ? 2 : 0) + (pulseIDs.contains(a.id) ? 1 : 0)
                let prioB = (b.id == hoveredID ? 4 : 0) + (b.id == selectedID ? 3 : 0) + (matches.contains(b.id) ? 2 : 0) + (pulseIDs.contains(b.id) ? 1 : 0)
                if prioA != prioB { return prioA < prioB }
                return a.hitCount < b.hitCount
            }

            for node in sortedForDrawing {
                guard let p = screenPoints[node.id] else { continue }
                let isHovered = node.id == hoveredID
                let isSelected = node.id == selectedID
                let isMatch = matches.contains(node.id)
                let isPulsing = pulseProgress != nil && pulseIDs.contains(node.id)
                let isNeighbor = focusID == nil || neighborIDs.contains(node.id)

                let baseRadius = nodeRadius(for: node) * min(max(sqrt(effectiveScale), 0.78), 1.55)
                let color = node.scope == "global" ? theme.scopeGlobal : theme.scopeProject

                var alpha = node.isDormant ? 0.34 : (0.48 + 0.52 * min(max(node.freshness, 0), 1))
                if hasSearch && !isMatch { alpha *= 0.22 }
                else if !isNeighbor && !isMatch { alpha *= 0.28 }
                if isHovered || isSelected || isMatch { alpha = 1.0 }

                // Real-time hit pulse rings
                if let progress = pulseProgress, isPulsing {
                    for ringIdx in 0..<2 {
                        let shifted = (progress * 1.4 - Double(ringIdx) * 0.35)
                        if shifted > 0 && shifted < 1 {
                            let ringR = baseRadius + CGFloat(shifted) * 34
                            let ringAlpha = (1.0 - shifted) * 0.72
                            let ringRect = CGRect(x: p.x - ringR, y: p.y - ringR, width: ringR * 2, height: ringR * 2)
                            context.stroke(
                                Path(ellipseIn: ringRect),
                                with: .color(pulseColor.opacity(ringAlpha)),
                                lineWidth: 2.0 * CGFloat(1.0 - shifted * 0.5)
                            )
                        }
                    }
                }

                // Ambient glow halo
                let haloScale: CGFloat = (isHovered || isSelected || isMatch) ? 2.6 : 1.9
                let haloR = baseRadius * haloScale
                let haloRect = CGRect(x: p.x - haloR, y: p.y - haloR, width: haloR * 2, height: haloR * 2)
                context.fill(
                    Path(ellipseIn: haloRect),
                    with: .color(color.opacity(alpha * (theme.isDark ? 0.24 : 0.16)))
                )

                // Node core
                let coreRect = CGRect(x: p.x - baseRadius, y: p.y - baseRadius, width: baseRadius * 2, height: baseRadius * 2)
                context.fill(Path(ellipseIn: coreRect), with: .color(color.opacity(alpha)))

                // Dormant dashed ring or selected/match highlight ring
                if isSelected || isHovered || isMatch {
                    let ringR = baseRadius + 3.5
                    let ringRect = CGRect(x: p.x - ringR, y: p.y - ringR, width: ringR * 2, height: ringR * 2)
                    context.stroke(
                        Path(ellipseIn: ringRect),
                        with: .color((isMatch ? theme.warning : theme.textPrimary).opacity(0.9)),
                        lineWidth: 1.5
                    )
                } else if node.isDormant {
                    let ringR = baseRadius + 2.5
                    let ringRect = CGRect(x: p.x - ringR, y: p.y - ringR, width: ringR * 2, height: ringR * 2)
                    context.stroke(
                        Path(ellipseIn: ringRect),
                        with: .color(theme.textTertiary.opacity(0.45)),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                    )
                }

                // Selective non-overlapping labels
                let shouldTryLabel = isHovered || isSelected || isMatch || isPulsing ||
                    (effectiveScale >= 1.35 && node.hitCount > 0) ||
                    (nodes.count <= 24 && effectiveScale >= 0.95)
                if shouldTryLabel && !isHovered {
                    let shortTitle = node.title.count > 16 ? String(node.title.prefix(15)) + "…" : node.title
                    let labelPoint = CGPoint(x: p.x, y: p.y + baseRadius + 10)
                    let estWidth = CGFloat(shortTitle.count) * 7.2 + 12
                    let estRect = CGRect(x: labelPoint.x - estWidth / 2, y: labelPoint.y - 8, width: estWidth, height: 16)
                    let collides = drawnLabelRects.contains { $0.intersects(estRect.insetBy(dx: -4, dy: -2)) }
                    if !collides || isSelected || isMatch || isPulsing {
                        drawnLabelRects.append(estRect)
                        let resolved = context.resolve(
                            Text(shortTitle)
                                .font(.system(size: 10, weight: (isSelected || isMatch) ? .semibold : .medium))
                                .foregroundStyle(theme.textPrimary.opacity(isSelected || isMatch ? 0.95 : 0.78))
                        )
                        context.draw(resolved, at: labelPoint, anchor: .center)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    ui.dragTranslation = value.translation
                }
                .onEnded { value in
                    ui.offset = CGSize(
                        width: ui.offset.width + value.translation.width,
                        height: ui.offset.height + value.translation.height
                    )
                    ui.dragTranslation = .zero
                }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    ui.pinchMagnification = value
                }
                .onEnded { value in
                    ui.scale = min(max(ui.scale * value, 0.55), 3.6)
                    ui.pinchMagnification = 1.0
                }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    if let hitNode = hitTestNode(at: value.location, in: size) {
                        onSelectMemoryID(hitNode.id)
                    }
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                ui.hoverLocation = location
                ui.hoveredNodeID = hitTestNode(at: location, in: size)?.id
            case .ended:
                ui.hoveredNodeID = nil
            }
        }
    }

    private func screenPoint(for norm: CGPoint, in size: CGSize) -> CGPoint {
        let halfW = size.width * 0.44
        let halfH = size.height * 0.42
        let cx = size.width / 2 + effectiveOffset.width
        let cy = size.height / 2 + effectiveOffset.height
        return CGPoint(
            x: cx + norm.x * halfW * effectiveScale,
            y: cy + norm.y * halfH * effectiveScale
        )
    }

    private func nodeRadius(for node: MemoryGraphNode) -> CGFloat {
        let heatBoost = min(Double(node.hitCount) * 0.95 + Double(node.evidenceCount) * 0.45, 7.5)
        return CGFloat(5.0 + heatBoost)
    }

    private func hitTestNode(at point: CGPoint, in size: CGSize) -> MemoryGraphNode? {
        var best: (node: MemoryGraphNode, dist: CGFloat)?
        for node in visibleNodes {
            guard let norm = ui.layout.positions[node.id] else { continue }
            let p = screenPoint(for: norm, in: size)
            let hitR = max(nodeRadius(for: node) * sqrt(effectiveScale) + 8, 14)
            let dist = hypot(p.x - point.x, p.y - point.y)
            if dist <= hitR, best == nil || dist < best!.dist {
                best = (node, dist)
            }
        }
        return best?.node
    }

    private func focusSearchMatches() {
        let matched = visibleNodes.filter { searchMatchedIDs.contains($0.id) }
        guard !matched.isEmpty else { return }
        let norms = matched.compactMap { ui.layout.positions[$0.id] }
        guard !norms.isEmpty else { return }
        let avgX = norms.map(\.x).reduce(0, +) / CGFloat(norms.count)
        let avgY = norms.map(\.y).reduce(0, +) / CGFloat(norms.count)
        let targetScale: CGFloat = matched.count == 1 ? 1.85 : 1.45
        let halfW = ui.canvasSize.width * 0.44
        let halfH = ui.canvasSize.height * 0.42
        withAnimation(.easeInOut(duration: 0.3)) {
            ui.scale = targetScale
            ui.offset = CGSize(
                width: -avgX * halfW * targetScale,
                height: -avgY * halfH * targetScale
            )
        }
    }

    // MARK: - Hover Tooltip & Legends

    private func hoverTooltip(for node: MemoryGraphNode, in size: CGSize) -> some View {
        let norm = ui.layout.positions[node.id] ?? .zero
        let p = screenPoint(for: norm, in: size)
        let clampedX = min(max(p.x, 140), max(size.width - 140, 140))
        let clampedY = p.y > 110 ? p.y - 54 : p.y + 56

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ScopeTag(projectPath: node.project)
                if node.isDormant {
                    ScorePill(label: "活性", value: "沉睡", tint: theme.warning)
                }
            }
            Text(node.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("命中 \(node.hitCount) 次")
                    .monospacedDigit()
                Text("· 证据 \(node.evidenceCount)")
                    .monospacedDigit()
                Text("· 活性 \(Int((node.freshness * 100).rounded()))%")
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: 250, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.accentBorder, lineWidth: 1)
        )
        .shadow(color: theme.cardShadow, radius: 10, y: 4)
        .position(x: clampedX, y: clampedY)
        .allowsHitTesting(false)
    }

    private func legendDot(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption2).foregroundStyle(theme.textSecondary)
        }
    }

    private func legendLine(_ title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: 10, height: dashed ? 1.5 : 1)
            Text(title).font(.caption2).foregroundStyle(theme.textSecondary)
        }
    }
}

// MARK: - Compact Live Preview Canvas for OverviewView

struct MemoryGalaxyMiniPreview: View {
    @Environment(\.theme) private var theme
    let graph: MemoryGraph
    let pulseMemoryIDs: [String]
    let pulseAgent: ActivityEvent.Agent?
    let pulseAt: Date?

    private let fallbackNodes: [(x: CGFloat, y: CGFloat, r: CGFloat, isGlobal: Bool)] = [
        (0.14, 0.34, 5.0, false),
        (0.26, 0.68, 4.5, true),
        (0.38, 0.28, 6.5, false),
        (0.49, 0.62, 5.0, false),
        (0.60, 0.36, 7.0, true),
        (0.73, 0.66, 5.5, false),
        (0.85, 0.32, 4.5, true)
    ]

    private let fallbackEdges: [(Int, Int)] = [
        (0, 1), (0, 2), (1, 3), (2, 3), (2, 4), (3, 4), (4, 5), (4, 6), (5, 6)
    ]

    var body: some View {
        let snapshot = GalaxyLayoutSnapshot.compute(graph: graph)
        let pulseSet = Set(pulseMemoryIDs)
        let pulseColor = pulseAgent?.brand.color(in: theme) ?? theme.accent
        let showPulse = pulseAt.map { Date().timeIntervalSince($0) < 10 } ?? false

        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.galaxyBackground))

            let step: CGFloat = 24
            var x: CGFloat = step / 2
            while x < size.width {
                var y: CGFloat = step / 2
                while y < size.height {
                    let dot = CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)
                    context.fill(Path(ellipseIn: dot), with: .color(theme.galaxyGrid))
                    y += step
                }
                x += step
            }

            if graph.nodes.isEmpty {
                let points = fallbackNodes.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                for (from, to) in fallbackEdges {
                    var path = Path()
                    path.move(to: points[from])
                    path.addLine(to: points[to])
                    context.stroke(path, with: .color(theme.galaxyEdge), lineWidth: 1)
                }
                for (idx, node) in fallbackNodes.enumerated() {
                    let p = points[idx]
                    let color = node.isGlobal ? theme.scopeGlobal : theme.scopeProject
                    let glowRect = CGRect(x: p.x - node.r * 2.2, y: p.y - node.r * 2.2, width: node.r * 4.4, height: node.r * 4.4)
                    context.fill(Path(ellipseIn: glowRect), with: .color(color.opacity(theme.isDark ? 0.22 : 0.15)))
                    let coreRect = CGRect(x: p.x - node.r, y: p.y - node.r, width: node.r * 2, height: node.r * 2)
                    context.fill(Path(ellipseIn: coreRect), with: .color(color))
                }
                return
            }

            var points: [String: CGPoint] = [:]
            for node in graph.nodes {
                guard let norm = snapshot.positions[node.id] else { continue }
                points[node.id] = CGPoint(
                    x: size.width / 2 + norm.x * size.width * 0.43,
                    y: size.height / 2 + norm.y * size.height * 0.40
                )
            }

            for edge in graph.edges {
                guard let p1 = points[edge.sourceID], let p2 = points[edge.targetID] else { continue }
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                switch edge.kind {
                case .semantic:
                    context.stroke(path, with: .color(theme.galaxyEdge.opacity(0.45)), lineWidth: 0.9)
                case .duplicate:
                    context.stroke(path, with: .color(theme.warning.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                case .sharedEvidence:
                    context.stroke(path, with: .color(theme.info.opacity(0.4)), style: StrokeStyle(lineWidth: 0.9, dash: [2, 2]))
                }
            }

            for node in graph.nodes {
                guard let p = points[node.id] else { continue }
                let r = CGFloat(3.5 + min(Double(node.hitCount) * 0.65 + Double(node.evidenceCount) * 0.25, 4.5))
                let color = node.scope == "global" ? theme.scopeGlobal : theme.scopeProject
                let alpha = node.isDormant ? 0.35 : (0.55 + 0.45 * min(max(node.freshness, 0), 1))

                if showPulse && pulseSet.contains(node.id) {
                    let ringR = r + 6
                    let ringRect = CGRect(x: p.x - ringR, y: p.y - ringR, width: ringR * 2, height: ringR * 2)
                    context.stroke(Path(ellipseIn: ringRect), with: .color(pulseColor.opacity(0.75)), lineWidth: 1.5)
                }

                let glowRect = CGRect(x: p.x - r * 2.0, y: p.y - r * 2.0, width: r * 4.0, height: r * 4.0)
                context.fill(Path(ellipseIn: glowRect), with: .color(color.opacity(alpha * (theme.isDark ? 0.24 : 0.16))))
                let coreRect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: coreRect), with: .color(color.opacity(alpha)))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(theme.hairlineBorder, lineWidth: 1)
        )
    }
}
