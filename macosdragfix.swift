import AppKit
// macosdragfix — move a window by dragging its title band, with no modifiers.
// Workaround for the title-bar drag bug on macOS 27 beta (moves via AX).
// Active zone (relative to the window): x in [xoffset, width-xoffset], y in [yoffset, band].
// Leaves the top edge (yoffset) and the corners/sides (xoffset) free for resize.
// A plain click goes to the app. Over buttons, tabs, and fields it stays out,
// including when the hit is a label inside that control.
// ~/.macosdragfix.yml lists extra exclusion areas per app (created if missing).
//
// Usage: macosdragfix [--xoffset N] [--yoffset N] [--band N] [--mod ctrl+cmd]
//   -x/--xoffset  px to keep clear on the left and right   (default 10)
//   -y/--yoffset  px to keep clear from the top edge       (default 8)
//   -b/--band     title-band height from the top edge      (default 34)
//   -m/--mod      required modifier, e.g. ctrl+cmd         (default none)
// Env fallback: MACOSDRAGFIX_XOFFSET, MACOSDRAGFIX_YOFFSET, MACOSDRAGFIX_BAND, MACOSDRAGFIX_MOD.
import Foundation
import ApplicationServices
import CoreGraphics

let env = ProcessInfo.processInfo.environment
var xoffset = CGFloat(env["MACOSDRAGFIX_XOFFSET"].flatMap { Double($0) } ?? 10)
var yoffset = CGFloat(env["MACOSDRAGFIX_YOFFSET"].flatMap { Double($0) } ?? 8)
var band    = CGFloat(env["MACOSDRAGFIX_BAND"].flatMap { Double($0) } ?? 34)
var modStr  = (env["MACOSDRAGFIX_MOD"] ?? "").lowercased()

do {
  let a = Array(CommandLine.arguments.dropFirst()); var i = 0
  func val() -> String? { i + 1 < a.count ? a[i+1] : nil }
  while i < a.count {
    switch a[i] {
    case "--xoffset","-x": if let v = val(), let d = Double(v) { xoffset = CGFloat(d) }; i += 1
    case "--yoffset","-y": if let v = val(), let d = Double(v) { yoffset = CGFloat(d) }; i += 1
    case "--band","-b":    if let v = val(), let d = Double(v) { band = CGFloat(d) }; i += 1
    case "--mod","-m":     if let v = val() { modStr = v.lowercased() }; i += 1
    default: break
    }
    i += 1
  }
}
let threshold: CGFloat = 4

let interactiveRoles: Set<String> = [
  "AXButton","AXMenuButton","AXPopUpButton","AXRadioButton","AXCheckBox",
  "AXTextField","AXTextArea","AXSlider","AXComboBox","AXLink","AXStepper",
  "AXDisclosureTriangle","AXSegmentedControl","AXSearchField","AXMenuItem",
  "AXTabButton","AXTab","AXPageTab"
]

@_silgen_name("proc_pidpath")
func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

struct ExcludeArea {
  var name = ""
  var x: CGFloat = 0
  var y: CGFloat = 0
  var width: CGFloat?
  var height: CGFloat?
  var right: CGFloat?
  var bottom: CGFloat?
  func contains(_ p: CGPoint, _ size: CGSize) -> Bool {
    let w = width ?? max(0, size.width - x - (right ?? 0))
    let h = height ?? max(0, size.height - y - (bottom ?? 0))
    return p.x >= x && p.y >= y && p.x < x + w && p.y < y + h
  }
}
struct AppRule {
  var name: String
  var bundle = ""
  var xoffset: CGFloat?
  var yoffset: CGFloat?
  var band: CGFloat?
  var exclude: [ExcludeArea] = []
}

let configPath = NSHomeDirectory() + "/.macosdragfix.yml"
let defaultConfig = """
# Per-app rules for macosdragfix. The key is the app name.
# bundle is optional; a window matches the name or the bundle id.
# Areas are points from the window's top-left.
# right / bottom measure from the opposite edges when width / height are omitted.
# band, xoffset, yoffset override the global values for that app.
# A button, field, or tab that Accessibility exposes is always left to the app.
# Edits apply on the next click.

"1Password":
  bundle: com.1password.1password
  exclude:
    - name: search
      x: 248
      y: 0
      right: 8
      height: 48

# Chrome tabs are measured from the live tab strip, so the empty
# title-bar area grows and shrinks with the open tabs. Add an exclude
# only for a control Accessibility does not report.
"""

var appRules: [AppRule] = []
var configMtime: Date?
var idCache: [pid_t: (name: String, bundle: String)] = [:]

func unquote(_ s: String) -> String {
  if s.count >= 2, let a = s.first, let b = s.last,
     (a == "\"" && b == "\"") || (a == "'" && b == "'") {
    return String(s.dropFirst().dropLast())
  }
  return s
}
func splitKV(_ s: String) -> (String, String)? {
  guard let i = s.firstIndex(of: ":") else { return nil }
  let k = String(s[..<i]).trimmingCharacters(in: .whitespaces)
  let v = String(s[s.index(after: i)...]).trimmingCharacters(in: .whitespaces)
  return k.isEmpty ? nil : (k, v)
}
func applyArea(_ area: inout ExcludeArea, _ k: String, _ v: String) {
  if k == "name" { area.name = unquote(v); return }
  guard let n = Double(v) else { return }
  switch k {
  case "x": area.x = CGFloat(n)
  case "y": area.y = CGFloat(n)
  case "width": area.width = CGFloat(n)
  case "height": area.height = CGFloat(n)
  case "right": area.right = CGFloat(n)
  case "bottom": area.bottom = CGFloat(n)
  default: break
  }
}
func parseConfig(_ text: String) -> [AppRule] {
  var apps: [AppRule] = []
  var inExclude = false
  for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
    let line = String(raw)
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
    let indent = line.prefix { $0 == " " }.count
    if indent == 0 {
      inExclude = false
      var name = trimmed
      if name.hasSuffix(":") { name.removeLast() }
      name = unquote(name.trimmingCharacters(in: .whitespaces))
      if !name.isEmpty { apps.append(AppRule(name: name)) }
      continue
    }
    guard !apps.isEmpty else { continue }
    let i = apps.count - 1
    if indent == 2 && trimmed == "exclude:" { inExclude = true; continue }
    if indent == 2, let (k, v) = splitKV(trimmed) {
      inExclude = false
      switch k {
      case "bundle": apps[i].bundle = unquote(v)
      case "xoffset": if let n = Double(v) { apps[i].xoffset = CGFloat(n) }
      case "yoffset": if let n = Double(v) { apps[i].yoffset = CGFloat(n) }
      case "band": if let n = Double(v) { apps[i].band = CGFloat(n) }
      default: break
      }
      continue
    }
    if inExclude && trimmed.hasPrefix("-") {
      var area = ExcludeArea()
      let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
      if let (k, v) = splitKV(String(rest)) { applyArea(&area, k, v) }
      apps[i].exclude.append(area)
      continue
    }
    if inExclude, var area = apps[i].exclude.last, let (k, v) = splitKV(trimmed) {
      applyArea(&area, k, v)
      apps[i].exclude[apps[i].exclude.count - 1] = area
    }
  }
  return apps
}
func loadConfigIfChanged() {
  let fm = FileManager.default
  if !fm.fileExists(atPath: configPath) {
    do {
      try defaultConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
      FileHandle.standardError.write("macosdragfix: wrote \(configPath)\n".data(using: .utf8)!)
    } catch {
      FileHandle.standardError.write("macosdragfix: could not write \(configPath): \(error)\n".data(using: .utf8)!)
    }
  }
  let mtime = (try? fm.attributesOfItem(atPath: configPath)[.modificationDate]) as? Date
  if mtime == configMtime { return }
  configMtime = mtime
  let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
  appRules = parseConfig(text)
}
func appIdentity(_ e: AXUIElement) -> (name: String, bundle: String) {
  var pid: pid_t = 0
  AXUIElementGetPid(e, &pid)
  if let hit = idCache[pid] { return hit }
  var buf = [CChar](repeating: 0, count: 4096)
  var name = ""
  var bundle = ""
  if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
    var url = URL(fileURLWithPath: String(cString: buf))
    while url.path != "/" {
      if url.pathExtension == "app" {
        name = url.deletingPathExtension().lastPathComponent
        let info = url.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: info),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
          bundle = plist["CFBundleIdentifier"] as? String ?? ""
          if let n = plist["CFBundleName"] as? String, !n.isEmpty { name = n }
        }
        break
      }
      url.deleteLastPathComponent()
    }
  }
  let pair = (name, bundle)
  idCache[pid] = pair
  return pair
}
func ruleFor(_ id: (name: String, bundle: String)) -> AppRule? {
  for r in appRules {
    if !r.bundle.isEmpty && r.bundle.caseInsensitiveCompare(id.bundle) == .orderedSame { return r }
    if r.name.caseInsensitiveCompare(id.name) == .orderedSame { return r }
  }
  return nil
}

func role(_ e: AXUIElement) -> String? {
  var v: CFTypeRef?
  if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v) == .success { return v as? String }
  return nil
}
func subrole(_ e: AXUIElement) -> String? {
  var v: CFTypeRef?
  if AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &v) == .success { return v as? String }
  return nil
}
func parent(_ e: AXUIElement) -> AXUIElement? {
  var v: CFTypeRef?
  if AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &v) == .success,
     let p = v, CFGetTypeID(p) == AXUIElementGetTypeID() { return (p as! AXUIElement) }
  return nil
}
func yieldsToApp(_ start: AXUIElement) -> Bool {
  var e = start
  for _ in 0..<12 {
    if let r = role(e) {
      if r == "AXWindow" || r == "AXApplication" { return false }
      if interactiveRoles.contains(r) { return true }
    }
    if let s = subrole(e), interactiveRoles.contains(s) { return true }
    guard let p = parent(e) else { return false }
    e = p
  }
  return false
}
func children(_ e: AXUIElement) -> [AXUIElement] {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success, let v else { return [] }
  if let a = v as? [AXUIElement], !a.isEmpty { return a }
  guard CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
  let arr = v as! CFArray
  var out: [AXUIElement] = []
  for i in 0..<CFArrayGetCount(arr) {
    if let p = CFArrayGetValueAtIndex(arr, i) {
      out.append(Unmanaged<AXUIElement>.fromOpaque(p).takeUnretainedValue())
    }
  }
  return out
}
func isChrome(_ id: (name: String, bundle: String)) -> Bool {
  if id.bundle.hasPrefix("com.google.Chrome") { return true }
  return id.name.caseInsensitiveCompare("Google Chrome") == .orderedSame
}
// Real tab and button frames in the title band. The tab strip group itself is
// wider than a tab, so the empty gap after the last tab stays draggable and
// follows how many tabs are open. Chrome nests the radios several groups deep.
func chromeOccupied(_ window: AXUIElement, _ origin: CGPoint, _ size: CGSize, _ bandH: CGFloat) -> [CGRect] {
  AXUIElementSetMessagingTimeout(window, 0.4)
  var rects: [CGRect] = []
  var queue: [(AXUIElement, Int)] = [(window, 0)]
  var qi = 0
  var seen = 0
  let maxW = min(380, max(120, size.width * 0.7))
  while qi < queue.count && seen < 200 && rects.count < 64 {
    let (e, depth) = queue[qi]
    qi += 1
    seen += 1
    if depth > 12 { continue }
    let r = role(e) ?? ""
    if r == "AXWebArea" || r == "AXTextArea" { continue }
    var below = false
    if let (p, s) = frame(e), s.width > 1, s.height > 1 {
      let relY = p.y - origin.y
      if relY > bandH + 4 { below = true }
      let inBand = relY + s.height > 0 && relY < bandH + 12
      let tab = r == "AXRadioButton" || r == "AXTab" || r == "AXTabButton" || r == "AXPageTab" || r == "AXTabGroup"
      let button = r == "AXButton" || r == "AXPopUpButton" || r == "AXMenuButton"
      if inBand && (tab || button) && s.height < bandH + 30 && s.width < maxW {
        rects.append(CGRect(x: p.x - 2, y: p.y - 2, width: s.width + 4, height: s.height + 4))
        continue
      }
    }
    if below || depth >= 12 { continue }
    for c in children(e) { queue.append((c, depth + 1)) }
  }
  return rects
}
func hit(_ p: CGPoint) -> AXUIElement? {
  var e: AXUIElement?
  if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &e) == .success { return e }
  return nil
}
func climbToWindow(_ start: AXUIElement) -> AXUIElement? {
  var e = start
  for _ in 0..<15 {
    if let r = role(e), r == (kAXWindowRole as String) { return e }
    var wv: CFTypeRef?
    if AXUIElementCopyAttributeValue(e, kAXWindowAttribute as CFString, &wv) == .success,
       let w = wv, CFGetTypeID(w) == AXUIElementGetTypeID() { return (w as! AXUIElement) }
    var pv: CFTypeRef?
    if AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &pv) == .success,
       let p = pv, CFGetTypeID(p) == AXUIElementGetTypeID() { e = (p as! AXUIElement) } else { break }
  }
  return nil
}
func frame(_ w: AXUIElement) -> (CGPoint, CGSize)? {
  var pv: CFTypeRef?; var sv: CFTypeRef?
  guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
        AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
  var p = CGPoint.zero; var s = CGSize.zero
  AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
  return (p, s)
}
func setPos(_ w: AXUIElement, _ p: CGPoint) {
  var pt = p
  if let v = AXValueCreate(.cgPoint, &pt) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
}
func setSize(_ w: AXUIElement, _ sz: CGSize) {
  var s = sz
  if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
}
// Mouse released within snapEdge px of a screen edge: left/right half, top = fill. Returns AX (top-left) coords.
let snapEdge: CGFloat = 4
func snapRect(_ loc: CGPoint) -> CGRect? {
  guard let mainH = NSScreen.screens.first?.frame.height else { return nil }
  for sc in NSScreen.screens {
    let f = sc.frame, v = sc.visibleFrame
    let full = CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height)  // flip to top-left
    guard full.insetBy(dx: -1, dy: -1).contains(loc) else { continue }
    let vis = CGRect(x: v.minX, y: mainH - v.maxY, width: v.width, height: v.height)
    if loc.x <= full.minX + snapEdge { return CGRect(x: vis.minX, y: vis.minY, width: vis.width / 2, height: vis.height) }
    if loc.x >= full.maxX - snapEdge { return CGRect(x: vis.midX, y: vis.minY, width: vis.width / 2, height: vis.height) }
    if loc.y <= full.minY + snapEdge { return vis }
    return nil
  }
  return nil
}
// Translucent preview shown while dragging over a snap edge (like native tiling hint).
var overlay: NSWindow?
func showOverlay(_ r: CGRect?) {
  guard let r = r, let mainH = NSScreen.screens.first?.frame.height else { overlay?.orderOut(nil); return }
  let f = CGRect(x: r.minX, y: mainH - r.maxY, width: r.width, height: r.height).insetBy(dx: 6, dy: 6)
  if overlay == nil {
    let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.level = .floating; w.ignoresMouseEvents = true
    w.hasShadow = false; w.collectionBehavior = [.canJoinAllSpaces, .transient]
    let v = NSView(); v.wantsLayer = true
    v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
    v.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
    v.layer?.borderWidth = 1; v.layer?.cornerRadius = 12
    w.contentView = v; overlay = w
  }
  guard let w = overlay else { return }
  if w.isVisible { if w.frame != f { NSAnimationContext.runAnimationGroup { $0.duration = 0.12; w.animator().setFrame(f, display: true) } } }
  else { w.setFrame(f, display: true); w.alphaValue = 0; w.orderFrontRegardless(); w.animator().alphaValue = 1 }
}
// Ease-out glide from current frame to target; runs on moveQueue.
func animate(_ w: AXUIElement, to r: CGRect) {
  guard let (p0, s0) = frame(w) else { setPos(w, r.origin); setSize(w, r.size); return }
  let steps = 10
  for i in 1...steps {
    let t = Double(i) / Double(steps), e = CGFloat(1 - pow(1 - t, 3))
    setPos(w, CGPoint(x: p0.x + (r.minX - p0.x) * e, y: p0.y + (r.minY - p0.y) * e))
    setSize(w, CGSize(width: s0.width + (r.width - s0.width) * e, height: s0.height + (r.height - s0.height) * e))
    usleep(12_000)
  }
  setPos(w, r.origin); setSize(w, r.size); setPos(w, r.origin)
}
func modOK(_ f: CGEventFlags) -> Bool {
  if modStr.isEmpty { return true }
  var ok = true
  if modStr.contains("ctrl")  { ok = ok && f.contains(.maskControl) }
  if modStr.contains("cmd")   { ok = ok && f.contains(.maskCommand) }
  if modStr.contains("alt") || modStr.contains("opt") { ok = ok && f.contains(.maskAlternate) }
  if modStr.contains("shift") { ok = ok && f.contains(.maskShift) }
  return ok
}

var candidate = false, moving = false
var win: AXUIElement?
var winStart = CGPoint.zero, mouseStart = CGPoint.zero
var tapPort: CFMachPort?

// AX position updates are synchronous in the target app. Chrome on an external
// display often answers slower than the mouse event rate; doing that work inside
// the event tap stalls the pointer. Apply only the newest point, off the tap.
let moveQueue = DispatchQueue(label: "it.m6i.macosdragfix.move", qos: .userInteractive)
let moveLock = NSLock()
var pendingWin: AXUIElement?
var pendingPos: CGPoint?
var moveBusy = false

func requestMove(_ w: AXUIElement, _ p: CGPoint) {
  moveLock.lock()
  pendingWin = w
  pendingPos = p
  let start = !moveBusy
  if start { moveBusy = true }
  moveLock.unlock()
  if start { moveQueue.async { drainMoves() } }
}

func drainMoves() {
  while true {
    moveLock.lock()
    guard let w = pendingWin, let p = pendingPos else {
      moveBusy = false
      moveLock.unlock()
      return
    }
    pendingPos = nil
    moveLock.unlock()
    setPos(w, p)
  }
}

let mask: CGEventMask =
  (1 << CGEventType.leftMouseDown.rawValue) |
  (1 << CGEventType.leftMouseDragged.rawValue) |
  (1 << CGEventType.leftMouseUp.rawValue)

let cb: CGEventTapCallBack = { _, type, event, _ in
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
    return nil
  }
  switch type {
  case .leftMouseDown:
    candidate = false; moving = false; win = nil
    let loc = event.location
    if !modOK(event.flags) { break }
    guard let h = hit(loc) else { break }
    if yieldsToApp(h) { break }                                     // control, or a label inside one
    guard let w = climbToWindow(h), let (wp, ws) = frame(w) else { break }
    loadConfigIfChanged()
    let id = appIdentity(w)
    let rule = ruleFor(id)
    let xo = rule?.xoffset ?? xoffset
    let yo = rule?.yoffset ?? yoffset
    let bd = rule?.band ?? band
    let relX = loc.x - wp.x, relY = loc.y - wp.y
    if relY >= yo && relY <= bd
       && relX >= xo && relX <= (ws.width - xo) {
      let rel = CGPoint(x: relX, y: relY)
      if rule?.exclude.contains(where: { $0.contains(rel, ws) }) == true { break }
      if isChrome(id), chromeOccupied(w, wp, ws, bd).contains(where: { $0.contains(loc) }) { break }
      candidate = true; win = w; winStart = wp; mouseStart = loc
    }
    // the down is delivered: the click reaches the app
  case .leftMouseDragged:
    if candidate, let w = win {
      let loc = event.location
      if !moving && (abs(loc.x - mouseStart.x) + abs(loc.y - mouseStart.y) > threshold) {
        moving = true
        AXUIElementSetMessagingTimeout(w, 1)   // don't let a stuck Chrome hold the mover for the default 6s
      }
      if moving {
        requestMove(w, CGPoint(x: winStart.x + (loc.x - mouseStart.x), y: winStart.y + (loc.y - mouseStart.y)))
        showOverlay(snapRect(loc))
        return nil
      }
    }
  case .leftMouseUp:
    // ponytail: Chrome snaps back to its cached frame on mouseUp; re-assert final position after it settles
    if moving, let w = win {
      let loc = event.location
      let p = CGPoint(x: winStart.x + (loc.x - mouseStart.x), y: winStart.y + (loc.y - mouseStart.y))
      let snap = snapRect(loc)
      showOverlay(nil)
      if let r = snap {
        moveQueue.asyncAfter(deadline: .now() + .milliseconds(60)) { animate(w, to: r) }
        moveQueue.asyncAfter(deadline: .now() + .milliseconds(400)) { setPos(w, r.origin); setSize(w, r.size) }
      } else {
        moveQueue.async { setPos(w, p) }
        for ms in [16, 40, 80, 150, 250] { moveQueue.asyncAfter(deadline: .now() + .milliseconds(ms)) { setPos(w, p) } }
      }
      // ponytail: hand Chrome a release at the press point so it sees a plain click, not a drag it must undo
      event.location = mouseStart
    }
    candidate = false; moving = false; win = nil
  default: break
  }
  return Unmanaged.passRetained(event)
}

loadConfigIfChanged()
if CommandLine.arguments.contains("--dump-config") {
  for r in appRules {
    let areas = r.exclude.map { $0.name.isEmpty ? "area" : $0.name }.joined(separator: ", ")
    print("\(r.name) bundle=\(r.bundle.isEmpty ? "-" : r.bundle) exclude=[\(areas)]")
  }
  exit(0)
}
if !AXIsProcessTrusted() {
  _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
  FileHandle.standardError.write("macosdragfix: waiting for Accessibility for this binary. Remove the old entry with −, then enable the new one. Toggling the existing switch does not update it.\n".data(using: .utf8)!)
  while !AXIsProcessTrusted() { sleep(1) }
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: .defaultTap, eventsOfInterest: mask, callback: cb, userInfo: nil) else {
  FileHandle.standardError.write("macosdragfix: event tap not created after Accessibility was granted\n".data(using: .utf8)!); exit(1)
}
tapPort = tap
NSApplication.shared.setActivationPolicy(.accessory)
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
let modNote = modStr.isEmpty ? "none" : modStr
FileHandle.standardError.write("macosdragfix active — xoffset=\(Int(xoffset)) yoffset=\(Int(yoffset)) band=\(Int(band)) mod=\(modNote) apps=\(appRules.count) config=\(configPath)\n".data(using: .utf8)!)
CFRunLoopRun()
