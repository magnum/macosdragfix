// macosdragfix — sposta una finestra trascinando nella sua fascia-titolo, SENZA modificatori.
// Workaround per il bug di drag della title bar su macOS 27 beta (muove via AX).
// Zona attiva (relativa alla finestra): x in [xoffset, width-xoffset], y in [yoffset, band].
// Esclude il bordo superiore (yoffset) e gli angoli/lati (xoffset) usati per il resize.
// Click secco -> all'app. Su pulsanti/tab/campi non interviene.
//
// Uso: macosdragfix [--xoffset N] [--yoffset N] [--band N] [--mod ctrl+cmd]
//   -x/--xoffset  px da tenere da sinistra e da destra   (def 8)
//   -y/--yoffset  px da tenere dal bordo superiore        (def 6)
//   -b/--band     altezza fascia-titolo dal bordo sup.    (def 34)
//   -m/--mod      modificatore richiesto, es. ctrl+cmd    (def nessuno)
// Fallback da env: MACOSDRAGFIX_XOFFSET, MACOSDRAGFIX_YOFFSET, MACOSDRAGFIX_BAND, MACOSDRAGFIX_MOD.
import Foundation
import ApplicationServices
import CoreGraphics

let env = ProcessInfo.processInfo.environment
var xoffset = CGFloat(env["MACOSDRAGFIX_XOFFSET"].flatMap { Double($0) } ?? 8)
var yoffset = CGFloat(env["MACOSDRAGFIX_YOFFSET"].flatMap { Double($0) } ?? 6)
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
  "AXDisclosureTriangle","AXSegmentedControl","AXSearchField","AXMenuItem"
]

func role(_ e: AXUIElement) -> String? {
  var v: CFTypeRef?
  if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v) == .success { return v as? String }
  return nil
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

let mask: CGEventMask =
  (1 << CGEventType.leftMouseDown.rawValue) |
  (1 << CGEventType.leftMouseDragged.rawValue) |
  (1 << CGEventType.leftMouseUp.rawValue)

let cb: CGEventTapCallBack = { _, type, event, _ in
  switch type {
  case .leftMouseDown:
    candidate = false; moving = false; win = nil
    let loc = event.location
    if !modOK(event.flags) { break }
    guard let h = hit(loc) else { break }
    if let r = role(h), interactiveRoles.contains(r) { break }      // sopra un controllo: all'app
    guard let w = climbToWindow(h), let (wp, ws) = frame(w) else { break }
    let relX = loc.x - wp.x, relY = loc.y - wp.y
    if relY >= yoffset && relY <= band                             // sotto il bordo sup., dentro la fascia
       && relX >= xoffset && relX <= (ws.width - xoffset) {        // lontano dai lati/angoli (resize)
      candidate = true; win = w; winStart = wp; mouseStart = loc
    }
    // non consumo il down: il click arriva all'app
  case .leftMouseDragged:
    if candidate, let w = win {
      let loc = event.location
      if !moving && (abs(loc.x - mouseStart.x) + abs(loc.y - mouseStart.y) > threshold) { moving = true }
      if moving {
        setPos(w, CGPoint(x: winStart.x + (loc.x - mouseStart.x), y: winStart.y + (loc.y - mouseStart.y)))
        return nil
      }
    }
  case .leftMouseUp:
    candidate = false; moving = false; win = nil
  default: break
  }
  return Unmanaged.passRetained(event)
}

_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: .defaultTap, eventsOfInterest: mask, callback: cb, userInfo: nil) else {
  FileHandle.standardError.write("macosdragfix: event tap non creato — manca Accessibilita?\n".data(using: .utf8)!); exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
let modNote = modStr.isEmpty ? "nessun tasto" : modStr
FileHandle.standardError.write("macosdragfix attivo — xoffset=\(Int(xoffset)) yoffset=\(Int(yoffset)) band=\(Int(band)) mod=\(modNote)\n".data(using: .utf8)!)
CFRunLoopRun()
