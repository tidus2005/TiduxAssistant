import CodexWatchWidgets
import SwiftUI
import WidgetKit

@main
struct CodexWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexWatchPetWidget()
        CodexCollaborationWidget(component: .ask)
        CodexCollaborationWidget(component: .progress)
        CodexCollaborationWidget(component: .approvals)
        CodexCollaborationWidget(component: .arena)
    }
}
