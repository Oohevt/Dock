import AppKit
let gid = Bundle.main.object(forInfoDictionaryKey: "DockGroupID") as? String ?? ""
if let u = URL(string: "dockgroups://group/\(gid)") { NSWorkspace.shared.open(u) }
exit(0)
