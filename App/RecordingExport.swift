import AVFoundation
import SayWhatCore

/// Builds the mixed AVFoundation composition for a finished recording — both AAC
/// tracks' rotating segments concatenated in order and overlaid from session time
/// 0. Shared by ``PlaybackController`` (to render karaoke playback) and
/// ``RecordingExporter`` (to write a shareable file). The tracks stay separate on
/// disk (the core invariant); mixing is a deliberate, playback/share-only
/// exception, the same one DESIGN.md calls out for following the transcript.
enum RecordingMix {
    /// Assemble both tracks of a finalized `session` into one composition.
    static func composition(for session: RecordingSession) async -> AVMutableComposition {
        let reader = RecordingReader()
        let composition = AVMutableComposition()
        for source in CaptureSource.allCases {
            await appendTrack(reader.segmentURLs(for: source, in: session), to: composition)
        }
        return composition
    }

    /// Concatenate one track's ordered segment files into a fresh composition audio
    /// track, starting at time 0. An empty track is skipped; unreadable segments
    /// are dropped so one bad rotation can't sink the whole mix.
    private static func appendTrack(_ urls: [URL], to composition: AVMutableComposition) async {
        guard !urls.isEmpty,
              let track = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { return }

        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let assetDuration = try? await asset.load(.duration)
            else { continue }
            try? track.insertTimeRange(
                CMTimeRange(start: .zero, duration: assetDuration),
                of: source,
                at: cursor
            )
            cursor = CMTimeAdd(cursor, assetDuration)
        }
    }
}

/// Writes a finished recording's two tracks into a single shareable `recording.m4a`
/// alongside the session's audio, so the meeting can be handed off as one file.
///
/// A convenience derived from the durable per-track segments — never the source of
/// truth — so it's best-effort: a failure here leaves the originals untouched. AAC
/// at the Apple M4A preset; the two tracks sum into one stereo-downmixed file.
/// App-side and AVFoundation-backed, exercised by hand rather than unit tests
/// (QUALITY.md §6).
enum RecordingExporter {
    /// The combined file's name within the session directory.
    static let filename = "recording.m4a"

    enum ExportError: Error { case sessionEmpty, exportFailed }

    /// Export `session`'s mixed audio to `recording.m4a`, replacing any prior copy,
    /// and return its URL. Throws ``ExportError/sessionEmpty`` when there's nothing
    /// to write (e.g. a zero-length recording).
    @discardableResult
    static func exportCombined(_ session: RecordingSession) async throws -> URL {
        let composition = await RecordingMix.composition(for: session)
        guard composition.duration.seconds > 0 else { throw ExportError.sessionEmpty }

        let output = session.directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: output)

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw ExportError.exportFailed }

        try await export.export(to: output, as: .m4a)
        return output
    }
}
