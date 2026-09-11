#!/usr/bin/env swift

import AppKit
import Foundation

private enum InstallerLayout {
    static let canvasSize = NSSize(width: 660, height: 420)
    static let titleFrame = NSRect(x: 80, y: 348, width: 500, height: 34)
    static let instructionFrame = NSRect(x: 80, y: 318, width: 500, height: 24)
    static let arrowStart = NSPoint(x: 245, y: 206)
    static let arrowEnd = NSPoint(x: 414, y: 206)
    static let arrowControlStart = NSPoint(x: 290, y: 230)
    static let arrowControlEnd = NSPoint(x: 370, y: 230)
    static let arrowHeadUpper = NSPoint(x: 397, y: 220)
    static let arrowHeadLower = NSPoint(x: 397, y: 192)
    static let arrowLineWidth: CGFloat = 5
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: create-macos-dmg.swift <artwork.png> <output.png>\n", stderr)
    exit(64)
}

let artworkURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let artwork = NSImage(contentsOf: artworkURL) else {
    fputs("Could not load artwork at \(artworkURL.path)\n", stderr)
    exit(66)
}

let canvasSize = InstallerLayout.canvasSize
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Could not create installer background canvas\n", stderr)
    exit(70)
}
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create installer background context\n", stderr)
    exit(70)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// Aspect-fill the source artwork so generation remains deterministic even if
// the source resolution changes while preserving the 660x420 Finder layout.
let sourceRatio = artwork.size.width / artwork.size.height
let targetRatio = canvasSize.width / canvasSize.height
let drawSize = sourceRatio > targetRatio
    ? NSSize(width: canvasSize.height * sourceRatio, height: canvasSize.height)
    : NSSize(width: canvasSize.width, height: canvasSize.width / sourceRatio)
let drawRect = NSRect(
    x: (canvasSize.width - drawSize.width) / 2,
    y: (canvasSize.height - drawSize.height) / 2,
    width: drawSize.width,
    height: drawSize.height
)
artwork.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)

let brown = NSColor(srgbRed: 0x2C / 255, green: 0x18 / 255, blue: 0x10 / 255, alpha: 1)
let honey = NSColor(srgbRed: 0xD4 / 255, green: 0x92 / 255, blue: 0x2E / 255, alpha: 1)

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center

let title = "Pablo’s ready to settle in"
title.draw(
    in: InstallerLayout.titleFrame,
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: brown,
        .paragraphStyle: paragraph,
    ]
)

let instruction = "Drag Pablo to Applications to install"
instruction.draw(
    in: InstallerLayout.instructionFrame,
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: brown.withAlphaComponent(0.78),
        .paragraphStyle: paragraph,
    ]
)

// A friendly, unmistakable drag direction between the two Finder icons.
let arrow = NSBezierPath()
arrow.lineWidth = InstallerLayout.arrowLineWidth
arrow.lineCapStyle = .round
arrow.move(to: InstallerLayout.arrowStart)
arrow.curve(
    to: InstallerLayout.arrowEnd,
    controlPoint1: InstallerLayout.arrowControlStart,
    controlPoint2: InstallerLayout.arrowControlEnd
)
honey.setStroke()
arrow.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: InstallerLayout.arrowHeadUpper)
arrowHead.line(to: InstallerLayout.arrowEnd)
arrowHead.line(to: InstallerLayout.arrowHeadLower)
arrowHead.lineWidth = InstallerLayout.arrowLineWidth
arrowHead.lineCapStyle = .round
arrowHead.lineJoinStyle = .round
arrowHead.stroke()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode installer background\n", stderr)
    exit(70)
}

try png.write(to: outputURL, options: .atomic)
