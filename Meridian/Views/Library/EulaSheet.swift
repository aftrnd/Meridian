import SwiftUI

/// A game's license agreement, shown by Meridian before Steam starts the
/// game. Accept records the answer for Steam, so it never opens its own
/// window for it; Cancel leaves the game unstarted (Pattern 47).
struct EulaSheet: View {
    let prompt: Launcher.EulaPrompt
    let onAccept: () -> Void
    let onCancel: () -> Void

    @State private var index = 0
    @State private var text: AttributedString?
    @State private var loadFailed = false

    private var eula: SteamEula { prompt.eulas[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eula.name)
                    .font(.title2.weight(.semibold))
                Text("\(prompt.game.name) asks you to accept this agreement before you play. You only need to do this once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.top, .horizontal], 24)
            .padding(.bottom, 16)

            Divider()

            Group {
                if let text {
                    ScrollView {
                        Text(text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                } else if loadFailed {
                    VStack(spacing: 10) {
                        Text("Couldn't load the agreement from Steam.")
                            .foregroundStyle(.secondary)
                        Button("Try Again") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 360)

            Divider()

            HStack {
                if prompt.eulas.count > 1 {
                    Text("\(index + 1) of \(prompt.eulas.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                // Only once the text is on screen: the player accepts what
                // they could read.
                Button("Accept", action: accept)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text == nil)
            }
            .padding(16)
        }
        .frame(width: 560)
        .task(id: eula.id) { await load() }
    }

    private func accept() {
        if index + 1 < prompt.eulas.count {
            index += 1
        } else {
            onAccept()
        }
    }

    private func load() async {
        text = nil
        loadFailed = false
        do {
            text = SteamBBCode.attributed(try await SteamEula.text(of: eula))
        } catch {
            loadFailed = true
        }
    }
}

/// Steam's agreement text is BBCode. Its formatting tags become styling;
/// any other tag is dropped and the text inside it kept.
enum SteamBBCode {
    static func attributed(_ source: String) -> AttributedString {
        let text = source.replacingOccurrences(of: "\r\n", with: "\n")
        var result = AttributedString()
        var bold = 0, italic = 0, underline = 0
        var heading: Int?
        var link: URL?
        var lists: [Int?] = []  // per open list: nil for bullets, else the next number

        func append(_ string: String) {
            guard !string.isEmpty else { return }
            var run = AttributedString(string)
            var font: Font = switch heading {
            case 1: .title2
            case 2: .title3
            case 3: .headline
            default: .body
            }
            if bold > 0 || heading != nil { font = font.bold() }
            if italic > 0 { font = font.italic() }
            run.font = font
            if underline > 0 { run.underlineStyle = .single }
            if let link { run.link = link }
            result += run
        }
        func startLine() {
            if let last = result.characters.last, last != "\n" { append("\n") }
        }

        var cursor = text.startIndex
        for match in text.matches(of: /\[(\/?)([A-Za-z0-9*]+)(?:=([^\]]*))?\]/) {
            append(String(text[cursor..<match.range.lowerBound]))
            cursor = match.range.upperBound
            let closing = !match.output.1.isEmpty
            switch match.output.2.lowercased() {
            case "b": bold = max(0, bold + (closing ? -1 : 1))
            case "i": italic = max(0, italic + (closing ? -1 : 1))
            case "u": underline = max(0, underline + (closing ? -1 : 1))
            case "h1", "h2", "h3":
                if closing {
                    heading = nil
                } else {
                    startLine()
                    heading = Int(match.output.2.dropFirst())
                }
            case "url":
                link = closing ? nil : match.output.3.flatMap { URL(string: String($0)) }
            case "list", "olist":
                if closing {
                    if !lists.isEmpty { lists.removeLast() }
                    startLine()
                } else {
                    lists.append(match.output.2.lowercased() == "olist" ? 1 : nil)
                }
            case "*":
                startLine()
                append(String(repeating: "    ", count: max(0, lists.count - 1)))
                if case .some(.some(let number)) = lists.last {
                    append("\(number). ")
                    lists[lists.count - 1] = number + 1
                } else {
                    append("• ")
                }
            case "hr":
                startLine()
                append("\n")
            default:
                break
            }
        }
        append(String(text[cursor...]))
        return result
    }
}
