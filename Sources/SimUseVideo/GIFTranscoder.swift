// SPDX-License-Identifier: Apache-2.0
import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import SimUseCore

public enum GIFTranscoderError: Error, LocalizedError, Equatable {
    case noVideoTrack
    case noFrames
    case cannotCreateDestination(String)
    case finalizeFailed

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "Recording contains no video track"
        case .noFrames:
            return "Recording contains no video frames"
        case .cannotCreateDestination(let path):
            return "Unable to create GIF file at \(path)"
        case .finalizeFailed:
            return "Failed to finalize GIF file"
        }
    }
}

/// Transcodes a finalized MP4 recording into an animated GIF.
///
/// GIF is a post-step rather than a fourth capture path on purpose: none
/// of the capture pipelines (idb's in-process recorder on iOS, `adb
/// screenrecord` passthrough on Android, the screenshot fallback) expose
/// decoded frames in-process, and the signal-to-finalise path of the
/// recording loop is latency-critical — transcoding after the MP4
/// trailer is on disk keeps that path untouched and covers every capture
/// mode with a single implementation.
///
/// Two passes over the asset bound *decode* memory to one frame:
///
///   1. A decoding read collects presentation timestamps (discarding the
///      pixels), which fixes the sampled frame count —
///      `CGImageDestination` requires the image count at creation time.
///      A passthrough (non-decoding) read would be cheaper but its raw
///      PTS carry B-frame reorder offsets, un-applied edit lists, and
///      trailer artifacts; only the decoded output's timestamps are the
///      display timeline.
///   2. BGRA decode appends only the sampled frames to the destination.
///
/// The *encode* side is not bounded: `CGImageDestination` holds every
/// added frame until finalize (ImageIO has no incremental GIF writer),
/// so peak memory grows linearly with the sampled frame count — see
/// `memoryWarningFrameThreshold`.
///
/// Sampling at `fps` also normalizes Android's variable-frame-rate
/// `screenrecord` output; per-frame delays come from the actual sampled
/// timestamp deltas, so wall-clock pacing survives the resample.
public enum GIFTranscoder {
    /// GIF delay resolution is centiseconds; browsers treat delays below
    /// 2 cs as "as fast as possible", so clamp to keep pacing honest.
    static let minimumDelay: Double = 0.02

    /// The centisecond delay floor makes 50 the highest frame rate a GIF
    /// can pace truthfully — sampling faster would clamp every delay up
    /// and stretch playback past wall clock.
    static let maximumFPS = 50

    /// Past this many sampled frames the in-memory encode gets heavy
    /// (roughly 9 MB per half-scale iPhone frame at finalize); warn so
    /// the user can pick a lower `--fps` or record mp4 for long sessions.
    static let memoryWarningFrameThreshold = 300

    /// Result of the timestamp-sampling pass.
    struct SamplingPlan: Equatable {
        /// Presentation timestamps (seconds, ascending) of the frames to keep.
        let timestamps: [Double]
        /// Per-frame GIF delays (seconds), same count as `timestamps`.
        let delays: [Double]
    }

    /// Select frames from `presentationTimes` (seconds, any order) by
    /// walking a target clock in `1/fps` steps — a frame is kept when it
    /// reaches the next target, and the clock then advances from the kept
    /// frame. Target accumulation (rather than distance-to-previous)
    /// keeps the *average* rate at `fps` even when source spacing beats
    /// against the interval.
    ///
    /// Timing honesty is enforced in two places so the centisecond floor
    /// never stretches playback: a frame closer than `minimumDelay` to
    /// the previous kept frame is not selected at all (clamping it up
    /// would owe time the GIF can't repay), and each kept frame's delay
    /// quantizes the *cumulative* timeline to centiseconds, so per-frame
    /// rounding carries forward instead of accumulating. The last frame
    /// holds for the nominal interval.
    static func plan(presentationTimes: [Double], fps: Int) -> SamplingPlan {
        let sorted = presentationTimes.sorted()
        guard !sorted.isEmpty else { return SamplingPlan(timestamps: [], delays: []) }

        let interval = 1.0 / Double(min(fps, Self.maximumFPS))
        // Quarter-frame tolerance absorbs encoder timestamp jitter when
        // the source is already at the target rate, without letting a
        // higher-rate source sneak extra frames through. The gap check
        // gets a tighter 1 ms allowance for the same jitter.
        let epsilon = interval * 0.25

        var kept: [Double] = [sorted[0]]
        var nextTarget = sorted[0] + interval
        for pts in sorted.dropFirst()
        where pts >= nextTarget - epsilon && pts - kept[kept.count - 1] >= Self.minimumDelay - 0.001 {
            kept.append(pts)
            nextTarget = max(nextTarget, pts) + interval
        }

        var delays: [Double] = []
        var elapsed = 0.0
        var quantized = 0.0
        for (index, pts) in kept.enumerated() {
            elapsed += index + 1 < kept.count ? kept[index + 1] - pts : interval
            let centiseconds = max((elapsed - quantized) * 100.0, Self.minimumDelay * 100.0).rounded()
            let delay = centiseconds / 100.0
            quantized += delay
            delays.append(delay)
        }
        return SamplingPlan(timestamps: kept, delays: delays)
    }

    /// Transcode `mp4URL` into an animated GIF at `gifURL`, sampling at
    /// `fps` (capped at `maximumFPS`). Returns the number of frames
    /// actually written.
    @discardableResult
    public static func transcode(mp4URL: URL, to gifURL: URL, fps: Int) async throws -> Int {
        let asset = AVURLAsset(url: mp4URL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw GIFTranscoderError.noVideoTrack
        }

        let plan = Self.plan(presentationTimes: try Self.readPresentationTimes(asset: asset, track: track), fps: fps)
        guard !plan.timestamps.isEmpty else {
            throw GIFTranscoderError.noFrames
        }
        if plan.timestamps.count > Self.memoryWarningFrameThreshold {
            FileHandle.standardError.write(Data("warning: GIF has \(plan.timestamps.count) frames; the encoder holds all of them in memory until the file is written — for long sessions prefer a lower --fps or --format mp4\n".utf8))
        }

        guard let destination = CGImageDestinationCreateWithURL(
            gifURL as CFURL,
            UTType.gif.identifier as CFString,
            plan.timestamps.count,
            nil
        ) else {
            throw GIFTranscoderError.cannotCreateDestination(gifURL.path)
        }

        let gifProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0 // loop forever
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        let appended = try Self.appendSampledFrames(asset: asset, track: track, plan: plan, to: destination)
        guard appended > 0 else {
            throw GIFTranscoderError.noFrames
        }

        guard CGImageDestinationFinalize(destination) else {
            throw GIFTranscoderError.finalizeFailed
        }
        return appended
    }

    /// Convenience wrapper for the record-video post-step: transcodes and
    /// removes the intermediate MP4 on success; on failure, preserves it
    /// and says where it is (so a failed transcode never discards the
    /// captured footage) while removing the partially written GIF, which
    /// would otherwise read as a successful recording to any
    /// does-the-file-exist check.
    public static func transcodeRecording(tempMP4: URL, to gifURL: URL, fps: Int) async throws {
        FileHandle.standardError.write(Data("Transcoding to GIF...\n".utf8))
        do {
            let frames = try await transcode(mp4URL: tempMP4, to: gifURL, fps: fps)
            try? FileManager.default.removeItem(at: tempMP4)
            FileHandle.standardError.write(Data("GIF written (\(frames) frames)\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: gifURL)
            throw CLIError(
                errorDescription: "Failed to transcode recording to GIF: \(error.localizedDescription); intermediate MP4 preserved at \(tempMP4.path)"
            )
        }
    }

    /// Pass 1 — display-timeline presentation timestamps via a decoding
    /// read (pixels discarded; decoder-native 4:2:0 halves the bandwidth
    /// of a BGRA conversion nothing looks at). See the type comment for
    /// why passthrough PTS can't drive the plan.
    private static func readPresentationTimes(asset: AVURLAsset, track: AVAssetTrack) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? GIFTranscoderError.noFrames
        }

        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if pts.isValid {
                times.append(pts.seconds)
            }
        }
        if reader.status == .failed {
            throw reader.error ?? GIFTranscoderError.noFrames
        }
        return times
    }

    /// Pass 2 — BGRA decode, appending only the planned frames. Decoded
    /// output arrives in presentation order, so a single cursor over the
    /// (ascending) planned timestamps pairs frames without buffering.
    /// Returns the number of frames actually appended: a frame whose
    /// pixels can't be converted consumes its plan slot (keeping every
    /// later frame's delay paired correctly) and is dropped.
    private static func appendSampledFrames(
        asset: AVURLAsset,
        track: AVAssetTrack,
        plan: SamplingPlan,
        to destination: CGImageDestination
    ) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? GIFTranscoderError.noFrames
        }

        // Timestamps in pass 2 are re-derived from the same samples as
        // pass 1, so match with a small absolute tolerance rather than
        // exact float equality.
        let tolerance = 0.001
        var cursor = 0
        var appended = 0

        while cursor < plan.timestamps.count, let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isValid, pts.seconds >= plan.timestamps[cursor] - tolerance else { continue }
            let slot = cursor
            cursor += 1
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            guard let cgImage else { continue }

            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: plan.delays[slot],
                    kCGImagePropertyGIFUnclampedDelayTime: plan.delays[slot]
                ]
            ]
            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
            appended += 1
        }
        if reader.status == .failed {
            throw reader.error ?? GIFTranscoderError.noFrames
        }
        reader.cancelReading()
        return appended
    }
}
