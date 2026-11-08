import SwiftUI

/// Night blue and gold, matching the app icon.
enum Theme {
    static let gold = Color(red: 0.95, green: 0.80, blue: 0.35)
    static let night = Color(red: 0.07, green: 0.08, blue: 0.15)
    static let deepNight = Color(red: 0.02, green: 0.02, blue: 0.06)
    static let danger = Color(red: 0.93, green: 0.33, blue: 0.33)
    static let card = Color.white.opacity(0.06)
    static let secondaryText = Color.white.opacity(0.62)

    static let background = LinearGradient(colors: [night, deepNight], startPoint: .top, endPoint: .bottom)
}

/// A rounded "chip" button used for presets and add-time.
struct ChipButton: View {
    let title: String
    var systemImage: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? Theme.deepNight : .white)
            .background(prominent ? Theme.gold : Theme.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(prominent ? 0 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.07)))
    }
}
