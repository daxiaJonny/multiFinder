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
