// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
// Draws the menu-bar template icon as a PDF into the given directory.
import AppKit
import Foundation

final class MenuMark: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.set()
        let cable = NSBezierPath()
        cable.move(to: NSPoint(x: 6.5, y: 11))
        cable.line(to: NSPoint(x: 6.5, y: 16))
        cable.curve(to: NSPoint(x: 14.5, y: 16), controlPoint1: NSPoint(x: 6.5, y: 23), controlPoint2: NSPoint(x: 11.5, y: 22))
        cable.line(to: NSPoint(x: 15.5, y: 13))
        cable.line(to: NSPoint(x: 21, y: 6))
        cable.move(to: NSPoint(x: 15.5, y: 13)); cable.line(to: NSPoint(x: 21, y: 20))
        cable.lineWidth = 1.9; cable.lineCapStyle = .round; cable.lineJoinStyle = .round; cable.stroke()
        // Filled circles preserve alpha-only rendering and read cleanly at 18 points.
        for (x,y) in [(15.5,13.0),(21.0,6.0),(21.0,20.0)] {
            NSBezierPath(ovalIn: NSRect(x:x-2.1,y:y-2.1,width:4.2,height:4.2)).fill()
        }
        let tip = NSBezierPath(roundedRect: NSRect(x:4,y:1.5,width:5,height:5), xRadius:0.6,yRadius:0.6)
        tip.windingRule = .evenOdd
        tip.appendRect(NSRect(x:5,y:3,width:1,height:1.5)); tip.appendRect(NSRect(x:7,y:3,width:1,height:1.5))
        tip.fill()
        NSBezierPath(roundedRect: NSRect(x:3,y:5.5,width:7,height:6),xRadius:1.2,yRadius:1.2).fill()
    }
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory:true)
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
let mark = MenuMark(frame:NSRect(x:0,y:0,width:24,height:24))
let pdf = mark.dataWithPDF(inside:mark.bounds)
try pdf.write(to:output.appendingPathComponent("LongcableMenuBarIconTemplate.pdf"))
