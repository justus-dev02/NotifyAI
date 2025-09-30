import SwiftUI

struct TagListView: View {
    let tags: [String]

    var body: some View {
        FlexibleView(data: tags, spacing: 8, lineSpacing: 8) { tag in
            Text(tag)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
    }
}

private struct FlexibleView<Data: Collection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let spacing: CGFloat
    let lineSpacing: CGFloat
    let content: (Data.Element) -> Content

    init(data: Data, spacing: CGFloat, lineSpacing: CGFloat, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content
    }

    var body: some View {
        var width: CGFloat = 0
        var height: CGFloat = 0
        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(data.enumerated()), id: \.element) { index, element in
                    content(element)
                        .padding(.horizontal, spacing / 2)
                        .padding(.vertical, lineSpacing / 2)
                        .alignmentGuide(.leading) { d in
                            if width + d.width > geometry.size.width {
                                width = 0
                                height -= d.height + lineSpacing
                            }
                            let result = width
                            if index == data.count - 1 {
                                width = 0
                            } else {
                                width += d.width + spacing
                            }
                            return result
                        }
                        .alignmentGuide(.top) { _ in
                            let result = height
                            if index == data.count - 1 {
                                height = 0
                            }
                            return result
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height * -1 + 32)
    }
}

#Preview {
    TagListView(tags: ["Pilot", "On-Prem", "Q4", "Renewal"])
}
