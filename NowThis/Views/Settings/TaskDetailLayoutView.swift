import SwiftUI

struct TaskDetailLayoutView: View {
    @AppStorage(TaskDetailSection.storageKey) private var storedOrder = ""
    @State private var editMode = EditMode.inactive

    private var order: [TaskDetailSection] {
        TaskDetailSection.decodeOrder(from: storedOrder)
    }

    var body: some View {
        let sections = order
        List {
            Section {
                ForEach(sections) { section in
                    HStack {
                        Text(section.displayName)
                        if editMode.isEditing {
                            Spacer()
                            Menu {
                                if section != sections.first {
                                    Button("Move Up") { move(section, by: -1) }
                                }
                                if section != sections.last {
                                    Button("Move Down") { move(section, by: 1) }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Move \(Text(section.displayName))")
                        }
                    }
                }
                .onMove(perform: moveSections)
            } footer: {
                Text("Tap Edit, then drag sections or use their Move menus. This order applies to every task on this device.")
            }

            Button("Reset to Default") { storedOrder = "" }
                .disabled(sections == TaskDetailSection.allCases)
        }
        .navigationTitle("Task Detail Layout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .environment(\.editMode, $editMode)
    }

    private func moveSections(from source: IndexSet, to destination: Int) {
        var updatedOrder = order
        updatedOrder.move(fromOffsets: source, toOffset: destination)
        storedOrder = TaskDetailSection.encodeOrder(updatedOrder)
    }

    private func move(_ section: TaskDetailSection, by offset: Int) {
        var updatedOrder = order
        guard let index = updatedOrder.firstIndex(of: section),
              updatedOrder.indices.contains(index + offset) else { return }
        updatedOrder.swapAt(index, index + offset)
        storedOrder = TaskDetailSection.encodeOrder(updatedOrder)
    }
}
