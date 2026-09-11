import AppKit
import SwiftUI

/// Central design system tokens for MultiFinder Theme v2 (Native Sequoia Polish).
public enum MFDTheme {
    // MARK: - Accent & Dual-Tone Colors

    /// Primary brand sky blue, dynamic for Light and Dark modes.
    public static var primaryAccent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(red: 0.231, green: 0.510, blue: 0.965, alpha: 1.0) // #3B82F6
                : NSColor(red: 0.102, green: 0.451, blue: 0.910, alpha: 1.0) // #1A73E8
        })
    }

    /// Secondary cyan/teal accent echoing the twin folder in the App Icon.
    public static var secondaryAccent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(red: 0.024, green: 0.714, blue: 0.831, alpha: 1.0) // #06B6D4
                : NSColor(red: 0.008, green: 0.518, blue: 0.780, alpha: 1.0) // #0284C7
        })
    }

    /// AI Sparkle gradient for smart actions (Ask / Organize).
    public static var aiGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.486, green: 0.227, blue: 0.929), // #7C3AED
                Color(red: 0.231, green: 0.510, blue: 0.965)  // #3B82F6
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// AI Sparkle accent color for text and icons.
    public static var aiSparkleColor: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(red: 0.655, green: 0.545, blue: 0.980, alpha: 1.0) // #A78BFA
                : NSColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 1.0) // #7C3AED
        })
    }

    // MARK: - Surfaces & Materials

    /// Background for unified pane headers, subtle semi-translucent styling.
    public static var paneHeaderBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.14, alpha: 0.85)
                : NSColor(white: 0.97, alpha: 0.92)
        })
    }

    /// Background for pane tab bar when multiple tabs exist.
    public static var paneTabBarBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.11, alpha: 0.90)
                : NSColor(white: 0.93, alpha: 0.92)
        })
    }

    /// Selected tab pill background.
    public static var activeTabBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.22, alpha: 1.0)
                : NSColor(white: 1.0, alpha: 0.98)
        })
    }

    /// Subtle hairline border / divider color (0.5px).
    public static var subtleHairline: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1.0, alpha: 0.08)
                : NSColor(white: 0.0, alpha: 0.08)
        })
    }

    /// Subtle card border for focused elements.
    public static var activeIndicator: Color {
        primaryAccent
    }

    /// Background for breadcrumb pills when hovered or normal.
    public static var breadcrumbPillBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1.0, alpha: 0.06)
                : NSColor(white: 0.0, alpha: 0.04)
        })
    }

    /// Hover background for interactive pills and icon buttons.
    public static var hoverPillBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1.0, alpha: 0.12)
                : NSColor(white: 0.0, alpha: 0.08)
        })
    }
}

// MARK: - AppKit Table Zebra Stripe Eliminator

extension NSTableView {
    private static var isZebraStripesDisabled = false

    /// Permanently eliminates alternating row zebra stripes at the AppKit level
    /// so they never draw on initial render or during view state updates.
    public static func disableZebraStripesGlobally() {
        guard !isZebraStripesDisabled else { return }
        isZebraStripesDisabled = true

        let setterSelector = #selector(setter: usesAlternatingRowBackgroundColors)
        let swizzledSetterSelector = #selector(mfd_setUsesAlternatingRowBackgroundColors(_:))

        if let origMethod = class_getInstanceMethod(NSTableView.self, setterSelector),
           let swizzMethod = class_getInstanceMethod(NSTableView.self, swizzledSetterSelector) {
            method_exchangeImplementations(origMethod, swizzMethod)
        }

        let getterSelector = #selector(getter: usesAlternatingRowBackgroundColors)
        let swizzledGetterSelector = #selector(mfd_usesAlternatingRowBackgroundColors)

        if let origMethod = class_getInstanceMethod(NSTableView.self, getterSelector),
           let swizzMethod = class_getInstanceMethod(NSTableView.self, swizzledGetterSelector) {
            method_exchangeImplementations(origMethod, swizzMethod)
        }
    }

    @objc private func mfd_setUsesAlternatingRowBackgroundColors(_ value: Bool) {
        // Intercept and force false: Prevents SwiftUI Table from ever enabling zebra stripes!
        mfd_setUsesAlternatingRowBackgroundColors(false)
    }

    @objc private func mfd_usesAlternatingRowBackgroundColors() -> Bool {
        return false
    }
}

// MARK: - AppKit Scroller Overlay Enforcer

extension NSScroller {
    private static var isOverlayEnforced = false

    /// Forces all scrollbars across the app to use modern floating overlay style,
    /// preventing legacy scrollbar tracks from showing permanent gray lines when a mouse is connected.
    public static func enforceOverlayGlobally() {
        guard !isOverlayEnforced else { return }
        isOverlayEnforced = true

        let metaClass: AnyClass = object_getClass(NSScroller.self)!
        let sel = #selector(getter: NSScroller.preferredScrollerStyle)
        let swizzledSel = #selector(NSScroller.mfd_preferredScrollerStyle)
        if let origMethod = class_getInstanceMethod(metaClass, sel),
           let swizzMethod = class_getInstanceMethod(metaClass, swizzledSel) {
            method_exchangeImplementations(origMethod, swizzMethod)
        }
    }

    @objc public static func mfd_preferredScrollerStyle() -> NSScroller.Style {
        return .overlay
    }
}

// MARK: - AppKit Table Row Separator Eliminator

extension NSTableRowView {
    private static var isSeparatorsDisabled = false

    /// Permanently eliminates horizontal row separator lines in table views,
    /// providing a clean, distraction-free Finder-style list view.
    public static func disableRowSeparatorsGlobally() {
        guard !isSeparatorsDisabled else { return }
        isSeparatorsDisabled = true

        if let sepClass = NSClassFromString("_NSTableRowSeparatorDrawingView") {
            let drawSel = #selector(NSView.draw(_:))
            let noopSel = #selector(NSTableRowView.mfd_noopDraw(_:))
            if let noopMethod = class_getInstanceMethod(NSTableRowView.self, noopSel) {
                class_replaceMethod(
                    sepClass,
                    drawSel,
                    method_getImplementation(noopMethod),
                    method_getTypeEncoding(noopMethod)
                )
            }
        }

        if let orig = class_getInstanceMethod(NSTableRowView.self, #selector(NSTableRowView.drawSeparator(in:))),
           let noop = class_getInstanceMethod(NSTableRowView.self, #selector(NSTableRowView.mfd_noopDraw(_:))) {
            method_setImplementation(orig, method_getImplementation(noop))
        }

        let sepColorSel = NSSelectorFromString("separatorColor")
        let clearColorSel = #selector(NSTableRowView.mfd_clearSeparatorColor)
        if let orig = class_getInstanceMethod(NSTableRowView.self, sepColorSel),
           let clear = class_getInstanceMethod(NSTableRowView.self, clearColorSel) {
            method_setImplementation(orig, method_getImplementation(clear))
        }

        let drawSepColorSel = NSSelectorFromString("_drawSeparatorInRect:withColor:")
        let noopDrawSepSel = #selector(NSTableRowView.mfd_noopDrawSeparator(in:with:))
        if let orig = class_getInstanceMethod(NSTableRowView.self, drawSepColorSel),
           let noop = class_getInstanceMethod(NSTableRowView.self, noopDrawSepSel) {
            method_setImplementation(orig, method_getImplementation(noop))
        }
    }

    @objc private func mfd_noopDraw(_ dirtyRect: NSRect) {
        // Suppress drawing to eliminate horizontal row separator lines!
    }

    @objc private func mfd_clearSeparatorColor() -> NSColor {
        return .clear
    }

    @objc private func mfd_noopDrawSeparator(in rect: NSRect, with color: NSColor) {
        // Suppress drawing with color!
    }
}


