import AppKit
import MetalKit

/// Synthetic desktop for repeatable visual QA, without screen-recording permission.
enum PreviewScene {
    static func texture(device: MTLDevice, dark: Bool = false) throws -> MTLTexture {
        let image = NSImage(size:NSSize(width:1000,height:680))
        image.lockFocus()
        let textColor: NSColor = dark ? NSColor(calibratedWhite:0.83,alpha:1) : .darkGray
        let mutedColor: NSColor = dark ? NSColor(calibratedWhite:0.54,alpha:1) : .gray
        NSGradient(starting:NSColor(calibratedRed:0.09,green:0.26,blue:0.31,alpha:1),
                   ending:NSColor(calibratedRed:0.42,green:0.56,blue:0.54,alpha:1))!.draw(in:NSRect(x:0,y:0,width:1000,height:680),angle:35)
        func box(_ rect:NSRect,_ color:NSColor,_ radius:CGFloat = 12) {
            color.setFill(); NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill()
        }
        func text(_ string:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ color:NSColor) {
            (string as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:.medium),.foregroundColor:color])
        }
        box(NSRect(x:90,y:65,width:820,height:550),NSColor(calibratedWhite:dark ? 0.10 : 0.94,alpha:1),16)
        box(NSRect(x:90,y:570,width:820,height:45),NSColor(calibratedWhite:dark ? 0.14 : 0.86,alpha:1),12)
        for (i,color) in [NSColor.systemRed,.systemYellow,.systemGreen].enumerated() {
            color.setFill(); NSBezierPath(ovalIn:NSRect(x:110+i*22,y:586,width:12,height:12)).fill()
        }
        text("Rainy Screen / Desktop preview",350,584,14,textColor)
        box(NSRect(x:90,y:65,width:190,height:505),NSColor(calibratedWhite:dark ? 0.075 : 0.89,alpha:1),0)
        text("WORKSPACE",112,527,12,mutedColor)
        for (i,label) in ["Overview","Projects","Documents","Archive"].enumerated() {
            text(label,112,480-CGFloat(i)*44,15,textColor)
        }
        text("A quiet, rainy afternoon.",320,488,30,textColor)
        text("A window between you and the weather.",320,450,16,mutedColor)
        for i in 0..<3 {
            box(NSRect(x:320+CGFloat(i)*181,y:290,width:161,height:120),NSColor(calibratedRed:dark ? 0.13 : 0.73-CGFloat(i)*0.08,green:dark ? 0.24 : 0.81,blue:dark ? 0.26 : 0.77,alpha:1),8)
            text(["Observe","Slow down","Keep working"][i],335+CGFloat(i)*181,332,16,textColor)
        }
        for i in 0..<5 {
            box(NSRect(x:320,y:238-CGFloat(i)*24,width:i == 4 ? 310 : 510,height:5),NSColor(calibratedWhite:dark ? 0.35 : 0.72,alpha:1),2)
        }
        text("Move the cursor to wipe the glass.",320,99,14,mutedColor)
        image.unlockFocus()
        var rect = NSRect(origin:.zero,size:image.size)
        guard let cg = image.cgImage(forProposedRect:&rect,context:nil,hints:nil) else { throw NSError(domain:"Preview",code:1) }
        return try MTKTextureLoader(device:device).newTexture(cgImage:cg,options:[.SRGB:false,.origin:MTKTextureLoader.Origin.topLeft])
    }
}
