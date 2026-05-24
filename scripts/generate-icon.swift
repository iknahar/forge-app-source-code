#!/usr/bin/env swift
// Generates the Forge app icon at every macOS-required size.
// Run with: swift scripts/generate-icon.swift
// Drops PNGs into Forge/Resources/Assets.xcassets/AppIcon.appiconset/

import AppKit
import Foundation

// Resolve project root (one level above scripts/)
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let projectRoot = scriptURL
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()  // scripts/
    .deletingLastPathComponent()  // macos-app/
let iconSetDir = projectRoot
    .appendingPathComponent("Forge/Resources/Assets.xcassets/AppIcon.appiconset")

let sizes: [(side: Int, scale: Int, filename: String)] = [
    (16,  1, "icon_16x16.png"),
    (16,  2, "icon_16x16@2x.png"),
    (32,  1, "icon_32x32.png"),
    (32,  2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

/// Render the Forge icon at `pixels` resolution.
/// Design: full-bleed red squircle background + bold white "F" with a
/// hammer-head crossbar on the top arm.
func renderIcon(pixels: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: pixels, height: pixels))
    img.lockFocus()

    // ───── Background: red squircle ─────
    // Forge accent #E72903
    let red       = NSColor(srgbRed: 0.906, green: 0.16,  blue: 0.012, alpha: 1.0)
    let redDeep   = NSColor(srgbRed: 0.78,  green: 0.10,  blue: 0.00,  alpha: 1.0)

    // macOS Big Sur+ rounded square: ~22.5% corner radius
    let r = pixels * 0.225
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                          xRadius: r, yRadius: r)
    red.setFill()
    bg.fill()

    // Subtle bottom shadow band for depth (very faint)
    let shadowBand = NSBezierPath(
        rect: NSRect(x: 0, y: 0, width: pixels, height: pixels * 0.18))
    bg.addClip()
    redDeep.withAlphaComponent(0.35).setFill()
    shadowBand.fill()

    // Reset clip so the F draws on top
    NSGraphicsContext.current?.cgContext.resetClip()

    // ───── White F + hammer crossbar ─────
    NSColor.white.setFill()

    // F bounding box (centered, ~60% of canvas)
    let fW: CGFloat = pixels * 0.50
    let fH: CGFloat = pixels * 0.62
    let fX: CGFloat = (pixels - fW) / 2
    let fY: CGFloat = (pixels - fH) / 2

    let stroke = fW * 0.22
    let bevel  = stroke * 0.18  // rounded corners on strokes

    // Vertical stem
    let stem = NSBezierPath(
        roundedRect: NSRect(x: fX, y: fY, width: stroke, height: fH),
        xRadius: bevel, yRadius: bevel)
    stem.fill()

    // Middle horizontal bar (~65% width)
    let midBarW = fW * 0.62
    let midBarY = fY + fH * 0.42
    let midBar = NSBezierPath(
        roundedRect: NSRect(x: fX, y: midBarY, width: midBarW, height: stroke * 0.85),
        xRadius: bevel, yRadius: bevel)
    midBar.fill()

    // Top arm (the hammer crossbar) — extends slightly past the stem
    // and has a "hammer head" thicker block on the right
    let topArmY = fY + fH - stroke
    let topArmW = fW * 0.92
    let topArm = NSBezierPath(
        roundedRect: NSRect(x: fX, y: topArmY, width: topArmW, height: stroke),
        xRadius: bevel, yRadius: bevel)
    topArm.fill()

    // Hammer head: a thicker block on the right end of the top arm,
    // protruding slightly above and below
    let headW = stroke * 1.35
    let headH = stroke * 1.55
    let headX = fX + topArmW - headW * 0.9
    let headY = topArmY - (headH - stroke) / 2
    let head = NSBezierPath(
        roundedRect: NSRect(x: headX, y: headY, width: headW, height: headH),
        xRadius: bevel * 1.3, yRadius: bevel * 1.3)
    head.fill()

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let rep  = NSBitmapImageRep(data: tiff),
        let png  = rep.representation(using: .png, properties: [:])
    else { throw NSError(domain: "ForgeIcon", code: 1) }
    try png.write(to: url)
}

// Make sure the iconset folder exists
try? FileManager.default.createDirectory(
    at: iconSetDir, withIntermediateDirectories: true)

print("Generating Forge icon → \(iconSetDir.path)")
for s in sizes {
    let px  = CGFloat(s.side * s.scale)
    let img = renderIcon(pixels: px)
    let url = iconSetDir.appendingPathComponent(s.filename)
    do {
        try writePNG(img, to: url)
        print("  ✓ \(s.filename)  (\(Int(px))×\(Int(px)))")
    } catch {
        print("  ✗ \(s.filename): \(error)")
    }
}

// Rewrite Contents.json so Xcode wires the files up
let contentsJSON = """
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "version" : 1, "author" : "forge-icon-script" }
}
"""
try contentsJSON.write(
    to: iconSetDir.appendingPathComponent("Contents.json"),
    atomically: true, encoding: .utf8)
print("  ✓ Contents.json")
print("\nDone. Press ⌘R in Xcode to see the new icon.")
