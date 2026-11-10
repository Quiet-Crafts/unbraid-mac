import AppKit
import WebKit
// Renders an SVG through WebKit (full filter support) to a transparent square PNG: render-svg.swift <svg> <png> <px>
let args = CommandLine.arguments
let svg = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let size = CGFloat(Double(args[3]) ?? 1024)
let app = NSApplication.shared
class D: NSObject, WKNavigationDelegate {
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
    let c = WKSnapshotConfiguration(); c.rect = CGRect(x: 0, y: 0, width: 1024, height: 1024); c.snapshotWidth = NSNumber(value: Double(size)); c.afterScreenUpdates = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      w.takeSnapshot(with: c) { img, e in
        guard let img, let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t) else { print(e as Any); exit(1) }
        let r2 = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r2)
        r.draw(in: NSRect(x: 0, y: 0, width: size, height: size)); NSGraphicsContext.restoreGraphicsState()
        // An icon's corner is clear; an opaque one means WebKit drew a page, not the SVG.
        guard r2.colorAt(x: 0, y: 0)?.alphaComponent == 0 else { print("render-svg: nothing drawn for \(svg.path)"); exit(1) }
        try! r2.representation(using: .png, properties: [:])!.write(to: out); exit(0)
      }
    }
  }
}
let d = D()
let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024))
w.setValue(false, forKey: "drawsBackground")
w.navigationDelegate = d
// The SVG goes inline: WebKit may not be allowed to read files beside it.
let markup = try! String(contentsOf: svg, encoding: .utf8)
let html = "<html><body style='margin:0;background:transparent'><div style='width:1024px;height:1024px'>\(markup)</div></body></html>"
w.loadHTMLString(html, baseURL: nil)
app.run()
