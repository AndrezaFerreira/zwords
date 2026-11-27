import SwiftUI
import Translation

/// The whole app is one screen: live captions + three controls.
struct RootView: View {
    @EnvironmentObject private var engine: CaptionEngine
    @EnvironmentObject private var translator: TranslationService
    @EnvironmentObject private var vocabulary: VocabularyStore
    @AppStorage("displayMode") private var mode: DisplayMode = .bilingual
    @State private var showLibrary = false
    @State private var toast: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // Source layer for Picture in Picture (kept tiny, behind the UI).
            PiPHostView(pip: engine.pip)
                .frame(width: 120, height: 40)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                CaptionsView(mode: mode)
                statusBar
                ControlBar(pip: engine.pip)
            }
        }
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showLibrary) {
            LibraryView()
                .presentationDragIndicator(.visible)
        }
        .translationTask(translator.configuration) { session in
            await translator.serve(session)
        }
        .task {
            engine.mode = mode
            translator.activate()
            await engine.prepare()
            await vocabulary.enrichPending()
        }
        .onChange(of: mode) { _, newValue in engine.mode = newValue }
        .onChange(of: translator.isReady) { _, ready in
            if ready { Task { await vocabulary.enrichPending() } }
        }
        .onChange(of: vocabulary.lastSaved?.serial) { _, _ in
            guard let word = vocabulary.lastSaved?.word else { return }
            withAnimation(.snappy) { toast = word }
            Task {
                try? await Task.sleep(for: .seconds(1.3))
                withAnimation(.easeOut) { if toast == word { toast = nil } }
            }
        }
        .sensoryFeedback(.success, trigger: vocabulary.lastSaved?.serial)
    }

    private var header: some View {
        HStack {
            Picker("Legendas", selection: $mode) {
                ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            Spacer()

            Button {
                showLibrary = true
            } label: {
                Image(systemName: "books.vertical")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Biblioteca de vocabulário")
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var statusBar: some View {
        if let notice = engine.notice {
            Button {
                engine.notice = nil
            } label: {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 6)
        } else if let problem = translator.problem, mode != .english {
            Button {
                translator.retry()
            } label: {
                Label(problem, systemImage: "character.bubble")
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 52)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityLabel("\(toast) salvo na biblioteca")
        }
    }
}
