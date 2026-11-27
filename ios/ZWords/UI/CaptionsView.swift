import SwiftUI

/// Scrolling, movie-style captions. Every English word is a one-tap target.
struct CaptionsView: View {
    let mode: DisplayMode
    @EnvironmentObject private var engine: CaptionEngine
    @State private var followLive = true

    var body: some View {
        if engine.lines.isEmpty {
            EmptyCaptionsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(engine.lines) { line in
                            CaptionRow(line: line,
                                       translation: engine.translations[line.id],
                                       mode: mode,
                                       isCurrent: line.id == engine.lines.last?.id)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.never)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
                } action: { _, atBottom in
                    followLive = atBottom
                }
                .onChange(of: engine.lines.last?.text) { _, _ in
                    guard followLive else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followLive {
                        Button {
                            followLive = true
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Label("Ao vivo", systemImage: "arrow.down")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding()
                    }
                }
                .contextMenu {
                    Button("Limpar legendas", systemImage: "trash", role: .destructive) { engine.clear() }
                }
            }
        }
    }
}

struct CaptionRow: View {
    let line: CaptionLine
    let translation: String?
    let mode: DisplayMode
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch mode {
            case .english:
                WordFlow(line: line, font: primaryFont)
            case .portuguese:
                if let translation {
                    Text(translation).font(primaryFont)
                } else {
                    Text(line.text).font(primaryFont).foregroundStyle(.tertiary)
                }
            case .bilingual:
                WordFlow(line: line, font: primaryFont)
                Text(translation ?? "…")
                    .font(isCurrent ? .title3 : .body)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isCurrent ? 1 : 0.62)
        .animation(.easeOut(duration: 0.15), value: translation)
    }

    private var primaryFont: Font {
        isCurrent ? .system(.title2, weight: .semibold) : .system(.title3, weight: .medium)
    }
}

/// English words of one caption line; a single tap saves the word.
struct WordFlow: View {
    let line: CaptionLine
    let font: Font
    @EnvironmentObject private var vocabulary: VocabularyStore

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 4) {
            ForEach(line.chunks) { chunk in
                WordChip(chunk: chunk, font: font,
                         isSaved: chunk.word.map(vocabulary.isSaved) ?? false) {
                    guard let word = chunk.word else { return }
                    vocabulary.save(word: word, offset: chunk.wordOffset, sentence: line.text)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct WordChip: View {
    let chunk: Chunk
    let font: Font
    let isSaved: Bool
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Text(chunk.display)
            .font(font)
            .foregroundStyle(isSaved ? Color.accentColor : Color.primary)
            .underline(isSaved, color: .accentColor.opacity(0.45))
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(pulse ? 0.25 : 0))
            )
            .scaleEffect(pulse ? 1.08 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                guard chunk.word != nil else { return }
                action()
                withAnimation(.spring(duration: 0.2)) { pulse = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeOut(duration: 0.3)) { pulse = false }
                }
            }
            .accessibilityAddTraits(chunk.word != nil ? .isButton : [])
            .accessibilityHint(chunk.word != nil ? "Salvar na biblioteca" : "")
    }
}

struct EmptyCaptionsView: View {
    var body: some View {
        VStack(spacing: 22) {
            Text("Ouça. Leia. Toque.")
                .font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 14) {
                Label("**Microfone** — conversas, aulas e o som ao redor.", systemImage: "mic")
                Label("**iPhone** — vídeos, podcasts e apps. Toque e escolha *Iniciar Transmissão*.",
                      systemImage: "iphone.radiowaves.left.and.right")
                Label("**Legenda flutuante** — continue vendo as legendas sobre outros apps.",
                      systemImage: "pip")
                Label("Toque em qualquer palavra para salvá-la.", systemImage: "hand.tap")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
