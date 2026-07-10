import SwiftUI

@main
struct MPO3DMacApp: App {
    @StateObject private var viewModel = EditorViewModel()

    var body: some Scene {
        WindowGroup("mpo3d") {
            ContentView(viewModel: viewModel)
        }
        .commands {
            MPO3DCommands(viewModel: viewModel)
        }
    }
}

private struct MPO3DCommands: Commands {
    @ObservedObject var viewModel: EditorViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Composition") {
                viewModel.createEmptyGrouping()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Open Photos") {
                viewModel.openFilesPanel()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("Open Photo Folder") {
                viewModel.openFolderPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Choose Output Folder") {
                viewModel.openOutputPanel()
            }
            .keyboardShortcut("d", modifiers: [.command])
        }

        CommandMenu("Alignment") {
            Button("Move Up") {
                viewModel.move(dx: 0, dy: -viewModel.moveStep)
            }
            .keyboardShortcut(.upArrow, modifiers: [])

            Button("Move Up by 10 px") {
                viewModel.move(dx: 0, dy: -10)
            }
            .keyboardShortcut(.upArrow, modifiers: [.shift])

            Button("Move Down") {
                viewModel.move(dx: 0, dy: viewModel.moveStep)
            }
            .keyboardShortcut(.downArrow, modifiers: [])

            Button("Move Down by 10 px") {
                viewModel.move(dx: 0, dy: 10)
            }
            .keyboardShortcut(.downArrow, modifiers: [.shift])

            Button("Move Left") {
                viewModel.move(dx: -viewModel.moveStep, dy: 0)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button("Move Left by 10 px") {
                viewModel.move(dx: -10, dy: 0)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.shift])

            Button("Move Right") {
                viewModel.move(dx: viewModel.moveStep, dy: 0)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Button("Move Right by 10 px") {
                viewModel.move(dx: 10, dy: 0)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.shift])

            Divider()

            Button("Reset Alignment") {
                viewModel.resetOffset()
            }
            .keyboardShortcut("r", modifiers: [])

            Button("Toggle Preview") {
                viewModel.togglePreview()
            }
            .keyboardShortcut(.space, modifiers: [])
        }

        CommandMenu("Export") {
            Button("Save GIF") {
                viewModel.saveCurrent(format: .gif)
            }
            .keyboardShortcut("s", modifiers: [.command])

            Button("Save PNG") {
                viewModel.saveCurrent(format: .png)
            }
            .keyboardShortcut("p", modifiers: [.command])

            Button("Save GIF and Next Photo") {
                viewModel.saveCurrent(format: .gif, advanceAfterSave: true)
            }
            .keyboardShortcut(.return, modifiers: [])

            Divider()

            Button("Faster GIF") {
                viewModel.decreaseDuration()
            }
            .keyboardShortcut("[", modifiers: [])

            Button("Slower GIF") {
                viewModel.increaseDuration()
            }
            .keyboardShortcut("]", modifiers: [])
        }

        CommandMenu("Zoom") {
            Button("Zoom Out") {
                viewModel.decreaseZoom()
            }
            .keyboardShortcut("-", modifiers: [])

            Button("Zoom In") {
                viewModel.increaseZoom()
            }
            .keyboardShortcut("=", modifiers: [])
        }
    }
}
