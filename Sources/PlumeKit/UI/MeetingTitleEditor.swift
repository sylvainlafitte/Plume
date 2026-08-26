import SwiftUI

/// One inline title interaction shared by recording, wrap-up and Meetings.
struct MeetingTitleEditor: View {
    enum Style {
        case compact
        case detail

        var font: Font {
            switch self {
            case .compact: return .headline
            case .detail: return .title3.bold()
            }
        }

        var height: CGFloat {
            switch self {
            case .compact: return 22
            case .detail: return 28
            }
        }
    }

    let title: String?
    let style: Style
    let isEnabled: Bool
    var allowsWindowDrag = false
    let onCommit: (String) -> Void

    @State private var draft = ""
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            TextField("Add title", text: text)
                .textFieldStyle(.plain)
                .font(style.font)
                .lineLimit(1)
                .focused($isFocused)
                .allowsHitTesting(isEditing)
                .onSubmit { commit() }
                .onExitCommand { cancel() }
                .onChange(of: isFocused) { wasFocused, focused in
                    if wasFocused, !focused, isEditing { commit() }
                }
                .accessibilityHidden(!isEditing)
                .accessibilityLabel("Meeting title")

            if !isEditing {
                if allowsWindowDrag {
                    activationLayer.gesture(WindowDragGesture())
                } else {
                    activationLayer
                }
            }
        }
        .frame(height: style.height, alignment: .leading)
        .opacity(isEnabled ? 1 : 0.55)
        .allowsHitTesting(isEnabled)
    }

    private var text: Binding<String> {
        Binding(
            get: { isEditing ? draft : title ?? "" },
            set: { draft = $0 })
    }

    private var activationLayer: some View {
        Color.clear
        .contentShape(Rectangle())
        .onTapGesture { beginEditing() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title == nil ? "Add meeting title" : "Edit meeting title")
        .accessibilityValue(title ?? "No title")
        .accessibilityHint("Opens a text field")
    }

    private func beginEditing() {
        guard isEnabled else { return }
        draft = title ?? ""
        isEditing = true
        isFocused = true
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        isFocused = false
        guard MeetingTitleStore.normalize(draft) != nil else { return }
        onCommit(draft)
    }

    private func cancel() {
        isEditing = false
        isFocused = false
        draft = title ?? ""
    }
}
