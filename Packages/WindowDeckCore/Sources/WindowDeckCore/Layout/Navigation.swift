import CoreGraphics

public enum NavigationDirection: Sendable {
    case left, right, up, down
}

/// 方向键导航：在给定方向上找最近的目标（坐标系 y 向下）。
public enum SpatialNavigation {
    public static func next<ID: Hashable>(
        from current: ID?,
        direction: NavigationDirection,
        targets: [(id: ID, rect: CGRect)]
    ) -> ID? {
        guard !targets.isEmpty else { return nil }
        guard let current, let origin = targets.first(where: { $0.id == current })?.rect else {
            return targets.first?.id
        }
        let o = CGPoint(x: origin.midX, y: origin.midY)
        var best: (id: ID, score: CGFloat)?
        for target in targets where target.id != current {
            let c = CGPoint(x: target.rect.midX, y: target.rect.midY)
            let dx = c.x - o.x
            let dy = c.y - o.y
            let (primary, secondary): (CGFloat, CGFloat)
            switch direction {
            case .left: (primary, secondary) = (-dx, dy)
            case .right: (primary, secondary) = (dx, dy)
            case .up: (primary, secondary) = (-dy, dx)
            case .down: (primary, secondary) = (dy, dx)
            }
            guard primary > 1 else { continue }
            // 偏离主方向的位移加权惩罚，优先同一行 / 同一列。
            let score = primary + abs(secondary) * 2
            if best == nil || score < best!.score {
                best = (target.id, score)
            }
        }
        return best?.id ?? current
    }
}
