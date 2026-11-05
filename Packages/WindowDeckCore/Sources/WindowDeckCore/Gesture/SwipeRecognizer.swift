import Foundation

/// 一个有效触点，坐标归一化到 0…1（触控板左下角为原点、y 向上）。
public struct TouchPoint: Hashable, Sendable {
    public var id: Int32
    public var x: Float
    public var y: Float

    public init(id: Int32, x: Float, y: Float) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// 一帧触控数据，只包含有效（按下中）的触点。
public struct TouchFrame: Sendable {
    public var timestamp: Double
    public var touches: [TouchPoint]

    public init(timestamp: Double, touches: [TouchPoint]) {
        self.timestamp = timestamp
        self.touches = touches
    }
}

public enum SwipeDirection: Sendable, Equatable {
    case up, down
}

public struct SwipeRecognizerConfig: Sendable, Equatable {
    public var fingers: Int = 3
    /// 位移阈值（归一化）。
    public var distanceThreshold: Double = 0.10
    /// 纵向 / 横向位移比，过滤横向滑动。
    public var directionRatio: Double = 1.8
    /// 快速轻扫的纵向速度阈值（归一化单位 / 秒）。
    public var velocityThreshold: Double = 1.2
    /// 进入候选前需要连续满足手指数的帧数。
    public var minStableFrames: Int = 2
    /// 超时未触发则取消。
    public var maxDuration: Double = 0.8
    /// 设备的 y 轴方向与预期相反时打开。
    public var invertY: Bool = false

    public init() {}
}

/// 三指（可配置）上下滑识别。值类型、无锁，由调用方保证串行调用。
public struct SwipeRecognizer: Sendable {
    enum State: Sendable, Equatable {
        case idle
        case tracking(stableFrames: Int, startX: Double, startY: Double, startTime: Double, lastY: Double, lastTime: Double, velocity: Double)
        /// 已触发或已取消，等待所有手指抬起。
        case cooldown
    }

    public var config: SwipeRecognizerConfig
    private(set) var state: State = .idle

    public init(config: SwipeRecognizerConfig = SwipeRecognizerConfig()) {
        self.config = config
    }

    public mutating func reset() {
        state = .idle
    }

    /// 处理一帧，识别出手势时返回方向（每次手势最多返回一次）。
    public mutating func process(_ frame: TouchFrame) -> SwipeDirection? {
        let count = frame.touches.count

        switch state {
        case .cooldown:
            if count == 0 { state = .idle }
            return nil

        case .idle:
            if count > config.fingers {
                // 多指手势（例如四指）结束时逐个抬指会经过 N 指，不能当作新手势。
                state = .cooldown
                return nil
            }
            guard count == config.fingers else { return nil }
            let c = centroid(frame.touches)
            state = .tracking(stableFrames: 1, startX: c.x, startY: c.y, startTime: frame.timestamp, lastY: c.y, lastTime: frame.timestamp, velocity: 0)
            return nil

        case let .tracking(stableFrames, startX, startY, startTime, lastY, lastTime, velocity):
            guard count == config.fingers else {
                // 手指数变化（加指 / 抬指）：取消，防止与四指手势、捏合误触。
                state = count == 0 ? .idle : .cooldown
                return nil
            }
            if frame.timestamp - startTime > config.maxDuration {
                state = .cooldown
                return nil
            }
            let c = centroid(frame.touches)
            let dt = frame.timestamp - lastTime
            var v = velocity
            if dt > 0 {
                let instant = (c.y - lastY) / dt
                v = velocity == 0 ? instant : velocity * 0.5 + instant * 0.5
            }
            let frames = stableFrames + 1
            state = .tracking(stableFrames: frames, startX: startX, startY: startY, startTime: startTime, lastY: c.y, lastTime: frame.timestamp, velocity: v)
            guard frames >= config.minStableFrames else { return nil }

            let dx = c.x - startX
            let dy = (c.y - startY) * (config.invertY ? -1 : 1)
            let vy = v * (config.invertY ? -1 : 1)
            let vertical = abs(dy) >= config.directionRatio * abs(dx)
            let byDistance = abs(dy) >= config.distanceThreshold
            let byVelocity = abs(vy) >= config.velocityThreshold && abs(dy) >= config.distanceThreshold / 2
            guard vertical, byDistance || byVelocity else { return nil }

            state = .cooldown
            return dy > 0 ? .up : .down
        }
    }

    private func centroid(_ touches: [TouchPoint]) -> (x: Double, y: Double) {
        guard !touches.isEmpty else { return (0, 0) }
        let n = Double(touches.count)
        let x = touches.reduce(0.0) { $0 + Double($1.x) } / n
        let y = touches.reduce(0.0) { $0 + Double($1.y) } / n
        return (x, y)
    }
}
