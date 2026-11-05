import Testing
@testable import WindowDeckCore

/// 合成一段手势：`fingers` 根手指从 (x0, y0) 匀速移动到 (x1, y1)，共 `frames` 帧，帧间隔 `dt`。
private func swipe(
    fingers: Int = 3,
    from start: (Float, Float) = (0.5, 0.4),
    to end: (Float, Float),
    frames: Int = 12,
    dt: Double = 0.011,
    startTime: Double = 0
) -> [TouchFrame] {
    (0..<frames).map { i in
        let t = Float(i) / Float(frames - 1)
        let x = start.0 + (end.0 - start.0) * t
        let y = start.1 + (end.1 - start.1) * t
        let touches = (0..<fingers).map { f in TouchPoint(id: Int32(f), x: x + Float(f) * 0.05, y: y) }
        return TouchFrame(timestamp: startTime + Double(i) * dt, touches: touches)
    }
}

private func lift(at time: Double) -> TouchFrame {
    TouchFrame(timestamp: time, touches: [])
}

private func run(_ recognizer: inout SwipeRecognizer, _ frames: [TouchFrame]) -> [SwipeDirection] {
    frames.compactMap { recognizer.process($0) }
}

@Suite("SwipeRecognizer")
struct SwipeRecognizerTests {
    @Test func swipeUpAndDown() {
        var r = SwipeRecognizer()
        #expect(run(&r, swipe(to: (0.5, 0.7)) + [lift(at: 1)]) == [.up])
        #expect(run(&r, swipe(from: (0.5, 0.7), to: (0.5, 0.4), startTime: 2) + [lift(at: 3)]) == [.down])
    }

    @Test func invertY() {
        var config = SwipeRecognizerConfig()
        config.invertY = true
        var r = SwipeRecognizer(config: config)
        #expect(run(&r, swipe(to: (0.5, 0.7))) == [.down])
    }

    @Test func horizontalSwipeDoesNotTrigger() {
        var r = SwipeRecognizer()
        #expect(run(&r, swipe(from: (0.2, 0.5), to: (0.8, 0.55))).isEmpty)
    }

    @Test func fourFingersDoNotTriggerThreeFingerGesture() {
        var r = SwipeRecognizer()
        #expect(run(&r, swipe(fingers: 4, to: (0.5, 0.8))).isEmpty)
    }

    @Test func fourFingerConfigTriggersOnFour() {
        var config = SwipeRecognizerConfig()
        config.fingers = 4
        var r = SwipeRecognizer(config: config)
        #expect(run(&r, swipe(fingers: 4, to: (0.5, 0.8))) == [.up])
    }

    @Test func addingFingerMidwayCancels() {
        var r = SwipeRecognizer()
        var frames = swipe(to: (0.5, 0.45), frames: 4)
        frames += swipe(fingers: 4, from: (0.5, 0.45), to: (0.5, 0.8), startTime: 0.05)
        #expect(run(&r, frames).isEmpty)
    }

    @Test func liftingFromFourToThreeDoesNotStartGesture() {
        var r = SwipeRecognizer()
        var frames = swipe(fingers: 4, to: (0.5, 0.42), frames: 3)
        frames += swipe(fingers: 3, from: (0.5, 0.42), to: (0.5, 0.8), startTime: 0.04)
        #expect(run(&r, frames).isEmpty)
    }

    @Test func slowSwipeTimesOut() {
        var r = SwipeRecognizer()
        // 1.2s 内只移动 0.12，前 0.8s 位移不足阈值，超时后不再触发。
        #expect(run(&r, swipe(to: (0.5, 0.52), frames: 100, dt: 0.012)).isEmpty)
    }

    @Test func triggersOnlyOncePerGesture() {
        var r = SwipeRecognizer()
        let frames = swipe(to: (0.5, 0.9), frames: 20) + swipe(from: (0.5, 0.9), to: (0.5, 0.3), frames: 20, startTime: 0.25)
        #expect(run(&r, frames) == [.up])
    }

    @Test func resetsAfterAllFingersLift() {
        var r = SwipeRecognizer()
        _ = run(&r, swipe(to: (0.5, 0.7)))
        _ = r.process(lift(at: 0.3))
        #expect(run(&r, swipe(to: (0.5, 0.7), startTime: 0.5)) == [.up])
    }

    @Test func quickFlickTriggersWithShorterDistance() {
        var config = SwipeRecognizerConfig()
        config.distanceThreshold = 0.10
        var r = SwipeRecognizer(config: config)
        // 0.06 的位移在 4 帧（约 33ms）内完成：速度约 1.8/s。
        #expect(run(&r, swipe(to: (0.5, 0.46), frames: 4)) == [.up])
    }

    @Test func tinyMovementDoesNotTrigger() {
        var r = SwipeRecognizer()
        #expect(run(&r, swipe(to: (0.5, 0.43), frames: 30, dt: 0.02)).isEmpty)
    }
}
