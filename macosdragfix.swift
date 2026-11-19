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
let sysWide = AXUIElementCreateSystemWide()
AXUIElementSetMessagingTimeout(sysWide, 0.25)   // a stuck app must not stall the hit test

func hit(_ p: CGPoint) -> AXUIElement? {
  var e: AXUIElement?
  if AXUIElementCopyElementAtPosition(sysWide, Float(p.x), Float(p.y), &e) == .success { return e }
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
// The tap callback must never block: macOS silently disables an event tap whose
// callback takes too long, and a disabled tap passes every drag through to the
// broken WindowServer gesture. All AX work therefore runs on evalQueue; the
// callback only touches these small flags, under stateLock. downSeq tags each
// mouseDown so a slow evaluation cannot attach itself to a newer gesture.
let stateLock = NSLock()
var downSeq = 0
let evalQueue = DispatchQueue(label: "it.m6i.macosdragfix.eval", qos: .userInteractive)

// Repeated drag attempts rescan the same tab strip; cache the result briefly so
// a slow Chrome tree cannot make every attempt expensive.
struct ScanKey: Hashable {
  var pid: pid_t; var x: CGFloat; var y: CGFloat; var w: CGFloat; var h: CGFloat; var band: CGFloat
}
struct ScanEntry { var rects: [CGRect]; var at: Date }
var scanCache: [ScanKey: ScanEntry] = [:]

func occupiedFor(_ w: AXUIElement, _ id: (name: String, bundle: String), _ wp: CGPoint, _ ws: CGSize, _ bd: CGFloat) -> [CGRect] {
  var pid: pid_t = 0
  AXUIElementGetPid(w, &pid)
  let key = ScanKey(pid: pid, x: wp.x, y: wp.y, w: ws.width, h: ws.height, band: bd)
  if let e = scanCache[key], Date().timeIntervalSince(e.at) < 1.5 { return e.rects }
  let rects = isChrome(id) ? chromeOccupied(w, wp, ws, bd) : []
  if scanCache.count > 32 { scanCache.removeAll(keepingCapacity: true) }
  scanCache[key] = ScanEntry(rects: rects, at: Date())
  return rects
}

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

// Runs on evalQueue: the heavy AX work that used to run inside the tap callback.
// Sets the candidate only if this down is still the newest one.
func evaluateDown(_ loc: CGPoint, _ seq: Int) {
  guard let h = hit(loc) else { return }
  if yieldsToApp(h) { return }                                     // control, or a label inside one
  guard let w = climbToWindow(h), let (wp, ws) = frame(w) else { return }
  loadConfigIfChanged()
  let id = appIdentity(w)
  let rule = ruleFor(id)
  let xo = rule?.xoffset ?? xoffset
  let yo = rule?.yoffset ?? yoffset
  let bd = rule?.band ?? band
  let relX = loc.x - wp.x, relY = loc.y - wp.y
  guard relY >= yo && relY <= bd && relX >= xo && relX <= (ws.width - xo) else { return }
  let rel = CGPoint(x: relX, y: relY)
  if rule?.exclude.contains(where: { $0.contains(rel, ws) }) == true { return }
  if occupiedFor(w, id, wp, ws, bd).contains(where: { $0.contains(loc) }) { return }
  stateLock.lock()
  if downSeq == seq { candidate = true; win = w; winStart = wp; mouseStart = loc }
  stateLock.unlock()
}

let cb: CGEventTapCallBack = { _, type, event, _ in
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
    return nil
  }
  switch type {
  case .leftMouseDown:
    stateLock.lock()
    candidate = false; moving = false; win = nil
    downSeq += 1
    let seq = downSeq
    stateLock.unlock()
    let loc = event.location
    if modOK(event.flags) { evalQueue.async { evaluateDown(loc, seq) } }
    // the down is delivered: the click reaches the app
  case .leftMouseDragged:
    stateLock.lock()
    let cand = candidate, w = win, ms = mouseStart, ws0 = winStart, mv = moving
    stateLock.unlock()
    if cand, let w {
      let loc = event.location
      if mv || abs(loc.x - ms.x) + abs(loc.y - ms.y) > threshold {
        if !mv {
          AXUIElementSetMessagingTimeout(w, 1) // don't let a stuck Chrome hold the mover for the default 6s
          stateLock.lock(); moving = true; stateLock.unlock()
        }
        requestMove(w, CGPoint(x: ws0.x + (loc.x - ms.x), y: ws0.y + (loc.y - ms.y)))
        return nil
      }
    }
  case .leftMouseUp:
    stateLock.lock()
    candidate = false; moving = false; win = nil
    stateLock.unlock()
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
  var waited = 0
  while !AXIsProcessTrusted() {
    sleep(1); waited += 1
    if waited == 10 {
      // Some processes never see a grant made while they are running. Under
      // launchd (KeepAlive) exiting here restarts us and the new process sees
      // the grant; run manually, start the command again.
      FileHandle.standardError.write("macosdragfix: Accessibility not visible after 10s; exiting so launchd restarts us\n".data(using: .utf8)!)
      exit(0)
    }
  }
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: .defaultTap, eventsOfInterest: mask, callback: cb, userInfo: nil) else {
  FileHandle.standardError.write("macosdragfix: event tap not created after Accessibility was granted\n".data(using: .utf8)!); exit(1)
}
tapPort = tap
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// Watchdog: even with the heavy work off the callback, macOS can disable the
// tap (timeout, user input). The callback handles the notification when it can,
// but it only fires once — this timer notices a still-disabled tap and revives
// it, so a wedged tap can never become "dragging quietly stopped working".
let myPid = Int32(ProcessInfo.processInfo.processIdentifier)
let watchdog = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 2, 2, 0, 0) { _ in
  guard let tapPort else { return }
  var count: UInt32 = 0
  CGGetEventTapList(0, nil, &count)
  guard count > 0 else { return }
  var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
  CGGetEventTapList(count, &taps, &count)
  for t in taps[..<Int(count)] where t.tappingProcess == myPid {
    if t.eventsOfInterest == mask && !t.enabled {
      CGEvent.tapEnable(tap: tapPort, enable: true)
      FileHandle.standardError.write("macosdragfix: re-enabled a disabled event tap\n".data(using: .utf8)!)
    }
  }
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), watchdog, .commonModes)

let modNote = modStr.isEmpty ? "none" : modStr
FileHandle.standardError.write("macosdragfix active — xoffset=\(Int(xoffset)) yoffset=\(Int(yoffset)) band=\(Int(band)) mod=\(modNote) apps=\(appRules.count) config=\(configPath)\n".data(using: .utf8)!)
CFRunLoopRun()
