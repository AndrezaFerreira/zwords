import SwiftData
import SwiftUI

/// Quick flashcard review using the real sentences where each word was found.
struct ReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vocabulary: VocabularyStore
    @Query(sort: \VocabWord.nextReview) private var words: [VocabWord]
    @State private var queue: [VocabWord] = []
    @State private var revealed = false
    @State private var started = false
    @State private var done = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let word = queue.first {
                    card(for: word)
                    Spacer(minLength: 0)
                    if revealed {
                        HStack(spacing: 16) {
                            answerButton("Não lembrei", color: .orange) { answer(word, remembered: false) }
                            answerButton("Lembrei", color: .green) { answer(word, remembered: true) }
                        }
                    } else {
                        answerButton("Mostrar significado", color: .accentColor) {
                            withAnimation(.snappy) { revealed = true }
                        }
                    }
                } else {
                    Spacer()
                    ContentUnavailableView {
                        Label(done > 0 ? "Revisão concluída" : "Tudo em dia", systemImage: "checkmark.seal")
                    } description: {
                        Text(done > 0 ? "\(done) palavra(s) revisada(s)." : "Nenhuma palavra para revisar agora.")
                    } actions: {
                        if !words.isEmpty {
                            Button("Revisar tudo mesmo assim") { queue = words.shuffled(); revealed = false }
                        }
                    }
                    Spacer()
                }
            }
            .padding(20)
            .navigationTitle(queue.isEmpty ? "" : "\(queue.count) restante(s)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } }
            }
            .onAppear {
                guard !started else { return }
                started = true
                queue = words.filter { $0.nextReview <= .now }
            }
        }
    }

    private func card(for word: VocabWord) -> some View {
        let context = word.sortedContexts.randomElement()
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(word.headword).font(.largeTitle.weight(.bold))
                Spacer()
                Button { Speaker.say(word.headword) } label: {
                    Image(systemName: "speaker.wave.2.fill").font(.title3)
                }
                .accessibilityLabel("Ouvir pronúncia")
            }
            if let context {
                Text(Highlighter.highlight(context.form, in: context.sentence))
                    .font(.title3)
                if revealed {
                    VStack(alignment: .leading, spacing: 10) {
                        if !context.meaning.isEmpty {
                            Text(context.meaning)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(context.sentenceTranslation)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .id(word.key)
    }

    private func answerButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
    }

    private func answer(_ word: VocabWord, remembered: Bool) {
        vocabulary.review(word, remembered: remembered)
        done += 1
        withAnimation(.snappy) {
            revealed = false
            queue.removeFirst()
        }
    }
}
