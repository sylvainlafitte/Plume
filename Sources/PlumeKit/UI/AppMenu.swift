import AppKit

/// The invisible main menu.
///
/// Plume is `LSUIElement`, so no menu bar is ever drawn — but macOS still routes
/// **standard editing commands through the main menu's key equivalents**. With
/// no main menu, ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z have nothing to dispatch to: the
/// responder chain rejects them and the system plays the error beep. Text could
/// be selected but never copied, in every window.
///
/// So the menu exists purely for key routing. Each item uses the standard
/// selector and `target: nil`, which sends it up the responder chain to whatever
/// text view is first responder.
enum AppMenu {

    static func install() {
        let main = NSMenu()

        // An app menu has to exist as item 0 or the Edit menu lands in its place.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Plume", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        editItem.submenu = editMenu()
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")

        func add(_ title: String, _ selector: Selector, _ key: String,
                 _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            // nil target = walk the responder chain to the focused text view.
            item.target = nil
            menu.addItem(item)
        }

        add("Undo", Selector(("undo:")), "z")
        add("Redo", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), "x")
        add("Copy", #selector(NSText.copy(_:)), "c")
        add("Paste", #selector(NSText.paste(_:)), "v")
        add("Select All", #selector(NSText.selectAll(_:)), "a")
        return menu
    }
}
