// MARK: - 小组件 Bundle
import WidgetKit
import SwiftUI

@main
struct CoursePetWidgets: WidgetBundle {
    var body: some Widget {
        CoursePetSmallWidget()
        CoursePetMediumWidget()
        CoursePetLargeWidget()
    }
}
