import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vocabulary: VocabularyStore
    @Query(sort: \VocabWord.updatedAt, order: .reverse) private var words: [VocabWord]
    @State private var search = ""
    @State private var reviewing = false

    private var filtered: [VocabWord] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return words }
        return words.filter { word in
            word.headword.localizedCaseInsensitiveContains(query)
                || word.contexts.contains {
                    $0.form.localizedCaseInsensitiveContains(query)
                        || $0.meaning.localizedCaseInsensitiveContains(query)
                        || $0.sentence.localizedCaseInsensitiveContains(query)
                        || $0.sentenceTranslation.localizedCaseInsensitiveContains(query)
                }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { word in
                    NavigationLink(value: word) { WordRow(word: word) }
                }
                .onDelete { offsets in
                    let items = offsets.map { filtered[$0] }
                    items.forEach(vocabulary.delete)
                }
            }
            .listStyle(.plain)
            .overlay {
                if words.isEmpty {
                    ContentUnavailableView("Nenhuma palavra ainda",
                                           systemImage: "text.word.spacing",
                                           description: Text("Toque em uma palavra das legendas para salvá-la aqui com o contexto."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Palavra, frase ou significado")
            .navigationTitle("Vocabulário")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: VocabWord.self) { WordDetailView(word: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Revisar", systemImage: "rectangle.on.rectangle.angled") { reviewing = true }
                        .labelStyle(.titleAndIcon)
                        .disabled(words.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OK") { dismiss() }.fontWeight(.semibold)
                }
            }
            .fullScreenCover(isPresented: $reviewing) { ReviewView() }
            .task { await vocabulary.enrichPending() }
        }
    }
}

struct WordRow: View {
    let word: VocabWord

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(word.headword)
                    .font(.headline)
                Text(word.latestMeaning.isEmpty ? "…" : word.latestMeaning)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if word.contexts.count > 1 {
                Text("\(word.contexts.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                    .accessibilityLabel("\(word.contexts.count) contextos")
            }
        }
        .padding(.vertical, 4)
    }
}

struct WordDetailView: View {
    let word: VocabWord
    @EnvironmentObject private var vocabulary: VocabularyStore

    var body: some View {
        List {
            Section {
                HStack {
                    Text(word.headword)
                        .font(.largeTitle.weight(.bold))
                    Spacer()
                    Button {
                        Speaker.say(word.headword)
                    } label: {
                        Image(systemName: "speaker.wave.2.fill").font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Ouvir pronúncia")
                }
                .listRowSeparator(.hidden)
            }

            Section(word.contexts.count == 1 ? "Contexto" : "\(word.contexts.count) contextos") {
                ForEach(word.sortedContexts) { item in
                    ContextCard(item: item)
                        .swipeActions {
                            Button("Apagar", systemImage: "trash", role: .destructive) {
                                vocabulary.delete(item)
                            }
                        }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ContextCard: View {
    let item: WordContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !item.meaning.isEmpty {
                Text(item.meaning)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text(Highlighter.highlight(item.form, in: item.sentence))
                .font(.body)
            Text(item.sentenceTranslation.isEmpty ? "Traduzindo…" : item.sentenceTranslation)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(item.createdAt, format: .dateTime.day().month().year().hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .textSelection(.enabled)
    }
}

enum Highlighter {
    static func highlight(_ word: String, in sentence: String) -> AttributedString {
        var attributed = AttributedString(sentence)
        guard let range = Lemmatizer.range(of: word, at: nil, in: sentence),
              let lower = AttributedString.Index(range.lowerBound, within: attributed),
              let upper = AttributedString.Index(range.upperBound, within: attributed) else { return attributed }
        attributed[lower..<upper].font = .body.bold()
        attributed[lower..<upper].foregroundColor = .accentColor
        return attributed
    }
}
