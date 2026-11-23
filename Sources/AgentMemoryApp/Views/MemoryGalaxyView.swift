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
    let label: String
    let colorIndex: Int
}

private struct GalaxyPhysicsNode {
    let node: MemoryGraphNode
    let clusterIndex: Int
    let home: Vec3
    let prominence: Double
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
    var screen: CGPoint
    let depth: Double          // rotated Z (larger = closer to viewer)
    let perspective: Double    // scale factor from perspective projection
    let radius: CGFloat
}

private struct GalaxyCloud {
    let meta: GalaxyClusterMeta
    let centroid: CGPoint
    let spread: CGFloat
    let bounds: CGRect
    let memberCount: Int
    let avgDepth: Double
    let avgPerspective: Double
    let hasPulse: Bool
}

private struct ProjectionCell: Hashable {
    let column: Int
    let row: Int

    init(point: CGPoint) {
        column = Int(floor(point.x / 24))
        row = Int(floor(point.y / 24))
    }

    init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
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
    private static let defaultYaw: Double = 0.35
    private static let defaultPitch: Double = 0.56
    var yaw: Double = defaultYaw
    var pitch: Double = defaultPitch
    var zoomScale: Double = 1.0
    var yawVelocity: Double = 0
    var pitchVelocity: Double = 0
    var autoRotateSpeedFactor: Double = 1.0
    var lastTickDate: Date?
    var lastInteractionDate: Date = .distantPast
    var isSmoothResetting: Bool = false

    // Drag interaction state
    var isDraggingSpace = false
    var draggedNodeIndex: Int? = nil
    var lastDragLocation: CGPoint? = nil

    // SwiftUI-observed lightweight UI state
    @Published var isAutoRotating = true
    @Published var displayedZoomPercent: Int = 100
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
        min(max(CGFloat(zoomScale) * pinchMagnification, 0.55), 2.8)
    }

    func markInteraction() {
        lastInteractionDate = Date()
        isSmoothResetting = false
    }

    func setZoomScale(_ newValue: Double) {
        zoomScale = min(max(newValue, 0.55), 2.8)
        let pct = Int((effectiveScale * 100).rounded())
        if displayedZoomPercent != pct {
            displayedZoomPercent = pct
        }
    }

    func beginSmoothReset() {
        isSmoothResetting = true
        yawVelocity = 0
        pitchVelocity = 0
        pinchMagnification = 1.0
    }

    private static let globalKey = "__global__"
    private static let goldenAngle = Double.pi * (3 - sqrt(5))

    private static func clusterKey(for node: MemoryGraphNode) -> String {
        guard node.scope != "global", let project = node.project, !project.isEmpty else { return globalKey }
        return project
    }

    static func clusterCount(for graph: MemoryGraph) -> Int {
        Set(graph.nodes.map(clusterKey)).count
    }

    func syncGraph(_ graph: MemoryGraph) {
        let sig = "\(graph.generatedAt.timeIntervalSince1970)-\(graph.nodes.count)-\(graph.edges.count)"
        guard sig != graphSignature else { return }
        graphSignature = sig

        let oldNodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.node.id, $0) })
        let draggedID = draggedNodeIndex.flatMap { nodes.indices.contains($0) ? nodes[$0].node.id : nil }
        let groups = Dictionary(grouping: graph.nodes, by: Self.clusterKey)
        let keys = groups.keys.sorted { a, b in
            if a == Self.globalKey || b == Self.globalKey { return a == Self.globalKey && b != Self.globalKey }
            return a < b
        }

        var connectivity: [String: Double] = [:]
        for edge in graph.edges {
            let contribution = 0.5 + edge.weight
            connectivity[edge.sourceID, default: 0] += contribution
            connectivity[edge.targetID, default: 0] += contribution
        }

        var builtClusters: [GalaxyClusterMeta] = []
        var builtNodes: [GalaxyPhysicsNode] = []
        var lookup: [String: Int] = [:]
        builtNodes.reserveCapacity(graph.nodes.count)

        for (index, key) in keys.enumerated() {
            guard let members = groups[key] else { continue }
            let isGlobal = key == Self.globalKey
            let name = URL(fileURLWithPath: key).lastPathComponent
            let colorIndex = isGlobal ? 0 : (1 + Int(Self.stableUnitHash(key) * 5))
            builtClusters.append(GalaxyClusterMeta(label: isGlobal ? "全局记忆" : (name.isEmpty ? key : name), colorIndex: colorIndex))

            let anchor = Self.clusterAnchor(index: index, count: keys.count)
            let ranked = members.map { node in
                let score = 2 * log1p(Double(node.hitCount)) + 1.5 * log1p(connectivity[node.id, default: 0])
                return (node: node, score: score)
            }.sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                if left.node.updated != right.node.updated { return left.node.updated > right.node.updated }
                return left.node.id < right.node.id
            }

            for (rank, member) in ranked.enumerated() {
                let node = member.node
                let home = anchor + Self.orbitOffset(rank: rank, count: ranked.count, id: node.id)
                let prominence = 0.80 * exp(-Double(rank) * 0.48) + min(member.score / 18, 0.20)
                let previous = oldNodes[node.id].flatMap { Self.clusterKey(for: $0.node) == key ? $0 : nil }
                lookup[node.id] = builtNodes.count
                builtNodes.append(GalaxyPhysicsNode(
                    node: node,
                    clusterIndex: index,
                    home: home,
                    prominence: prominence,
                    position: previous?.position ?? home,
                    velocity: previous?.velocity ?? .zero
                ))
            }
        }

        clusters = builtClusters
        nodes = builtNodes
        idToIndex = lookup
        edges = graph.edges.compactMap { edge in
            guard let source = lookup[edge.sourceID], let target = lookup[edge.targetID], source != target else { return nil }
            return GalaxyPhysicsEdge(
                sourceIndex: source,
                targetIndex: target,
                kind: edge.kind,
                weight: edge.weight,
                sameCluster: builtNodes[source].clusterIndex == builtNodes[target].clusterIndex
            )
        }
        draggedNodeIndex = draggedID.flatMap { lookup[$0] }
        lastProjected = []

        if oldNodes.isEmpty {
            for _ in 0..<16 { stepPhysics(dt: 1.0 / 60.0) }
        }
    }

    private static func clusterAnchor(index: Int, count: Int) -> Vec3 {
        if count == 1 { return .zero }
        if count == 2 {
            let sign = index == 0 ? -1.0 : 1.0
            return Vec3(x: sign * 0.76, y: sign * 0.18, z: sign * 0.12)
        }

        let latitude = 1 - 2 * (Double(index) + 0.5) / Double(count)
        let ring = sqrt(1 - latitude * latitude)
        let azimuth = goldenAngle * Double(index) + 0.4
        let shell = count <= 5 ? 0.85 : 1.0
        return Vec3(
            x: cos(azimuth) * ring * shell,
            y: latitude * 0.67 * shell,
            z: sin(azimuth) * ring * shell
        )
    }

    private static func orbitOffset(rank: Int, count: Int, id: String) -> Vec3 {
        guard rank > 0 else { return .zero }
        let spread = min(0.17 + pow(Double(count), 1.0 / 3.0) * 0.118, 0.96)
        let fraction = Double(rank) / Double(count - 1)
        let jitter = stableUnitHash(id)
        let radius = spread * (0.22 + 0.78 * pow(fraction, 1.0 / 3.0)) * (0.92 + jitter * 0.16)
        let azimuth = goldenAngle * Double(rank) + jitter * 0.55
        let latitude = (Double(rank) * 0.754877666).truncatingRemainder(dividingBy: 1) * 2 - 1
        let ring = sqrt(1 - latitude * latitude)
        return Vec3(
            x: cos(azimuth) * ring * radius,
            y: latitude * radius * 0.72,
            z: sin(azimuth) * ring * radius
        )
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
            if !isSmoothResetting {
                yaw += (0.038 * autoRotateSpeedFactor + yawVelocity) * dt
                pitch += pitchVelocity * dt
                let inertiaDecay = pow(0.06, dt)
                yawVelocity *= inertiaDecay
                pitchVelocity *= inertiaDecay
                if abs(yawVelocity) < 0.001 { yawVelocity = 0 }
                if abs(pitchVelocity) < 0.001 { pitchVelocity = 0 }
            }

            // Gently clamp pitch so universe never flips awkwardly upside down
            if pitch > 1.15 {
                pitch += (1.15 - pitch) * min(dt * 8.0, 1.0)
            } else if pitch < -1.15 {
                pitch += (-1.15 - pitch) * min(dt * 8.0, 1.0)
            }

            // Auto-recenter & zoom reset in ambientBackdrop after 3.0s idle without hovering a node
            let isPinching = abs(pinchMagnification - 1.0) >= 0.001
            if lastMode == .ambientBackdrop {
                if draggedNodeIndex == nil && !isPinching && hoveredNodeID == nil && now.timeIntervalSince(lastInteractionDate) >= 3.0 {
                    let lerpFactor = 1.0 - exp(-dt * 2.2)
                    if abs(zoomScale - 1.0) > 0.001 {
                        zoomScale += (1.0 - zoomScale) * lerpFactor
                    } else {
                        zoomScale = 1.0
                    }
                    if abs(pitch - Self.defaultPitch) > 0.001 {
                        pitch += (Self.defaultPitch - pitch) * lerpFactor
                    } else {
                        pitch = Self.defaultPitch
                    }
                }
            } else if isSmoothResetting {
                let lerpFactor = 1.0 - exp(-dt * 5.2)
                zoomScale += (1.0 - zoomScale) * lerpFactor
                pitch += (Self.defaultPitch - pitch) * lerpFactor

                let twoPi = Double.pi * 2.0
                var yawDiff = (Self.defaultYaw - yaw).truncatingRemainder(dividingBy: twoPi)
                if yawDiff > Double.pi { yawDiff -= twoPi }
                if yawDiff < -Double.pi { yawDiff += twoPi }
                yaw += yawDiff * lerpFactor

                let pct = Int((effectiveScale * 100).rounded())
                if displayedZoomPercent != pct {
                    Task { @MainActor [weak self] in
                        self?.displayedZoomPercent = pct
                    }
                }

                if abs(zoomScale - 1.0) < 0.002 && abs(pitch - Self.defaultPitch) < 0.002 && abs(yawDiff) < 0.002 {
                    zoomScale = 1.0
                    pitch = Self.defaultPitch
                    isSmoothResetting = false
                    if displayedZoomPercent != 100 {
                        Task { @MainActor [weak self] in
                            self?.displayedZoomPercent = 100
                        }
                    }
                }
            }
        }

        stepPhysics(dt: dt)
    }

    private func stepPhysics(dt: Double) {
        let count = nodes.count
        guard count > 0 else { return }

        var forces = Array(repeating: Vec3.zero, count: count)

        // The highest-ranked star is tethered to the core. Companions have individual orbital offsets.
        for i in nodes.indices {
            let node = nodes[i]
            forces[i] += (node.home - node.position) * (3.0 + node.prominence * 5.5)
        }

        // Intra-galaxy links let related companions form groups within the same gravitational field.
        for edge in edges {
            let a = edge.sourceIndex
            let b = edge.targetIndex
            let delta = nodes[b].position - nodes[a].position
            let distance = max(delta.length, 0.004)
            let restLength: Double
            let stiffness: Double
            if edge.sameCluster {
                switch edge.kind {
                case .duplicate:
                    restLength = 0.25
                    stiffness = 1.45
                case .semantic:
                    restLength = 0.33
                    stiffness = 0.78 * max(edge.weight, 0.35)
                case .sharedEvidence:
                    restLength = 0.31
                    stiffness = 0.82
                }
            } else {
                let homeDistance = (nodes[a].home - nodes[b].home).length
                restLength = max(homeDistance, 0.52)
                stiffness = 0.08
            }
            let force = delta * ((distance - restLength) / distance * stiffness)
            forces[a] += force
            forces[b] += force * -1
        }

        let localClearance = count > 180 ? 0.19 : 0.24
        for i in nodes.indices {
            let first = nodes[i]
            for j in (i + 1)..<count {
                let second = nodes[j]
                let sameCluster = first.clusterIndex == second.clusterIndex
                let cutoff = sameCluster ? localClearance : 0.37
                let delta = first.position - second.position
                let distanceSquared = delta.lengthSq
                guard distanceSquared < cutoff * cutoff else { continue }

                let distance = sqrt(distanceSquared)
                let direction = distance > 0.0001 ? delta * (1 / distance) : Vec3(x: 1, y: 0, z: 0)
                let overlap = cutoff - distance
                let strength = sameCluster ? 13.0 : 21.0
                let push = direction * (overlap * strength * (1 + overlap / cutoff))
                forces[i] += push
                forces[j] += push * -1
            }
        }

        // 4. Integrate with elastic damping
        let damping = pow(0.035, dt)
        for i in 0..<count {
            if draggedNodeIndex == i {
                nodes[i].velocity = .zero
                continue
            }
            nodes[i].velocity = (nodes[i].velocity + forces[i] * dt) * damping
            nodes[i].position += nodes[i].velocity * dt

            // Soft spherical boundary to keep universe cohesive
            let lenSq = nodes[i].position.lengthSq
            if lenSq > 4.0 {
                let inv = sqrt(4.0 / lenSq)
                nodes[i].position = nodes[i].position * inv
            }
        }
    }

    // MARK: - 3D Projection & Camera Basis

    func screenCenter(for size: CGSize, mode: MemoryGalaxyMode) -> CGPoint {
        switch mode {
        case .ambientBackdrop:
            return CGPoint(x: size.width * 0.56, y: size.height * 0.48)
        case .interactiveFull:
            return CGPoint(x: size.width * 0.50, y: size.height * 0.50)
        }
    }

    private func projectionScale(for size: CGSize, mode: MemoryGalaxyMode) -> CGSize {
        if mode == .ambientBackdrop {
            return CGSize(width: size.width * 0.40 * effectiveScale, height: size.height * 0.39 * effectiveScale)
        }
        let uniform = max(min(size.width, size.height) * 0.40, 150) * effectiveScale
        return CGSize(width: uniform, height: uniform)
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
        let scale = projectionScale(for: size, mode: mode)
        let center = screenCenter(for: size, mode: mode)
        let sx = center.x + CGFloat(cam.x * persp) * scale.width
        let sy = center.y - CGFloat(cam.y * persp) * scale.height
        return (CGPoint(x: sx, y: sy), cam.z, persp)
    }

    /// Converts a 2D screen drag delta into a 3D world-space displacement along the camera plane.
    func worldDelta(forScreenDelta delta: CGSize, atDepth depth: Double, in size: CGSize, mode: MemoryGalaxyMode) -> Vec3 {
        let cameraDist = 3.25
        let persp = 2.65 / max(cameraDist - depth, 0.55)
        let scale = projectionScale(for: size, mode: mode)
        let camDx = Double(delta.width) / max(scale.width * persp, 40)
        let camDy = -Double(delta.height) / max(scale.height * persp, 40)

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
        yaw = Self.defaultYaw
        pitch = Self.defaultPitch
        yawVelocity = 0
        pitchVelocity = 0
        isSmoothResetting = false
        pinchMagnification = 1.0
        setZoomScale(1.0)
    }

    func focusOn(nodeIDs: Set<String>) {
        let matched = nodes.filter { nodeIDs.contains($0.node.id) }
        guard !matched.isEmpty else { return }
        markInteraction()
        var avg = Vec3.zero
        for m in matched { avg += m.position }
        avg = avg * (1.0 / Double(matched.count))
        let targetYaw = -atan2(avg.x, max(abs(avg.z), 0.15))
        let targetPitch = min(max(atan2(avg.y, max(sqrt(avg.x * avg.x + avg.z * avg.z), 0.25)), -0.9), 0.9)
        yaw = targetYaw
        pitch = targetPitch
        yawVelocity = 0
        pitchVelocity = 0
        setZoomScale(matched.count == 1 ? 1.55 : 1.30)
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
    var isPaused: Bool = false
    var isSidebarExpanded: Bool = false
    var dreamResonanceTrigger: Date? = nil
    let onSelectMemoryID: (String) -> Void
    var onClearSelection: (() -> Void)? = nil

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
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { timeline in
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
            .onChange(of: isPaused) { _, paused in
                if !paused {
                    engine.lastTickDate = nil
                }
            }
            .onChange(of: model.memoryGraph) { _, newGraph in
                engine.syncGraph(newGraph)
            }
        }
    }

    // The camera can project distant stars onto the same point despite their world-space separation.
    private func separateProjectedStars(_ stars: inout [ProjectedStar], pinnedIndex: Int?) {
        guard stars.count > 1 else { return }
        let origins = stars.map(\.screen)
        for _ in 0..<3 {
            let cells = stars.map { ProjectionCell(point: $0.screen) }
            let buckets = Dictionary(grouping: stars.indices) { cells[$0] }
            var moved = false
            for first in stars.indices {
                let cell = cells[first]
                for row in (cell.row - 1)...(cell.row + 1) {
                    for column in (cell.column - 1)...(cell.column + 1) {
                        for second in buckets[ProjectionCell(column: column, row: row)] ?? [] where second > first {
                            let a = stars[first]
                            let b = stars[second]
                            let dx = a.screen.x - b.screen.x
                            let dy = a.screen.y - b.screen.y
                            let distance = hypot(dx, dy)
                            let clearance = a.radius + b.radius + 2.2
                            guard distance < clearance else { continue }

                            let direction = distance > 0.01 ? CGPoint(x: dx / distance, y: dy / distance) : CGPoint(x: 1, y: 0)
                            let overlap = clearance - distance
                            let share: CGFloat
                            if a.index == pinnedIndex {
                                share = 0
                            } else if b.index == pinnedIndex {
                                share = 1
                            } else {
                                share = b.radius / (a.radius + b.radius)
                            }
                            stars[first].screen = projectedOffset(a.screen, origin: origins[first], direction: direction, distance: overlap * share)
                            stars[second].screen = projectedOffset(b.screen, origin: origins[second], direction: direction, distance: -overlap * (1 - share))
                            moved = true
                        }
                    }
                }
            }
            if !moved { break }
        }
    }

    private func projectedOffset(_ point: CGPoint, origin: CGPoint, direction: CGPoint, distance: CGFloat) -> CGPoint {
        let x = point.x + direction.x * distance - origin.x
        let y = point.y + direction.y * distance - origin.y
        let limit = min(1, 18 / max(hypot(x, y), 1))
        return CGPoint(x: origin.x + x * limit, y: origin.y + y * limit)
    }

    private func drawGalaxyLabels(
        in context: GraphicsContext,
        size: CGSize,
        clouds: [GalaxyCloud],
        palette: [Color]
    ) {
        let viewport = CGRect(x: -40, y: 24, width: size.width + 80, height: max(0, size.height - 44))
        for cloud in clouds where cloud.bounds.intersects(viewport) {
            let label = cloud.meta.label
            let title = label.count > 24 ? String(label.prefix(23)) + "…" : label
            let baseColor = palette[cloud.meta.colorIndex % palette.count]
            let depthAlpha = min(max((cloud.avgDepth + 1.55) / 2.85, 0.44), 0.94)
            let anchorY = max(32, min(size.height - 22, cloud.bounds.minY - 11))
            let anchorX = min(max(cloud.centroid.x, 36), max(size.width - 36, 36))
            let text = context.resolve(
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(baseColor.opacity(depthAlpha))
            )
            context.draw(text, at: CGPoint(x: anchorX, y: anchorY), anchor: .center)
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
        var projected: [ProjectedStar] = []
        projected.reserveCapacity(engine.nodes.count)

        for (idx, item) in engine.nodes.enumerated() {
            guard isNodeVisible(item.node) else { continue }
            let proj = engine.project(item.position, in: size, mode: mode)
            let baseR = CGFloat((2.05 + item.prominence * 4.7) * min(max(proj.perspective, 0.72), 1.25))
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
        separateProjectedStars(&projected, pinnedIndex: engine.draggedNodeIndex ?? focusID.flatMap { engine.idToIndex[$0] })
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
            let ambientColor = theme.galaxyAtmosphere.opacity(theme.isDark ? 0.18 : 0.20)
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
            var clouds: [GalaxyCloud] = []
            let clusterMembers = Dictionary(grouping: projected, by: \.clusterIndex)
            for (index, meta) in engine.clusters.enumerated() {
                guard let members = clusterMembers[index], !members.isEmpty else { continue }
                var sumX: CGFloat = 0
                var sumY: CGFloat = 0
                var sumDepth: Double = 0
                var sumPerspective: Double = 0
                var bounds = CGRect.null
                for star in members {
                    sumX += star.screen.x
                    sumY += star.screen.y
                    sumDepth += star.depth
                    sumPerspective += star.perspective
                    let extent = star.radius + 5
                    bounds = bounds.union(CGRect(
                        x: star.screen.x - extent, y: star.screen.y - extent,
                        width: extent * 2, height: extent * 2
                    ))
                }
                let count = Double(members.count)
                let centroid = CGPoint(x: sumX / count, y: sumY / count)
                let spread = members.reduce(CGFloat(42)) {
                    max($0, hypot($1.screen.x - centroid.x, $1.screen.y - centroid.y))
                }
                clouds.append(GalaxyCloud(
                    meta: meta, centroid: centroid, spread: spread, bounds: bounds, memberCount: members.count,
                    avgDepth: sumDepth / count, avgPerspective: sumPerspective / count,
                    hasPulse: pulseProgress != nil && members.contains { pulseIDs.contains($0.node.id) }
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
                guard edge.sameCluster || touchesFocus else { continue }
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
                    let baseAlpha = (0.14 + edge.weight * 0.28) * depthAlpha
                    if edge.sameCluster {
                        let color = touchesFocus
                            ? theme.accent.opacity(0.85)
                            : theme.galaxyEdge.opacity(dimmed ? 0.10 : baseAlpha)
                        context.stroke(path, with: .color(color), lineWidth: touchesFocus ? 1.65 : 1.0)
                    } else {
                        context.stroke(
                            path,
                            with: .color(theme.accent.opacity(0.75)),
                            style: StrokeStyle(lineWidth: 1.4, dash: [2.5, 4.5])
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

                let freshness = min(max(star.node.freshness, 0), 1)
                let visibility = star.node.isDormant ? 0.39 : 0.70 + 0.30 * freshness
                var alpha = visibility * (0.50 + 0.50 * depthFactor)
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
                            .init(color: starColor.opacity(min(alpha * (theme.isDark ? 0.46 : 0.36) + resonanceFlare * 0.35, 0.86)), location: 0.0),
                            .init(color: starColor.opacity(alpha * (theme.isDark ? 0.16 : 0.14)), location: 0.42),
                            .init(color: Color.clear, location: 1.0)
                        ]),
                        center: p,
                        startRadius: 0,
                        endRadius: auraRadius
                    )
                )

                // Dimensional luminous core (dark: radiant core + gleam; light: translucent gemstone orb with top-left specular)
                let coreRect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                let core = Path(ellipseIn: coreRect)
                if theme.isDark {
                    context.fill(core, with: .color(starColor.opacity(min(alpha * 1.12, 1))))
                    context.fill(
                        core,
                        with: .radialGradient(
                            Gradient(colors: [theme.galaxyStarGleam.opacity(alpha * 0.68), .clear]),
                            center: p,
                            startRadius: 0,
                            endRadius: r
                        )
                    )
                } else {
                    let highlightCenter = CGPoint(x: p.x - r * 0.28, y: p.y - r * 0.28)
                    context.fill(
                        core,
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: theme.galaxyStarGleam.opacity(min(alpha * 0.96, 1.0)), location: 0.0),
                                .init(color: starColor.opacity(min(alpha * 0.68, 0.92)), location: 0.30),
                                .init(color: starColor.opacity(min(alpha * 0.96, 1.0)), location: 0.72),
                                .init(color: starColor.opacity(min(alpha * 1.08, 1.0)), location: 1.0)
                            ]),
                            center: highlightCenter,
                            startRadius: 0,
                            endRadius: r * 1.38
                        )
                    )
                    // Crisp subtle top-left specular pinpoint
                    let specR = max(r * 0.28, 0.95)
                    let specCenter = CGPoint(x: p.x - r * 0.30, y: p.y - r * 0.30)
                    let specRect = CGRect(x: specCenter.x - specR, y: specCenter.y - specR, width: specR * 2, height: specR * 2)
                    context.fill(
                        Path(ellipseIn: specRect),
                        with: .radialGradient(
                            Gradient(colors: [Color.white.opacity(min(alpha * 0.92, 0.95)), Color.clear]),
                            center: specCenter,
                            startRadius: 0,
                            endRadius: specR
                        )
                    )
                }

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

            drawGalaxyLabels(in: context, size: canvasSize, clouds: clouds, palette: nebulaPalette)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    engine.markInteraction()
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
                    engine.markInteraction()
                    engine.draggedNodeIndex = nil
                    engine.isDraggingSpace = false
                    engine.lastDragLocation = nil
                }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    engine.markInteraction()
                    engine.pinchMagnification = value
                    let pct = Int((engine.effectiveScale * 100).rounded())
                    if engine.displayedZoomPercent != pct {
                        engine.displayedZoomPercent = pct
                    }
                }
                .onEnded { value in
                    engine.markInteraction()
                    engine.pinchMagnification = 1.0
                    engine.setZoomScale(engine.zoomScale * Double(value))
                }
        )
        .simultaneousGesture(
            SpatialTapGesture(count: 2)
                .onEnded { value in
                    guard mode == .interactiveFull else { return }
                    if engine.hitTestProjected(at: value.location) == nil {
                        engine.beginSmoothReset()
                    }
                }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    if let hitStar = engine.hitTestProjected(at: value.location) {
                        onSelectMemoryID(hitStar.node.id)
                    } else {
                        onClearSelection?()
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
            .rotation3DEffect(
                .degrees(isSidebarExpanded ? -7 : 0),
                axis: (x: 0, y: 1, z: 0),
                anchor: .trailing,
                perspective: 0.45
            )
            .offset(x: isSidebarExpanded ? 16 : 0)
            .scaleEffect(isSidebarExpanded ? 0.95 : 1.0, anchor: .trailing)
            .animation(
                isSidebarExpanded
                    ? .spring(response: 0.32, dampingFraction: 0.82)
                    : .easeOut(duration: 0.22),
                value: isSidebarExpanded
            )

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
                    Text("· 拖空白旋转 · 抓星点拉扯 · 双击回中")
                        .font(.system(size: 11.5))
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
            .rotation3DEffect(
                .degrees(isSidebarExpanded ? -7 : 0),
                axis: (x: 0, y: 1, z: 0),
                anchor: .trailing,
                perspective: 0.45
            )
            .offset(x: isSidebarExpanded ? 16 : 0)
            .scaleEffect(isSidebarExpanded ? 0.95 : 1.0, anchor: .trailing)
            .animation(
                isSidebarExpanded
                    ? .spring(response: 0.32, dampingFraction: 0.82)
                    : .easeOut(duration: 0.22),
                value: isSidebarExpanded
            )

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
                    engine.markInteraction()
                    engine.setZoomScale(engine.zoomScale / 1.25)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("缩小")

                Text("\(engine.displayedZoomPercent)%")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 42)

                Button {
                    engine.markInteraction()
                    engine.setZoomScale(engine.zoomScale * 1.25)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("放大")

                Divider().frame(height: 14).overlay(theme.hairlineBorder)

                Button {
                    engine.beginSmoothReset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("平滑回中并重置视角")
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
