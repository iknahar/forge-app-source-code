import SwiftUI
import AppKit

/// The "magic translation" overlay that paints translated text on top of
/// the screenshot selection. Sits in its own NSPanel, sized and
/// positioned exactly over the selection rect.
///
/// Visual contract:
///   • A subtle dim layer over the whole selection.
///   • Per-text-block: a darker overlay rectangle + the target-language
///     text rendered in white on top.
///   • Two pill dropdowns at the top — Source (with Auto-detect) and
///     Target — that live-update the translation whenever changed.
///   • A magic shimmer effect that sweeps across the selection while
///     translation is running.
///   • A small × button in the top-right to dismiss back to selection.
struct TranslationOverlayPanel: View {

    /// Live state owned by the parent (the module). The view re-renders
    /// whenever any of these change.
    @ObservedObject var model: TranslationOverlayModel

    var body: some View {
        let m = model.layoutMetrics

        // We use absolute positioning inside a ZStack so the per-block
        // overlay can be anchored EXACTLY over the original selection
        // rect (panel-local coords), while the controls strip floats
        // outside it (above or below) without being constrained by
        // the same frame.
        ZStack(alignment: .topLeading) {
            // Transparent container that fills the whole panel — keeps
            // hit-testing on dropdowns/× working.
            Color.clear

            // 1. Selection-shaped block of: base dim, per-block dark
            //    overlays + translated text, shimmer while loading.
            selectionLayer
                .frame(width: m.selectionInPanel.width,
                       height: m.selectionInPanel.height)
                .clipped()
                .position(x: m.selectionInPanel.midX,
                          y: m.selectionInPanel.midY)

            // 2. Controls strip — sits ABOVE the selection by default
            //    (or below when there's no room above). Uses the full
            //    panel width so the language pills stay left-anchored
            //    and the × stays right-anchored.
            controlsRow
                .frame(width: m.panelSize.width, height: m.stripHeight)
                .position(
                    x: m.panelSize.width / 2,
                    y: m.stripIsBelow
                        ? (m.selectionInPanel.maxY + (m.stripHeight / 2) + 2)
                        : (m.selectionInPanel.minY - (m.stripHeight / 2) - 2)
                )
        }
        .frame(width: m.panelSize.width, height: m.panelSize.height)
        .background(Color.clear)
    }

    /// The per-block translation layer that sits exactly over the
    /// original selection rect. Same content as before (faint dim +
    /// per-block dark overlays + shimmer), but now factored out so
    /// the controls can live OUTSIDE this rect.
    private var selectionLayer: some View {
        ZStack {
            // Faint base dim
            Color.black.opacity(0.25)

            // Per-block dark overlay + translated text
            GeometryReader { geo in
                ForEach(model.blocks) { block in
                    blockOverlay(block, in: geo.size)
                }
            }
            .allowsHitTesting(false)

            // Magic shimmer while translating
            if model.isTranslating {
                shimmer
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Per-block overlay

    /// Draws one dark rectangle covering the original line + the
    /// translated text rendered in white on top.
    private func blockOverlay(_ block: ScreenTranslator.TextBlock,
                              in size: CGSize) -> some View {
        // Vision returns boundingBox in unit coords with BOTTOM-LEFT
        // origin. SwiftUI uses TOP-LEFT, so flip Y.
        let rect = CGRect(
            x: block.boundingBox.minX * size.width,
            y: (1 - block.boundingBox.maxY) * size.height,
            width: block.boundingBox.width * size.width,
            height: block.boundingBox.height * size.height
        )
        let display = block.translated ?? block.original
        // Pick a font size that roughly matches the original text height
        // so the overlay reads like a 1:1 replacement, not a tooltip.
        let fontSize = max(10, min(rect.height * 0.78, 32))

        return ZStack {
            // Heavy dim — the user shouldn't be able to read the
            // original through it, but the layout still shows through.
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(0.78))

            // Yellow on black for the translated text — better
            // contrast than white on black at small sizes, and
            // makes the overlay visibly read as "annotation" vs.
            // original content. The drop shadow stays for edge
            // crispness against busy backgrounds.
            Text(display)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(.yellow)
                .shadow(color: .black.opacity(0.7), radius: 1, y: 0)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 4)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .opacity(block.translated == nil && !model.isTranslating ? 0.55 : 1)
        // Subtle reveal when each block's translation lands
        .animation(.easeOut(duration: 0.35), value: block.translated)
    }

    // MARK: - Controls row

    private var controlsRow: some View {
        HStack(spacing: 8) {
            // Language pills — pinned LEFT, OUTSIDE the selection rect.
            languagePill(
                label: ScreenTranslator.label(forCode: effectiveSourceLabel),
                isSource: true
            ) {
                Menu {
                    ForEach(ScreenTranslator.supportedLanguages, id: \.code) { lang in
                        Button {
                            model.changeSource(to: lang.code)
                        } label: {
                            HStack {
                                Text(lang.label)
                                if lang.code == model.sourceLanguage {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(ScreenTranslator.label(forCode: effectiveSourceLabel))
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(.white)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.6))

            languagePill(
                label: ScreenTranslator.label(forCode: model.targetLanguage),
                isSource: false
            ) {
                Menu {
                    ForEach(ScreenTranslator.supportedLanguages.filter { $0.code != "auto" },
                            id: \.code) { lang in
                        Button {
                            model.changeTarget(to: lang.code)
                        } label: {
                            HStack {
                                Text(lang.label)
                                if lang.code == model.targetLanguage {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(ScreenTranslator.label(forCode: model.targetLanguage))
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(.white)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            // Offline badge — shown when the last pass detected no
            // network. Sits between the language pills and the × so
            // it's noticeable without obscuring the controls.
            if model.isOffline {
                HStack(spacing: 4) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 10, weight: .bold))
                    Text("Offline")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    Capsule().fill(Color(red: 0.92, green: 0.30, blue: 0.18))
                )
                .help("Translation needs an internet connection")
                .transition(.opacity)
            }

            Spacer()

            // Dismiss
            Button(action: model.onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(Color.black.opacity(0.55))
                    )
            }
            .buttonStyle(.plain)
            .help("Dismiss translation overlay")
        }
    }

    /// What to render inside the source dropdown label. When the user
    /// kept "auto" we show the detected code (e.g. "Swedish") with a
    /// little badge instead of literally "Auto-detect" — way more
    /// useful information.
    private var effectiveSourceLabel: String {
        if model.sourceLanguage == "auto", let d = model.detectedLanguage {
            return d
        }
        return model.sourceLanguage
    }

    private func languagePill<Content: View>(label: String,
                                             isSource: Bool,
                                             @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(
                    isSource
                        ? Color.black.opacity(0.55)
                        : Color(red: 0.06, green: 0.45, blue: 0.95).opacity(0.78)
                )
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
    }

    // MARK: - Magic shimmer

    /// A diagonal white gradient that sweeps across the selection while
    /// the translation is in flight. Adds the "magic happening" beat the
    /// user asked for.
    @State private var shimmerPhase: CGFloat = -1.5

    private var shimmer: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.25),
                    Color.white.opacity(0),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: geo.size.width * 0.6)
            .offset(x: shimmerPhase * geo.size.width)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1.5
                }
            }
        }
        .clipped()
    }
}

// MARK: - Model

/// Observable state for the translation overlay. The module owns one of
/// these per active translation session and feeds the SwiftUI view via
/// `@ObservedObject`. Changing `sourceLanguage` / `targetLanguage`
/// here triggers `onLanguageChange`, which re-runs the pipeline.
final class TranslationOverlayModel: ObservableObject {
    /// Geometry hints from the module: where in the panel's local
    /// coordinate space the controls strip and the per-block overlay
    /// should go. Set once when the panel is created and read by the
    /// SwiftUI view.
    struct LayoutMetrics {
        let panelSize: CGSize
        let selectionInPanel: CGRect   // panel-local rect of the original selection
        let stripHeight: CGFloat       // height reserved for the controls strip
        let stripIsBelow: Bool         // true ⇒ strip sits below the selection, not above
    }

    @Published var blocks: [ScreenTranslator.TextBlock] = []
    @Published var sourceLanguage: String
    @Published var targetLanguage: String
    @Published var detectedLanguage: String?
    @Published var isTranslating: Bool = false
    @Published var statusReason: String?
    /// True when the last translation attempt failed because the
    /// device wasn't online — the overlay shows a small offline badge
    /// next to the language pills.
    @Published var isOffline: Bool = false
    /// Geometry — set by the module right after building the panel.
    /// Defaults to a degenerate value so the view renders something
    /// during the brief moment before the first layout.
    @Published var layoutMetrics = LayoutMetrics(
        panelSize: .zero,
        selectionInPanel: .zero,
        stripHeight: 32,
        stripIsBelow: false
    )

    let onDismiss: () -> Void
    let onLanguageChange: (_ source: String, _ target: String) -> Void

    init(sourceLanguage: String,
         targetLanguage: String,
         onDismiss: @escaping () -> Void,
         onLanguageChange: @escaping (String, String) -> Void) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.onDismiss = onDismiss
        self.onLanguageChange = onLanguageChange
    }

    func changeSource(to code: String) {
        guard code != sourceLanguage else { return }
        sourceLanguage = code
        onLanguageChange(sourceLanguage, targetLanguage)
    }

    func changeTarget(to code: String) {
        guard code != targetLanguage else { return }
        targetLanguage = code
        onLanguageChange(sourceLanguage, targetLanguage)
    }

    /// Replace `blocks` + status fields from a fresh translation pass.
    @MainActor
    func apply(result: ScreenTranslator.Result) {
        blocks = result.blocks
        detectedLanguage = result.detectedLanguage
        statusReason = result.translationUnavailableReason
        isOffline = result.isOffline
        // If the user kept "auto" and the detection updated, fold it in
        // by leaving `sourceLanguage` as "auto" — the view picks the
        // detected label for display.
        isTranslating = false
    }
}
