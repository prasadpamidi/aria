import MarkdownUI
import SwiftUI

// MARK: - Avyra markdown theme

/// Custom `MarkdownUI` theme tuned for Avyra's dark glass chat
/// bubbles. Keeps body text in `.body` so it matches the streaming
/// flow we had before MarkdownUI replaced `Text`, but adds proper
/// styling for the structural elements `Text(LocalizedStringKey:)`
/// couldn't render at all:
///
///   - Headings — sized + weighted, with breathing room above
///   - Lists — bulleted + numbered with hanging indent
///   - Tables — bordered, with header emphasis
///   - Block quotes — accent-tinted left rule
///   - Inline code — monospaced + subtle background fill
///   - Code blocks — Splash-style dark scheme card
///   - Links — accent color, underline on tap
///   - Horizontal rules — thin secondary divider
///
/// The dark-chat-bubble assumption matters: backgrounds are sourced
/// from `Color(.systemBackground)` siblings so the elements look
/// integrated whether the surrounding bubble is the `.tertiarySystem`
/// fill we use for assistant or the accent tint for user (we only
/// apply this theme to the assistant bubble — user bubbles are
/// short, plain text).
extension Theme {
    static let avyraChat = Theme()
        // Body inherits the default `.body` font for parity with the
        // streamer's render. We re-spell it here so the theme is
        // self-contained and easy to tune.
            .text {
                FontSize(.em(1.0))
                ForegroundColor(.primary)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.92))
                BackgroundColor(Color.primary.opacity(0.08))
            }
            .strong { FontWeight(.semibold) }
            .emphasis { FontStyle(.italic) }
            .strikethrough { StrikethroughStyle(.single) }
            .link { ForegroundColor(.accentColor) }
            // Headings — leading + trailing margins so consecutive
            // paragraphs read as separate beats.
            .heading1 { configuration in
                VStack(alignment: .leading, spacing: 4) {
                    configuration.label
                        .markdownMargin(top: 12, bottom: 6)
                        .markdownTextStyle {
                            FontWeight(.bold)
                            FontSize(.em(1.6))
                        }
                    Divider().opacity(0.4)
                }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: 12, bottom: 4)
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(.em(1.4))
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: 10, bottom: 4)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.2))
                    }
            }
            .heading4 { configuration in
                configuration.label
                    .markdownMargin(top: 8, bottom: 4)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.05))
                    }
            }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(top: 0, bottom: 8)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                    configuration.label
                        .padding(.leading, 10)
                        .padding(.vertical, 4)
                        .markdownTextStyle {
                            ForegroundColor(.secondary)
                            FontStyle(.italic)
                        }
                }
                .markdownMargin(top: 4, bottom: 8)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .relativeLineSpacing(.em(0.18))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.88))
                            ForegroundColor(.primary)
                        }
                        .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .markdownMargin(top: 6, bottom: 10)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .table { configuration in
                configuration.label
                    .markdownTableBorderStyle(.init(color: .primary.opacity(0.15)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            Color.primary.opacity(0.02),
                            Color.primary.opacity(0.06)
                        )
                    )
                    .markdownMargin(top: 6, bottom: 10)
            }
            .tableCell { configuration in
                configuration.label
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .markdownTextStyle {
                        FontSize(.em(0.95))
                    }
            }
            .thematicBreak {
                Divider()
                    .markdownMargin(top: 8, bottom: 8)
            }
}
