import AppKit
// Fake "Finder": a window with a tile; drag from it carries the file URLs in $DRAGSRC_FILES (colon-separated).
// Also logs files it is asked to open (so we can see "drop file on app icon" arrive).
let logPath = ProcessInfo.processInfo.environment["DRAGSRC_LOG"] ?? "/tmp/dragsrc.log"
func log(_ s: String) { if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); try? h.close() } else { try? (s + "\n").write(toFile: logPath, atomically: true, encoding: .utf8) } }
final class Tile: NSView, NSDraggingSource {
  var files: [URL] = []
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { [.copy, .move, .link, .generic, .delete] }
  override func mouseDown(with e: NSEvent) {
    let items = files.map { u -> NSDraggingItem in
      let it = NSDraggingItem(pasteboardWriter: u as NSURL)
      it.setDraggingFrame(NSRect(x: 0, y: 0, width: 64, height: 64), contents: NSWorkspace.shared.icon(forFile: u.path)); return it }
    beginDraggingSession(with: items, event: e, source: self)
  }
  func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) { log("drag ended op=\(operation.rawValue)") }
}
final class D: NSObject, NSApplicationDelegate {
  func application(_ a: NSApplication, open urls: [URL]) { log("OPENED: " + urls.map { $0.path }.joined(separator: ", ")) }
}
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let d = D(); app.delegate = d
let w = NSWindow(contentRect: NSRect(x: 60, y: NSScreen.main!.frame.height - 260, width: 160, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
let t = Tile(frame: NSRect(x: 0, y: 0, width: 160, height: 160)); t.wantsLayer = true; t.layer?.backgroundColor = NSColor.systemOrange.cgColor
t.files = (ProcessInfo.processInfo.environment["DRAGSRC_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
w.contentView = t; w.title = "DragSrc"; w.level = .floating; w.orderFrontRegardless()
log("ready frame=\(w.frame)")
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
app.run()
