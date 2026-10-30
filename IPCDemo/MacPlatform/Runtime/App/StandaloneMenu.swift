import AppKit
import IPCProtocol
import MacPetWindowing

private final class MenuAction: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func invoke() { handler() }
}

/// Native launch control; no terminal or Electron process is needed.
final class StandaloneMenu {
    private let item: NSStatusItem
    init(pet: any PetRequestHandling, window: MacPetWindowAdapter, quit: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "DynaPet") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "DynaPet"
        }
        item.button?.toolTip = "DynaPet：显示、隐藏与大小设置"
        let menu = NSMenu()
        menu.addItem(MenuAction("显示桌宠") { window.showWindow() })
        menu.addItem(MenuAction("隐藏桌宠") { window.hideWindow() })
        menu.addItem(MenuAction("摸摸她") { pet.touch { _ in } })
        menu.addItem(MenuAction("显示 / 隐藏状态面板") { window.toggleStatusPanel() })
        let sizes = NSMenu(), parent = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        for scale in [0.75, 1.0, 1.25] {
            sizes.addItem(MenuAction("\(Int(scale * 100))%") { pet.resize(scale: scale) { _ in } })
        }
        parent.submenu = sizes; menu.addItem(parent)
        menu.addItem(.separator())
        menu.addItem(MenuAction("退出 DynaPet", handler: quit))
        item.menu = menu
        window.setContextMenu(menu)
    }
    func close() { precondition(Thread.isMainThread); NSStatusBar.system.removeStatusItem(item) }
}
