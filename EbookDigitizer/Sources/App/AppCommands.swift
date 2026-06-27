import SwiftUI
import AppKit
import EbookDigitizerCore

/// Native macOS menu commands wiring the responder-chain actions (use-case 7a.2
/// shortcut magic) and the per-page operations (7b/7d) into the app's menu bar.
struct AppCommands: Commands {

    let viewModel: WorkspaceViewModel

    var body: some Commands {
        // Replace the default Text Formatting commands with our XHTML wraps so
        // Cmd+B / Cmd+I route through the responder chain into XHTMLTextView.
        CommandGroup(replacing: .textFormatting) {
            Button("Bold") {
                NSApp.sendAction(#selector(XHTMLTextView.toggleStrong(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("b", modifiers: .command)

            Button("Italic") {
                NSApp.sendAction(#selector(XHTMLTextView.toggleItalics(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("i", modifiers: .command)
        }

        // Page operations (use-case 7b orientation, 7d force re-extract) scoped
        // to the current page (first page entirely in view).
        CommandGroup(after: .toolbar) {
            Section("Current Page") {
                Button("Rotate Left") {
                    if let id = viewModel.currentPageID {
                        viewModel.rotate(pageID: id, by: -90)
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

                Button("Rotate Right") {
                    if let id = viewModel.currentPageID {
                        viewModel.rotate(pageID: id, by: 90)
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

                Button("Flip Horizontal") {
                    if let id = viewModel.currentPageID {
                        viewModel.flip(pageID: id)
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Divider()

                Button("Force Re-Extract Page") {
                    if let id = viewModel.currentPageID {
                        viewModel.reextractPage(id, force: true)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
