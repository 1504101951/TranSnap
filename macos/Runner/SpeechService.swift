import AVFoundation

final class SpeechService {
    private var synthesizer: AVSpeechSynthesizer?
    private var spokenText: String?

    func toggle(text: String, language: String) -> Bool {
        let repeating = synthesizer?.isSpeaking == true && spokenText == text
        stop()
        guard !repeating else { return false }
        let synthesizer = self.synthesizer ?? AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: language)
        spokenText = text
        synthesizer.speak(utterance)
        return true
    }

    func stop() {
        spokenText = nil
        synthesizer?.stopSpeaking(at: .immediate)
    }

    static func voice(for code: String) -> AVSpeechSynthesisVoice? {
        let language = Locale.Language(identifier: code)
        if let base = language.languageCode?.identifier, let region = language.maximalIdentifier.split(separator: "-").last,
           let voice = AVSpeechSynthesisVoice(language: "\(base)-\(region)") {
            return voice
        }
        return AVSpeechSynthesisVoice(language: code)
    }
}
