import AppKit
import CoreGraphics

/// AX / CG 使用"主屏左上角原点、y 向下"，Cocoa 使用"主屏左下角原点、y 向上"。
@MainActor
enum CoordinateConverter {
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// AX 全局坐标 → Cocoa 全局坐标。
    static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Cocoa 全局坐标 → AX 全局坐标。
    static func axRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// AX 全局坐标 → 某块屏幕上覆盖层（flipped 视图）的局部坐标。
    static func overlayRect(fromAX rect: CGRect, screen: NSScreen) -> CGRect {
        let screenAX = axRect(fromCocoa: screen.frame)
        return rect.offsetBy(dx: -screenAX.minX, dy: -screenAX.minY)
    }

    /// 与窗口重叠面积最大的屏幕。
    static func screen(forAX rect: CGRect) -> NSScreen? {
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in NSScreen.screens {
            let intersection = axRect(fromCocoa: screen.frame).intersection(rect)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if best == nil || area > best!.area {
                best = (screen, area)
            }
        }
        return best?.screen
    }

    static var screenWithMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
