import AgentMemoryCore
import SwiftUI

// MARK: - Galaxy Display Mode

enum MemoryGalaxyMode: Equatable {
    case ambientBackdrop
    case interactiveFull
}

// MARK: - 3D Math Helpers

private struct Vec3 {
    var x: Double
    var y: Double
    var z: Double

    static let zero = Vec3(x: 0, y: 0, z: 0)

    static func + (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    static func * (lhs: Vec3, rhs: Double) -> Vec3 {
        Vec3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    static func += (lhs: inout Vec3, rhs: Vec3) {
        lhs.x += rhs.x
        lhs.y += rhs.y
        lhs.z += rhs.z
    }

    var lengthSq: Double { x * x + y * y + z * z }
    var length: Double { sqrt(lengthSq) }
}

private struct GalaxyClusterMeta {
    let key: String
    let label: String
    let isGlobal: Bool
    let projectPath: String?
    let colorIndex: Int
    let anchor: Vec3
}

private struct GalaxyPhysicsNode {
    let node: MemoryGraphNode
    let clusterIndex: Int
    var position: Vec3
    var velocity: Vec3
}

private struct GalaxyPhysicsEdge {
    let sourceIndex: Int
    let targetIndex: Int
    let kind: MemoryGraphEdge.Kind
    let weight: Double
    let sameCluster: Bool
}

private struct ProjectedStar {
    let index: Int
    let node: MemoryGraphNode
    let clusterIndex: Int
    let screen: CGPoint
    let depth: Double          // rotated Z (larger = closer to viewer)
    let perspective: Double    // scale factor from perspective projection
    let radius: CGFloat
}

private struct BackgroundStardust {
    let u: Double              // 0...1
    let v: Double              // 0...1
    let depth: Double          // 0.2...1.0
    let size: CGFloat
    let phase: Double
    let speed: Double
}

// MARK: - 3D Elastic Physics & Camera Engine

@MainActor
private final class GalaxyEngine: ObservableObject {
    // Physics state (mutated in-place at 60fps inside TimelineView without publishing)
    var clusters: [GalaxyClusterMeta] = []
    var nodes: [GalaxyPhysicsNode] = []
    var edges: [GalaxyPhysicsEdge] = []
    var idToIndex: [String: Int] = [:]
    var lastProjected: [ProjectedStar] = []
    var lastCanvasSize: CGSize = CGSize(width: 960, height: 640)
    var lastMode: MemoryGalaxyMode = .interactiveFull

    // Camera state
    var yaw: Double = 0.35
    var pitch: Double = 0.22
    var yawVelocity: Double = 0
    var pitchVelocity: Double = 0
    var autoRotateSpeedFactor: Double = 1.0
    var lastTickDate: Date?

    // Drag interaction state
    var isDraggingSpace = false
    var draggedNodeIndex: Int? = nil
    var lastDragLocation: CGPoint? = nil

    // SwiftUI-observed lightweight UI state
    @Published var isAutoRotating = true
    @Published var scale: CGFloat = 1.0
    @Published var pinchMagnification: CGFloat = 1.0
    @Published var hoveredNodeID: String? = nil
    @Published var hoverLocation: CGPoint = .zero
    @Published var scopeFilter: GalaxyScopeFilter = .all
    @Published var selectedProject: String? = nil
    @Published var showSemanticEdges = true
    @Published var showDuplicateEdges = true
    @Published var showSharedEvidenceEdges = true
    @Published var hideDormant = false
    @Published var searchText = ""

    private var graphSignature: String = ""
    let stardust: [BackgroundStardust]

    init() {
        var dust: [BackgroundStardust] = []
        dust.reserveCapacity(84)
        for i in 0..<84 {
            let h1 = Self.stableUnitHash("dust-u-\(i)")
            let h2 = Self.stableUnitHash("dust-v-\(i)")
            let h3 = Self.stableUnitHash("dust-d-\(i)")
            let h4 = Self.stableUnitHash("dust-p-\(i)")
            dust.append(BackgroundStardust(
                u: h1,
                v: h2,
                depth: 0.25 + h3 * 0.75,
                size: CGFloat(0.75 + h3 * 1.45),
                phase: h4 * .pi * 2,
                speed: 0.6 + h1 * 1.3
            ))
        }
        self.stardust = dust
    }

    var effectiveScale: CGFloat {
        min(max(scale * pinchMagnification, 0.55), 2.8)
    }

    static func clusterCount(for graph: MemoryGraph) -> Int {
        guard !graph.nodes.isEmpty else { return 0 }
        var keys = Set<String>()
        for node in graph.nodes {
            let key = (node.scope == "global" || node.project == nil || node.project?.isEmpty == true)
                ? "__global__"
                : (node.project ?? "__global__")
            keys.insert(key)
        }
        return keys.count
    }

    func syncGraph(_ graph: MemoryGraph) {
        let sig = "\(graph.generatedAt.timeIntervalSince1970)-\(graph.nodes.count)-\(graph.edges.count)"
        guard sig != graphSignature else { return }
        graphSignature = sig

        // Preserve existing positions for smooth incremental updates
        var oldPositions: [String: Vec3] = [:]
        for item in nodes {
            oldPositions[item.node.id] = item.position
        }

        let allNodes = graph.nodes
        guard !allNodes.isEmpty else {
            clusters = []
            nodes = []
            edges = []
            idToIndex = [:]
            lastProjected = []
            return
        }

        // 1. Bucket by scope / project
        var scopeBuckets: [String: [MemoryGraphNode]] = [:]
        for node in allNodes {
            let key = (node.scope == "global" || node.project == nil || node.project?.isEmpty == true)
                ? "__global__"
                : (node.project ?? "__global__")
            scopeBuckets[key, default: []].append(node)
        }

        // 2. Refine large buckets into semantic sub-clusters using union-find on strong edges
        var strongAdjacency: [String: [String]] = [:]
        for edge in graph.edges {
            let isStrong = (edge.kind == .duplicate)
                || (edge.kind == .sharedEvidence)
                || (edge.kind == .semantic && edge.weight >= 0.48)
            if isStrong {
                strongAdjacency[edge.sourceID, default: []].append(edge.targetID)
                strongAdjacency[edge.targetID, default: []].append(edge.sourceID)
            }
        }

        struct RawCluster {
            let key: String
            let label: String
            let isGlobal: Bool
            let projectPath: String?
            let members: [MemoryGraphNode]
        }

        var rawClusters: [RawCluster] = []
        let sortedScopeKeys = scopeBuckets.keys.sorted { a, b in
            if a == "__global__" { return true }
            if b == "__global__" { return false }
            let ca = scopeBuckets[a]?.count ?? 0
            let cb = scopeBuckets[b]?.count ?? 0
            if ca != cb { return ca > cb }
            return a < b
        }

        for scopeKey in sortedScopeKeys {
            guard let bucket = scopeBuckets[scopeKey], !bucket.isEmpty else { continue }
            let isGlobal = scopeKey == "__global__"
            let baseLabel = isGlobal ? "全局记忆" : (URL(fileURLWithPath: scopeKey).lastPathComponent.isEmpty ? scopeKey : URL(fileURLWithPath: scopeKey).lastPathComponent)
            let projectPath: String? = isGlobal ? nil : scopeKey

            if bucket.count >= 14 {
                let memberSet = Set(bucket.map(\.id))
                var visited = Set<String>()
                var components: [[MemoryGraphNode]] = []
                let byID = Dictionary(uniqueKeysWithValues: bucket.map { ($0.id, $0) })

                for node in bucket {
                    guard !visited.contains(node.id) else { continue }
                    var queue = [node.id]
                    visited.insert(node.id)
                    var comp: [MemoryGraphNode] = []
                    while !queue.isEmpty {
                        let cur = queue.removeFirst()
                        if let m = byID[cur] { comp.append(m) }
                        for nxt in strongAdjacency[cur] ?? [] where memberSet.contains(nxt) && !visited.contains(nxt) {
                            visited.insert(nxt)
                            queue.append(nxt)
                        }
                    }
                    components.append(comp)
                }

                // Keep meaningful sub-clusters (>= 4 nodes) and merge tiny fragments into the largest
                let major = components.filter { $0.count >= 4 }.sorted { $0.count > $1.count }
                if major.count >= 2 {
                    var merged = major
                    let minors = components.filter { $0.count < 4 }.flatMap { $0 }
                    if !minors.isEmpty {
                        merged[0].append(contentsOf: minors)
                    }
                    for (subIdx, comp) in merged.enumerated() {
                        let subLabel = subIdx == 0 ? baseLabel : "\(baseLabel) · 星簇 \(subIdx + 1)"
                        rawClusters.append(RawCluster(
                            key: "\(scopeKey)#\(subIdx)",
                            label: subLabel,
                            isGlobal: isGlobal,
                            projectPath: projectPath,
                            members: comp
                        ))
                    }
                    continue
                }
            }

            rawClusters.append(RawCluster(
                key: scopeKey,
                label: baseLabel,
                isGlobal: isGlobal,
                projectPath: projectPath,
                members: bucket
            ))
        }

        // 3. Place cluster anchors cleanly in 3D space (Fibonacci sphere distribution)
        let clusterCount = rawClusters.count
        var builtClusters: [GalaxyClusterMeta] = []
        builtClusters.reserveCapacity(clusterCount)

        let goldenAngle = Double.pi * (3.0 - sqrt(5.0))
        for (idx, raw) in rawClusters.enumerated() {
            let anchor: Vec3
            if clusterCount == 1 {
                anchor = .zero
            } else if clusterCount == 2 {
                let sign = idx == 0 ? -1.0 : 1.0
                anchor = Vec3(x: sign * 0.56, y: sign * 0.14, z: sign * 0.22)
            } else {
                let y = 1.0 - (Double(idx) / Double(max(clusterCount - 1, 1))) * 1.65 - 0.12
                let radiusAtY = sqrt(max(1.0 - y * y * 0.65, 0.15))
                let theta = goldenAngle * Double(idx) + 0.4
                let shellRadius = clusterCount <= 4 ? 0.68 : 0.82
                anchor = Vec3(
                    x: cos(theta) * radiusAtY * shellRadius,
                    y: y * 0.48 * shellRadius,
                    z: sin(theta) * radiusAtY * shellRadius
                )
            }

            let colorIndex = raw.isGlobal ? 0 : (1 + (idx % 5))
            builtClusters.append(GalaxyClusterMeta(
                key: raw.key,
                label: raw.label,
                isGlobal: raw.isGlobal,
                projectPath: raw.projectPath,
                colorIndex: colorIndex,
                anchor: anchor
            ))
        }

        // 4. Spawn 3D physics nodes around each cluster anchor
        var builtNodes: [GalaxyPhysicsNode] = []
        var lookup: [String: Int] = [:]
        builtNodes.reserveCapacity(allNodes.count)

        for (cIdx, raw) in rawClusters.enumerated() {
            let anchor = builtClusters[cIdx].anchor
            let ordered = raw.members.sorted {
                if $0.hitCount != $1.hitCount { return $0.hitCount > $1.hitCount }
                if $0.updated != $1.updated { return $0.updated > $1.updated }
                return $0.id < $1.id
            }
            let spread = clusterCount <= 1 ? 0.52 : 0.30
            for (i, node) in ordered.enumerated() {
                let initialPos: Vec3
                if let existing = oldPositions[node.id] {
                    initialPos = existing
                } else if ordered.count == 1 {
                    initialPos = anchor
                } else {
                    let t = (Double(i) + 0.5) / Double(ordered.count)
                    let phi = acos(1.0 - 2.0 * t)
                    let theta = goldenAngle * Double(i) + Self.stableUnitHash(node.id) * 0.6
                    let r = spread * (0.35 + 0.65 * pow(t, 0.45))
                    initialPos = Vec3(
                        x: anchor.x + sin(phi) * cos(theta) * r,
                        y: anchor.y + cos(phi) * r * 0.85,
                        z: anchor.z + sin(phi) * sin(theta) * r
                    )
                }
                lookup[node.id] = builtNodes.count
                builtNodes.append(GalaxyPhysicsNode(
                    node: node,
                    clusterIndex: cIdx,
                    position: initialPos,
                    velocity: .zero
                ))
            }
        }

        // 5. Build indexed physics edges
        var builtEdges: [GalaxyPhysicsEdge] = []
        builtEdges.reserveCapacity(graph.edges.count)
        for edge in graph.edges {
            guard let s = lookup[edge.sourceID], let t = lookup[edge.targetID], s != t else { continue }
            builtEdges.append(GalaxyPhysicsEdge(
                sourceIndex: s,
                targetIndex: t,
                kind: edge.kind,
                weight: edge.weight,
                sameCluster: builtNodes[s].clusterIndex == builtNodes[t].clusterIndex
            ))
        }

        self.clusters = builtClusters
        self.nodes = builtNodes
        self.edges = builtEdges
        self.idToIndex = lookup

        // Warm-start physics for 14 steps so initial layout is already organically relaxed
        for _ in 0..<14 {
            stepPhysics(dt: 1.0 / 60.0)
        }
    }

    func tick(now: Date) {
        let rawDt = lastTickDate.map { now.timeIntervalSince($0) } ?? (1.0 / 60.0)
        lastTickDate = now
        let dt = min(max(rawDt, 1.0 / 120.0), 1.0 / 24.0)

        // Smooth auto-rotation speed modulation (decelerates smoothly when hovering a star)
        let targetSpeed: Double
        if !isAutoRotating || isDraggingSpace || draggedNodeIndex != nil {
            targetSpeed = 0.0
        } else if hoveredNodeID != nil {
            targetSpeed = 0.12
        } else {
            targetSpeed = 1.0
        }
        autoRotateSpeedFactor += (targetSpeed - autoRotateSpeedFactor) * min(dt * 6.5, 1.0)

        // Slow, dignified 3D rotation + drag inertia
        if !isDraggingSpace {
            yaw += (0.095 * autoRotateSpeedFactor + yawVelocity) * dt
            pitch += pitchVelocity * dt
            let inertiaDecay = pow(0.06, dt)
            yawVelocity *= inertiaDecay
            pitchVelocity *= inertiaDecay
            if abs(yawVelocity) < 0.001 { yawVelocity = 0 }
            if abs(pitchVelocity) < 0.001 { pitchVelocity = 0 }

            // Gently clamp pitch so universe never flips awkwardly upside down
            if pitch > 1.15 {
                pitch += (1.15 - pitch) * min(dt * 8.0, 1.0)
            } else if pitch < -1.15 {
                pitch += (-1.15 - pitch) * min(dt * 8.0, 1.0)
            }
        }

        stepPhysics(dt: dt)
    }

    private func stepPhysics(dt: Double) {
        let count = nodes.count
        guard count > 0 else { return }

        var forces = Array(repeating: Vec3.zero, count: count)

        // 1. Cluster gravity well
        let gravityStrength = 1.85
        for i in 0..<count {
            let anchor = clusters[nodes[i].clusterIndex].anchor
            let diff = anchor - nodes[i].position
            forces[i] += diff * gravityStrength
        }

        // 2. Semantic edge springs (Hooke's law)
        for edge in edges {
            let a = edge.sourceIndex
            let b = edge.targetIndex
            let delta = nodes[b].position - nodes[a].position
            let dist = max(delta.length, 0.004)
            let restLength: Double
            let k: Double
            switch edge.kind {
            case .duplicate:
                restLength = 0.11
                k = 3.6
            case .semantic:
                restLength = edge.sameCluster ? 0.22 : 0.56
                k = (edge.sameCluster ? 1.55 : 0.35) * max(edge.weight, 0.35)
            case .sharedEvidence:
                restLength = edge.sameCluster ? 0.25 : 0.62
                k = edge.sameCluster ? 0.95 : 0.22
            }
            let stretch = (dist - restLength) / dist
            let f = delta * (stretch * k)
            forces[a] += f
            forces[b] += f * -1.0
        }

        // 3. Pairwise 3D short-range repulsion
        let minSep = count > 140 ? 0.16 : 0.22
        let minSepSq = minSep * minSep
        let repulseStrength = count > 140 ? 0.042 : 0.068
        for i in 0..<count {
            let pi = nodes[i].position
            let ci = nodes[i].clusterIndex
            for j in (i + 1)..<count {
                let d = pi - nodes[j].position
                let distSq = d.lengthSq
                let cutoffSq = (ci == nodes[j].clusterIndex) ? minSepSq : (minSepSq * 1.9)
                if distSq < cutoffSq {
                    let dist = max(sqrt(distSq), 0.008)
                    let overlap = sqrt(cutoffSq) - dist
                    let push = (overlap / dist) * repulseStrength * 14.0
                    let f = d * push
                    forces[i] += f
                    forces[j] += f * -1.0
                }
            }
        }

        // 4. Integrate with elastic damping
        let damping = pow(0.14, dt)
        for i in 0..<count {
            if draggedNodeIndex == i {
                nodes[i].velocity = .zero
                continue
            }
            nodes[i].velocity = (nodes[i].velocity + forces[i] * dt) * damping
            nodes[i].position += nodes[i].velocity * dt

            // Soft spherical boundary to keep universe cohesive
            let lenSq = nodes[i].position.lengthSq
            if lenSq > 2.4 {
                let inv = sqrt(2.4 / lenSq)
                nodes[i].position = nodes[i].position * inv
            }
        }
    }

    // MARK: - 3D Projection & Camera Basis

    func screenCenter(for size: CGSize, mode: MemoryGalaxyMode) -> CGPoint {
        switch mode {
        case .ambientBackdrop:
            return CGPoint(x: size.width * 0.67, y: size.height * 0.44)
        case .interactiveFull:
            return CGPoint(x: size.width * 0.50, y: size.height * 0.50)
        }
    }

    func baseScalePixels(for size: CGSize, mode: MemoryGalaxyMode) -> Double {
        let minDim = Double(min(size.width, size.height))
        let modeFactor = mode == .ambientBackdrop ? 0.40 : 0.42
        return max(minDim * modeFactor, 160.0) * Double(effectiveScale)
    }

    func rotateToCamera(_ p: Vec3) -> Vec3 {
        let cosY = cos(yaw)
        let sinY = sin(yaw)
        let x1 = p.x * cosY + p.z * sinY
        let z1 = -p.x * sinY + p.z * cosY

        let cosP = cos(pitch)
        let sinP = sin(pitch)
        let y2 = p.y * cosP - z1 * sinP
        let z2 = p.y * sinP + z1 * cosP
        return Vec3(x: x1, y: y2, z: z2)
    }

    func project(_ p: Vec3, in size: CGSize, mode: MemoryGalaxyMode) -> (point: CGPoint, depth: Double, perspective: Double) {
        let cam = rotateToCamera(p)
        let cameraDist = 3.25
        let denom = max(cameraDist - cam.z, 0.55)
        let persp = 2.65 / denom
        let pxScale = baseScalePixels(for: size, mode: mode)
        let center = screenCenter(for: size, mode: mode)
        let sx = center.x + CGFloat(cam.x * persp * pxScale)
        let sy = center.y - CGFloat(cam.y * persp * pxScale)
        return (CGPoint(x: sx, y: sy), cam.z, persp)
    }

    /// Converts a 2D screen drag delta into a 3D world-space displacement along the camera plane.
    func worldDelta(forScreenDelta delta: CGSize, atDepth depth: Double, in size: CGSize, mode: MemoryGalaxyMode) -> Vec3 {
        let cameraDist = 3.25
        let persp = 2.65 / max(cameraDist - depth, 0.55)
        let pxScale = max(baseScalePixels(for: size, mode: mode) * persp, 40.0)
        let camDx = Double(delta.width) / pxScale
        let camDy = -Double(delta.height) / pxScale

        // Inverse of rotateToCamera (transpose of Pitch * Yaw = Yaw^T * Pitch^T)
        let cosP = cos(pitch)
        let sinP = sin(pitch)
        let y1 = camDy * cosP
        let z1 = -camDy * sinP

        let cosY = cos(yaw)
        let sinY = sin(yaw)
        let wx = camDx * cosY - z1 * sinY
        let wz = camDx * sinY + z1 * cosY
        return Vec3(x: wx, y: y1, z: wz)
    }

    func hitTestProjected(at location: CGPoint) -> ProjectedStar? {
        // Iterate front-to-back (highest depth first)
        var best: (star: ProjectedStar, dist: CGFloat)?
        for star in lastProjected.reversed() {
            let hitR = max(star.radius + 9.0, 15.0)
            let dist = hypot(star.screen.x - location.x, star.screen.y - location.y)
            if dist <= hitR {
                if best == nil || dist < best!.dist {
                    best = (star, dist)
                }
            }
        }
        return best?.star
    }

    func resetView() {
        yaw = 0.35
        pitch = 0.22
        yawVelocity = 0
        pitchVelocity = 0
        scale = 1.0
        pinchMagnification = 1.0
    }

    func focusOn(nodeIDs: Set<String>) {
        let matched = nodes.filter { nodeIDs.contains($0.node.id) }
        guard !matched.isEmpty else { return }
        var avg = Vec3.zero
        for m in matched { avg += m.position }
        avg = avg * (1.0 / Double(matched.count))
        let targetYaw = -atan2(avg.x, max(abs(avg.z), 0.15))
        let targetPitch = min(max(atan2(avg.y, max(sqrt(avg.x * avg.x + avg.z * avg.z), 0.25)), -0.9), 0.9)
        yaw = targetYaw
        pitch = targetPitch
        yawVelocity = 0
        pitchVelocity = 0
        scale = matched.count == 1 ? 1.55 : 1.30
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

private enum GalaxyScopeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case global = "仅全局"
    case project = "仅项目"

    var id: Self { self }
}

// MARK: - 3D Elastic Memory Galaxy View

struct MemoryGalaxyView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    var mode: MemoryGalaxyMode = .interactiveFull
    var dreamResonanceTrigger: Date? = nil
    let onSelectMemoryID: (String) -> Void

    @StateObject private var engine = GalaxyEngine()

    private let pulseDuration: TimeInterval = 4.2
    private let resonanceDuration: TimeInterval = 2.8

    static func clusterCount(for graph: MemoryGraph) -> Int {
        GalaxyEngine.clusterCount(for: graph)
    }

    private var knownProjects: [String] {
        Array(Set(model.memoryGraph.nodes.compactMap(\.project).filter { !$0.isEmpty })).sorted()
    }

    private func isNodeVisible(_ node: MemoryGraphNode) -> Bool {
        guard mode == .interactiveFull else { return true }
        if engine.hideDormant && node.isDormant { return false }
        switch engine.scopeFilter {
        case .all:
            return true
        case .global:
            return node.scope == "global" || node.project == nil
        case .project:
            guard let project = node.project, !project.isEmpty else { return false }
            if let selectedProject = engine.selectedProject {
                return project == selectedProject
            }
            return true
        }
    }

    private var searchMatchedIDs: Set<String> {
        guard mode == .interactiveFull else { return [] }
        let q = engine.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return Set(model.memoryGraph.nodes.filter {
            isNodeVisible($0) &&
            ($0.title.lowercased().contains(q) || ($0.project?.lowercased().contains(q) ?? false))
        }.map(\.id))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    galaxyCanvas(size: size, now: timeline.date)
                }

                // Hover Liquid Glass tooltip
                if let hoveredID = engine.hoveredNodeID,
                   let star = engine.lastProjected.first(where: { $0.node.id == hoveredID }) {
                    hoverTooltip(for: star, in: size)
                }

                // Interactive Full-Screen HUD (Memory -> Galaxy mode)
                if mode == .interactiveFull {
                    interactiveFullOverlay
                }
            }
            .onAppear {
                engine.lastCanvasSize = size
                engine.lastMode = mode
                engine.syncGraph(model.memoryGraph)
                if model.memoryGraph.nodes.isEmpty {
                    model.refreshMemoryGraph()
                }
            }
            .onChange(of: size) { _, newSize in
                engine.lastCanvasSize = newSize
            }
            .onChange(of: mode) { _, newMode in
                engine.lastMode = newMode
            }
            .onChange(of: model.memoryGraph) { _, newGraph in
                engine.syncGraph(newGraph)
            }
        }
    }

    // MARK: - 3D Canvas Renderer

    private func galaxyCanvas(size: CGSize, now: Date) -> some View {
        engine.tick(now: now)

        let matches = searchMatchedIDs
        let hasSearch = mode == .interactiveFull && !engine.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let selectedID = model.selectedMemory?.id
        let hoveredID = engine.hoveredNodeID
        let focusID = hoveredID ?? selectedID

        // Real-time hit pulse progress
        let pulseIDs = Set(model.lastPulseMemoryIDs)
        let pulseElapsed = model.lastPulseAt.map { now.timeIntervalSince($0) }
        let pulseProgress: Double? = (pulseElapsed != nil && pulseElapsed! >= 0 && pulseElapsed! < pulseDuration)
            ? (pulseElapsed! / pulseDuration)
            : nil
        let pulseColor = model.lastPulseAgent?.brand.color(in: theme) ?? theme.accent

        // Dream resonance wave progress
        let resonanceElapsed = dreamResonanceTrigger.map { now.timeIntervalSince($0) }
        let resonanceProgress: Double? = (resonanceElapsed != nil && resonanceElapsed! >= 0 && resonanceElapsed! < resonanceDuration)
            ? (resonanceElapsed! / resonanceDuration)
            : nil

        // Visible node indices & projection
        var visibleIndexSet = Set<Int>()
        var projected: [ProjectedStar] = []
        projected.reserveCapacity(engine.nodes.count)

        for (idx, item) in engine.nodes.enumerated() {
            guard isNodeVisible(item.node) else { continue }
            visibleIndexSet.insert(idx)
            let proj = engine.project(item.position, in: size, mode: mode)
            let heatBoost = min(Double(item.node.hitCount) * 0.72 + Double(item.node.evidenceCount) * 0.32, 5.5)
            let baseR = CGFloat((4.0 + heatBoost) * min(max(proj.perspective, 0.58), 1.55))
            projected.append(ProjectedStar(
                index: idx,
                node: item.node,
                clusterIndex: item.clusterIndex,
                screen: proj.point,
                depth: proj.depth,
                perspective: proj.perspective,
                radius: baseR
            ))
        }
        projected.sort { $0.depth < $1.depth }
        engine.lastProjected = projected

        var projectedByIndex: [Int: ProjectedStar] = [:]
        projectedByIndex.reserveCapacity(projected.count)
        for star in projected {
            projectedByIndex[star.index] = star
        }

        // Focus neighbor set
        var neighborIndices = Set<Int>()
        if let focusID, let focusIdx = engine.idToIndex[focusID] {
            neighborIndices.insert(focusIdx)
            for edge in engine.edges {
                if edge.sourceIndex == focusIdx { neighborIndices.insert(edge.targetIndex) }
                else if edge.targetIndex == focusIdx { neighborIndices.insert(edge.sourceIndex) }
            }
        }

        let nebulaPalette = theme.galaxyNebulaColors
        let screenCenter = engine.screenCenter(for: size, mode: mode)
        let timeSeconds = now.timeIntervalSinceReferenceDate

        return Canvas { context, canvasSize in
            // 1. Deep Cosmic Sky / Light Observatory Gradient (Zero Dot-Matrix Grid)
            let bgRect = CGRect(origin: .zero, size: canvasSize)
            let skyGradient = Gradient(colors: [theme.galaxySkyTop, theme.galaxySkyBottom])
            context.fill(
                Path(bgRect),
                with: .linearGradient(
                    skyGradient,
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: canvasSize.width, y: canvasSize.height)
                )
            )

            // Subtle atmospheric radial glow behind the galaxy center
            let ambientRadius = max(canvasSize.width, canvasSize.height) * 0.58
            let ambientColor = theme.isDark
                ? Color(red: 36 / 255, green: 62 / 255, blue: 112 / 255).opacity(0.18)
                : Color(red: 147 / 255, green: 197 / 255, blue: 253 / 255).opacity(0.20)
            context.fill(
                Path(bgRect),
                with: .radialGradient(
                    Gradient(colors: [ambientColor, Color.clear]),
                    center: screenCenter,
                    startRadius: 10,
                    endRadius: ambientRadius
                )
            )

            // 2. Distant Parallax Twinkling Stardust
            for dust in engine.stardust {
                let px = (dust.u - engine.yaw * 0.045 * dust.depth).truncatingRemainder(dividingBy: 1.0)
                let py = (dust.v + engine.pitch * 0.045 * dust.depth).truncatingRemainder(dividingBy: 1.0)
                let normX = px < 0 ? px + 1.0 : px
                let normY = py < 0 ? py + 1.0 : py
                let sx = CGFloat(normX) * canvasSize.width
                let sy = CGFloat(normY) * canvasSize.height
                let twinkle = 0.45 + 0.55 * sin(timeSeconds * dust.speed + dust.phase)
                let dustAlpha = (theme.isDark ? 0.34 : 0.24) * dust.depth * twinkle
                let r = dust.size
                context.fill(
                    Path(ellipseIn: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)),
                    with: .color(theme.galaxyStardust.opacity(dustAlpha))
                )
            }

            // 3. Dynamic 3D Nebula Clouds per Cluster (computed live from projected centroids & spread)
            struct ClusterCloud {
                let clusterIndex: Int
                let meta: GalaxyClusterMeta
                let centroid: CGPoint
                let spread: CGFloat
                let avgDepth: Double
                let avgPerspective: Double
                let hasPulse: Bool
            }

            var clouds: [ClusterCloud] = []
            for (cIdx, meta) in engine.clusters.enumerated() {
                let members = projected.filter { $0.clusterIndex == cIdx }
                guard !members.isEmpty else { continue }
                var sumX: CGFloat = 0
                var sumY: CGFloat = 0
                var sumDepth: Double = 0
                var sumPersp: Double = 0
                var hasPulse = false
                for m in members {
                    sumX += m.screen.x
                    sumY += m.screen.y
                    sumDepth += m.depth
                    sumPersp += m.perspective
                    if pulseProgress != nil && pulseIDs.contains(m.node.id) {
                        hasPulse = true
                    }
                }
                let inv = CGFloat(1.0 / Double(members.count))
                let centroid = CGPoint(x: sumX * inv, y: sumY * inv)
                var maxDist: CGFloat = 46
                for m in members {
                    maxDist = max(maxDist, hypot(m.screen.x - centroid.x, m.screen.y - centroid.y))
                }
                clouds.append(ClusterCloud(
                    clusterIndex: cIdx,
                    meta: meta,
                    centroid: centroid,
                    spread: maxDist,
                    avgDepth: sumDepth / Double(members.count),
                    avgPerspective: sumPersp / Double(members.count),
                    hasPulse: hasPulse
                ))
            }
            clouds.sort { $0.avgDepth < $1.avgDepth }

            for cloud in clouds {
                let baseColor = nebulaPalette[cloud.meta.colorIndex % nebulaPalette.count]
                let depthFactor = min(max((cloud.avgDepth + 1.5) / 3.0, 0.35), 1.15)
                let pulseBoost = (cloud.hasPulse && pulseProgress != nil)
                    ? sin((pulseProgress ?? 0) * .pi) * 0.14
                    : 0.0
                let resBoost: Double
                if let rp = resonanceProgress {
                    let distFromCenter = Double(hypot(cloud.centroid.x - screenCenter.x, cloud.centroid.y - screenCenter.y))
                    let waveR = rp * Double(max(canvasSize.width, canvasSize.height)) * 0.65
                    let band = max(0, 1.0 - abs(distFromCenter - waveR) / 140.0)
                    resBoost = band * (1.0 - rp) * 0.22
                } else {
                    resBoost = 0.0
                }

                let outerR = (cloud.spread * 1.48 + 44) * CGFloat(min(max(cloud.avgPerspective, 0.72), 1.35))
                let innerR = outerR * 0.52
                let outerAlpha = (theme.isDark ? 0.16 : 0.13) * depthFactor + pulseBoost + resBoost
                let innerAlpha = (theme.isDark ? 0.22 : 0.16) * depthFactor + pulseBoost + resBoost

                // Outer soft nebula veil
                let outerRect = CGRect(x: cloud.centroid.x - outerR, y: cloud.centroid.y - outerR, width: outerR * 2, height: outerR * 2)
                context.fill(
                    Path(ellipseIn: outerRect),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: baseColor.opacity(min(outerAlpha, 0.42)), location: 0.0),
                            .init(color: baseColor.opacity(min(outerAlpha * 0.42, 0.22)), location: 0.48),
                            .init(color: Color.clear, location: 1.0)
                        ]),
                        center: cloud.centroid,
                        startRadius: 2,
                        endRadius: outerR
                    )
                )

                // Inner luminous core haze
                let innerRect = CGRect(x: cloud.centroid.x - innerR, y: cloud.centroid.y - innerR, width: innerR * 2, height: innerR * 2)
                context.fill(
                    Path(ellipseIn: innerRect),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: baseColor.opacity(min(innerAlpha, 0.48)), location: 0.0),
                            .init(color: Color.clear, location: 1.0)
                        ]),
                        center: cloud.centroid,
                        startRadius: 0,
                        endRadius: innerR
                    )
                )

                // Subtle cluster label floating near the top rim of the nebula
                let labelAlpha = (theme.isDark ? 0.46 : 0.56) * depthFactor
                let resolved = context.resolve(
                    Text(cloud.meta.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(baseColor.opacity(min(labelAlpha, 0.85)))
                )
                let labelY = cloud.centroid.y - min(cloud.spread * 0.78 + 18, outerR * 0.62)
                context.draw(resolved, at: CGPoint(x: cloud.centroid.x, y: labelY), anchor: .center)
            }

            // 4. Dream Resonance Cosmic Wavefront (triggered by "批量做梦" pill)
            if let rp = resonanceProgress {
                let maxR = max(canvasSize.width, canvasSize.height) * 0.68
                for ringIdx in 0..<2 {
                    let localP = rp * 1.15 - Double(ringIdx) * 0.16
                    if localP > 0 && localP < 1 {
                        let eased = 1.0 - pow(1.0 - localP, 2.4)
                        let r = CGFloat(eased) * maxR
                        let fade = (1.0 - localP) * (theme.isDark ? 0.62 : 0.52)
                        let ringRect = CGRect(x: screenCenter.x - r, y: screenCenter.y - r, width: r * 2, height: r * 2)
                        let ringGradient = Gradient(colors: [
                            theme.accent.opacity(fade),
                            theme.agentAntigravity.opacity(fade),
                            theme.scopeGlobal.opacity(fade * 0.9),
                            theme.accent.opacity(fade)
                        ])
                        context.stroke(
                            Path(ellipseIn: ringRect),
                            with: .conicGradient(ringGradient, center: screenCenter, angle: .radians(localP * .pi)),
                            lineWidth: CGFloat((ringIdx == 0 ? 2.6 : 1.5) * (1.0 - localP * 0.55))
                        )
                    }
                }
            }

            // 5. Curved Depth-Modulated Edges
            for edge in engine.edges {
                guard visibleIndexSet.contains(edge.sourceIndex), visibleIndexSet.contains(edge.targetIndex) else { continue }
                if mode == .interactiveFull {
                    switch edge.kind {
                    case .semantic: if !engine.showSemanticEdges { continue }
                    case .duplicate: if !engine.showDuplicateEdges { continue }
                    case .sharedEvidence: if !engine.showSharedEvidenceEdges { continue }
                    }
                }
                guard let s1 = projectedByIndex[edge.sourceIndex], let s2 = projectedByIndex[edge.targetIndex] else { continue }

                let avgDepth = (s1.depth + s2.depth) * 0.5
                let depthAlpha = min(max((avgDepth + 1.5) / 2.8, 0.22), 1.0)
                let touchesFocus = focusID != nil && (s1.node.id == focusID || s2.node.id == focusID)
                let dimmed = (focusID != nil && !touchesFocus) || (hasSearch && !matches.contains(s1.node.id) && !matches.contains(s2.node.id))

                // Gentle quadratic arc
                let mid = CGPoint(x: (s1.screen.x + s2.screen.x) * 0.5, y: (s1.screen.y + s2.screen.y) * 0.5)
                let dx = s2.screen.x - s1.screen.x
                let dy = s2.screen.y - s1.screen.y
                let dist = max(hypot(dx, dy), 1)
                let curveOffset = min(dist * 0.14, 26) * (edge.sameCluster ? 1.0 : -1.0)
                let control = CGPoint(x: mid.x - (dy / dist) * curveOffset, y: mid.y + (dx / dist) * curveOffset)

                var path = Path()
                path.move(to: s1.screen)
                path.addQuadCurve(to: s2.screen, control: control)

                switch edge.kind {
                case .semantic:
                    let baseAlpha = min(max(0.16 + edge.weight * 0.40, 0.16), 0.62) * depthAlpha
                    if edge.sameCluster {
                        let color = touchesFocus
                            ? theme.accent.opacity(0.85)
                            : theme.galaxyEdge.opacity(dimmed ? 0.10 : baseAlpha)
                        context.stroke(path, with: .color(color), lineWidth: touchesFocus ? 1.65 : 1.0)
                    } else {
                        let color = touchesFocus
                            ? theme.accent.opacity(0.75)
                            : theme.galaxyEdge.opacity(dimmed ? 0.08 : baseAlpha * 0.65)
                        context.stroke(
                            path,
                            with: .color(color),
                            style: StrokeStyle(lineWidth: touchesFocus ? 1.4 : 0.85, dash: [2.5, 4.5])
                        )
                    }
                case .duplicate:
                    let color = theme.warning.opacity(dimmed ? 0.18 : (touchesFocus ? 0.95 : 0.72 * depthAlpha))
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: touchesFocus ? 2.0 : 1.35, dash: [5, 4])
                    )
                case .sharedEvidence:
                    let color = theme.info.opacity(dimmed ? 0.14 : (touchesFocus ? 0.85 : 0.46 * depthAlpha))
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: touchesFocus ? 1.55 : 1.0, dash: [2, 3])
                    )
                }
            }

            // 6. Luminous 3D Stars (Back-to-Front Depth Order, Smooth Radial Glows)
            var drawnLabelRects: [CGRect] = []
            for star in projected {
                let p = star.screen
                let isHovered = star.node.id == hoveredID
                let isSelected = star.node.id == selectedID
                let isMatch = matches.contains(star.node.id)
                let isPulsing = pulseProgress != nil && pulseIDs.contains(star.node.id)
                let isNeighbor = focusID == nil || neighborIndices.contains(star.index)

                let clusterMeta = engine.clusters[star.clusterIndex]
                let starColor = nebulaPalette[clusterMeta.colorIndex % nebulaPalette.count]
                let depthFactor = min(max((star.depth + 1.55) / 2.85, 0.30), 1.0)

                var alpha = (star.node.isDormant ? 0.36 : (0.54 + 0.46 * min(max(star.node.freshness, 0), 1))) * depthFactor
                if hasSearch && !isMatch { alpha *= 0.20 }
                else if !isNeighbor && !isMatch { alpha *= 0.26 }
                if isHovered || isSelected || isMatch || isPulsing { alpha = 1.0 }

                // Dream resonance momentary star flare
                var resonanceFlare: Double = 0
                if let rp = resonanceProgress {
                    let distFromCenter = Double(hypot(p.x - screenCenter.x, p.y - screenCenter.y))
                    let waveR = rp * Double(max(canvasSize.width, canvasSize.height)) * 0.68
                    let band = max(0, 1.0 - abs(distFromCenter - waveR) / 72.0)
                    resonanceFlare = band * (1.0 - rp)
                }

                let r = star.radius * (isHovered ? 1.24 : (1.0 + CGFloat(resonanceFlare) * 0.35))

                // Real-time hit pulse dual expanding rings
                if let progress = pulseProgress, isPulsing {
                    for ringIdx in 0..<2 {
                        let shifted = progress * 1.45 - Double(ringIdx) * 0.34
                        if shifted > 0 && shifted < 1 {
                            let ringR = r + CGFloat(shifted) * 38
                            let ringAlpha = (1.0 - shifted) * 0.78
                            let ringRect = CGRect(x: p.x - ringR, y: p.y - ringR, width: ringR * 2, height: ringR * 2)
                            context.stroke(
                                Path(ellipseIn: ringRect),
                                with: .color(pulseColor.opacity(ringAlpha)),
                                lineWidth: 2.0 * CGFloat(1.0 - shifted * 0.5)
                            )
                        }
                    }
                }

                // Smooth radial aura (replaces hard double solid circles)
                let auraRadius = r * ((isHovered || isSelected || isMatch) ? 3.8 : (2.9 + CGFloat(resonanceFlare) * 1.2))
                let auraRect = CGRect(x: p.x - auraRadius, y: p.y - auraRadius, width: auraRadius * 2, height: auraRadius * 2)
                context.fill(
                    Path(ellipseIn: auraRect),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: starColor.opacity(min(alpha * (theme.isDark ? 0.58 : 0.42) + resonanceFlare * 0.35, 0.92)), location: 0.0),
                            .init(color: starColor.opacity(alpha * (theme.isDark ? 0.22 : 0.14)), location: 0.42),
                            .init(color: Color.clear, location: 1.0)
                        ]),
                        center: p,
                        startRadius: 0,
                        endRadius: auraRadius
                    )
                )

                // Bright luminous star core
                let coreRect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                let coreCenterColor = theme.isDark
                    ? Color.white.opacity(min(alpha * 0.95 + resonanceFlare * 0.2, 1.0))
                    : Color.white.opacity(0.92)
                context.fill(
                    Path(ellipseIn: coreRect),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: coreCenterColor, location: 0.0),
                            .init(color: starColor.opacity(min(alpha, 1.0)), location: 0.55),
                            .init(color: starColor.opacity(alpha * 0.55), location: 1.0)
                        ]),
                        center: p,
                        startRadius: 0,
                        endRadius: r
                    )
                )

                // Selection / match / dormant subtle ring
                if isSelected || isHovered || isMatch {
                    let ringR = r + 4.0
                    let ringRect = CGRect(x: p.x - ringR, y: p.y - ringR, width: ringR * 2, height: ringR * 2)
                    context.stroke(
                        Path(ellipseIn: ringRect),
                        with: .color((isMatch ? theme.warning : theme.textPrimary).opacity(0.88)),
                        lineWidth: 1.35
                    )
                } else if star.node.isDormant {
                    let ringR = r + 2.8
                    let ringRect = CGRect(x: p.x - ringR, y: p.y - ringR, width: ringR * 2, height: ringR * 2)
                    context.stroke(
                        Path(ellipseIn: ringRect),
                        with: .color(theme.textTertiary.opacity(0.45 * depthFactor)),
                        style: StrokeStyle(lineWidth: 0.9, dash: [2, 2])
                    )
                }

                // Selective non-overlapping labels (foreground stars or selected/matched)
                let shouldShowLabel = isSelected || isMatch || isPulsing ||
                    (mode == .interactiveFull && depthFactor > 0.78 && (engine.effectiveScale >= 1.25 || projected.count <= 22))
                if shouldShowLabel && !isHovered {
                    let shortTitle = star.node.title.count > 16 ? String(star.node.title.prefix(15)) + "…" : star.node.title
                    let labelPoint = CGPoint(x: p.x, y: p.y + r + 10)
                    let estWidth = CGFloat(shortTitle.count) * 7.2 + 12
                    let estRect = CGRect(x: labelPoint.x - estWidth / 2, y: labelPoint.y - 8, width: estWidth, height: 16)
                    let collides = drawnLabelRects.contains { $0.intersects(estRect.insetBy(dx: -4, dy: -2)) }
                    if !collides || isSelected || isMatch || isPulsing {
                        drawnLabelRects.append(estRect)
                        let resolved = context.resolve(
                            Text(shortTitle)
                                .font(.system(size: 10, weight: (isSelected || isMatch) ? .semibold : .medium))
                                .foregroundStyle(theme.textPrimary.opacity((isSelected || isMatch) ? 0.95 : 0.78 * depthFactor))
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
                    if engine.lastDragLocation == nil {
                        if let grabbed = engine.hitTestProjected(at: value.startLocation) {
                            engine.draggedNodeIndex = grabbed.index
                            engine.isDraggingSpace = false
                        } else {
                            engine.draggedNodeIndex = nil
                            engine.isDraggingSpace = true
                            engine.yawVelocity = 0
                            engine.pitchVelocity = 0
                        }
                        engine.lastDragLocation = value.startLocation
                    }

                    let prev = engine.lastDragLocation ?? value.startLocation
                    let delta = CGSize(
                        width: value.location.x - prev.x,
                        height: value.location.y - prev.y
                    )
                    engine.lastDragLocation = value.location

                    if let draggedIdx = engine.draggedNodeIndex, draggedIdx < engine.nodes.count {
                        let depth = engine.rotateToCamera(engine.nodes[draggedIdx].position).z
                        let wDelta = engine.worldDelta(forScreenDelta: delta, atDepth: depth, in: size, mode: mode)
                        engine.nodes[draggedIdx].position += wDelta
                        engine.nodes[draggedIdx].velocity = .zero
                    } else if engine.isDraggingSpace {
                        let sensitivity = 0.0068
                        engine.yaw += Double(delta.width) * sensitivity
                        engine.pitch = min(max(engine.pitch + Double(delta.height) * sensitivity, -1.25), 1.25)
                        engine.yawVelocity = Double(delta.width) * sensitivity * 16.0
                        engine.pitchVelocity = Double(delta.height) * sensitivity * 16.0
                    }
                }
                .onEnded { _ in
                    engine.draggedNodeIndex = nil
                    engine.isDraggingSpace = false
                    engine.lastDragLocation = nil
                }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    engine.pinchMagnification = value
                }
                .onEnded { value in
                    engine.scale = min(max(engine.scale * value, 0.55), 2.8)
                    engine.pinchMagnification = 1.0
                }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    if let hitStar = engine.hitTestProjected(at: value.location) {
                        onSelectMemoryID(hitStar.node.id)
                    }
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                engine.hoverLocation = location
                if engine.draggedNodeIndex == nil && !engine.isDraggingSpace {
                    engine.hoveredNodeID = engine.hitTestProjected(at: location)?.node.id
                }
            case .ended:
                engine.hoveredNodeID = nil
            }
        }
    }

    // MARK: - Interactive Full-Screen Floating Liquid Glass Controls

    private var interactiveFullOverlay: some View {
        ZStack {
            // Top floating Liquid Glass filter/search bar
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(theme.textTertiary)
                        TextField("搜索星图节点标题或项目，回车聚焦…", text: $engine.searchText)
                            .textFieldStyle(.plain)
                            .onSubmit { engine.focusOn(nodeIDs: searchMatchedIDs) }
                        if !engine.searchText.isEmpty {
                            Button {
                                engine.searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        if !searchMatchedIDs.isEmpty {
                            Button("聚焦 (\(searchMatchedIDs.count))") {
                                engine.focusOn(nodeIDs: searchMatchedIDs)
                            }
                            .buttonStyle(SoftActionButtonStyle(tint: theme.accent, compact: true))
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6.5)
                    .background(theme.surfacePrimary.opacity(theme.isDark ? 0.55 : 0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(theme.hairlineBorder, lineWidth: 1)
                    )

                    SegmentedPillBar(
                        options: GalaxyScopeFilter.allCases,
                        selection: $engine.scopeFilter,
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
                    edgeTogglePill("语义连线", isOn: $engine.showSemanticEdges, tint: theme.accent)
                    edgeTogglePill("疑似重复", isOn: $engine.showDuplicateEdges, tint: theme.warning)
                    edgeTogglePill("同源证据", isOn: $engine.showSharedEvidenceEdges, tint: theme.info)
                    edgeTogglePill("隐藏沉睡", isOn: $engine.hideDormant, tint: theme.textSecondary)

                    if engine.scopeFilter == .project && !knownProjects.isEmpty {
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

                    HStack(spacing: 6) {
                        ScorePill(label: "星系", value: "\(engine.clusters.count)", tint: theme.scopeGlobal)
                        ScorePill(label: "星点", value: "\(engine.lastProjected.count)", tint: theme.accent)
                        let dupCount = model.memoryGraph.edges.filter { $0.kind == .duplicate }.count
                        if dupCount > 0 {
                            ScorePill(label: "疑似重复", value: "\(dupCount)", tint: theme.warning)
                        }
                    }
                }
            }
            .padding(12)
            .liquidGlassSurface(cornerRadius: 15)
            .padding(.leading, 80)
            .padding(.trailing, 18)
            .padding(.top, 98)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Empty state when no nodes exist
            if model.memoryGraph.nodes.isEmpty {
                EmptyStateCard(
                    icon: "sparkles",
                    title: "星图等待记忆点亮",
                    description: "当 Agent 沉淀长期记忆并完成向量索引后，这里将以 3D 弹性星系呈现记忆簇、相似连线与命中脉搏。",
                    actionTitle: "刷新星图"
                ) {
                    model.refreshMemoryGraph()
                }
                .frame(maxWidth: 420)
            }

            // Bottom-left legend + live hit pulse indicator
            VStack(alignment: .leading, spacing: 6) {
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .liquidGlassCapsule()
                }

                HStack(spacing: 10) {
                    legendDot("全局星系", color: theme.scopeGlobal)
                    legendDot("项目星系", color: theme.scopeProject)
                    legendLine("疑似重复", color: theme.warning, dashed: true)
                    legendLine("同源证据", color: theme.info, dashed: true)
                    Text("· 拖空白旋转 · 抓星点拉扯")
                        .font(.caption2)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .liquidGlassCapsule()
            }
            .padding(.leading, 80)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)

            // Bottom-right zoom / auto-rotate / reset capsule
            HStack(spacing: 4) {
                Button {
                    engine.isAutoRotating.toggle()
                } label: {
                    Image(systemName: engine.isAutoRotating ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(engine.isAutoRotating ? "暂停星系自转" : "恢复星系自转")

                Divider().frame(height: 14).overlay(theme.hairlineBorder)

                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        engine.scale = max(engine.scale / 1.25, 0.55)
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("缩小")

                Text("\(Int((engine.effectiveScale * 100).rounded()))%")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 40)

                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        engine.scale = min(engine.scale * 1.25, 2.8)
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("放大")

                Divider().frame(height: 14).overlay(theme.hairlineBorder)

                Button {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                        engine.resetView()
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("重置 3D 视角")
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .liquidGlassCapsule()
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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
            .background(isOn.wrappedValue ? tint.opacity(theme.isDark ? 0.16 : 0.11) : theme.surfaceSecondary.opacity(0.75), in: Capsule())
            .overlay(
                Capsule().stroke(isOn.wrappedValue ? tint.opacity(0.34) : theme.hairlineBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func projectChip(title: String, path: String?) -> some View {
        let active = engine.selectedProject == path
        return Button {
            engine.selectedProject = path
        } label: {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(active ? theme.accent : theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(active ? theme.accentSoft : theme.surfacePrimary.opacity(0.75), in: Capsule())
                .overlay(Capsule().stroke(active ? theme.accentBorder : theme.hairlineBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(path ?? "显示所有项目记忆")
    }

    // MARK: - Hover Tooltip & Legend

    private func hoverTooltip(for star: ProjectedStar, in size: CGSize) -> some View {
        let clampedX = min(max(star.screen.x, 145), max(size.width - 145, 145))
        let clampedY = star.screen.y > 120 ? star.screen.y - 58 : star.screen.y + 60

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ScopeTag(projectPath: star.node.project)
                if star.node.isDormant {
                    ScorePill(label: "活性", value: "沉睡", tint: theme.warning)
                }
            }
            Text(star.node.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("命中 \(star.node.hitCount) 次")
                    .monospacedDigit()
                Text("· 证据 \(star.node.evidenceCount)")
                    .monospacedDigit()
                Text("· 活性 \(Int((star.node.freshness * 100).rounded()))%")
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 256, alignment: .leading)
        .liquidGlassSurface(cornerRadius: 12, highlighted: true)
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
