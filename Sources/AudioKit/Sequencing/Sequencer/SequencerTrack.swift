// Copyright AudioKit. All Rights Reserved. Revision History at http://github.com/AudioKit/AudioKit/

#if !os(tvOS)

import CAudioKit
import Foundation

/// Audio player that loads a sample into memory
open class SequencerTrack {

    /// Node sequencer sends data to
    public var targetNode: Node?

    /// Length of the track in beats
    public var length: Double = 4 {
        didSet {
            updateSequence()
        }
    }

    /// Speed of the track in beats per minute
    public var tempo: BPM = 120 {
        didSet {
            updateSequence()
        }
    }

    /// Maximum number of times to play, ie. loop the track
    /// 0 means loop indefinitely
    public var numberOfLoops: Int = 0 {
        didSet {
            updateSequence()
        }
    }

    /// Is looping enabled?
    public var loopEnabled: Bool = true {
        didSet {
            updateSequence()
        }
    }

    /// Is the track currently playing?
    public var isPlaying: Bool {
        return akSequencerEngineIsPlaying(engine)
    }

    /// Current position of the track
    public var currentPosition: Double {
        akSequencerEngineGetPosition(engine)
    }

    /// Current position of the track
    public var currentLoop: Int {
        Int(akSequencerEngineGetCurrentLoop(engine))
    }

    private var engine: SequencerEngineRef

    // MARK: - Initialization

    /// Initialize the track
    public init(targetNode: Node?) {
        self.targetNode = targetNode
        engine = akSequencerEngineCreate()
    }

    deinit {
        if let auAudioUnit = targetNode?.avAudioUnit?.auAudioUnit {
            if let token = renderObserverToken {
                auAudioUnit.removeRenderObserver(token)
            }
        }
        akSequencerEngineDestroy(engine)
    }

    /// Start the track
    public func play() {
        akSequencerEnginePlay(engine)
    }

    /// Start the track from the beginning
    public func playFromStart() {
        akSequencerEnginePlayFromStart(engine)
    }

    /// Start the track after a certain delay in beats
    public func playAfterDelay(beats: Double) {
        seek(to: -1 * beats)
        akSequencerEnginePlay(engine)
    }

    /// Stop playback
    public func stop() {
        akSequencerEngineStop(engine)
    }

    /// Set the current position to the start ofthe track
    public func rewind() {
        seek(to: 0)
    }

    /// Move to a position in the track
    public func seek(to position: Double) {
        akSequencerEngineSeekTo(engine, position)
    }

    /// Sequence
    public var sequence = NoteEventSequence() {
        didSet {
            updateSequence()
        }
    }

    /// Remove the notes in the track
    public func clear() {
        sequence = NoteEventSequence()
    }

    // NOTE: This does not stop the sequencer
    // this is just exposed. Use track.stop()
    /// Stop playing all the notes currently playing
    public func stopPlayingNotes() {
        akSequencerEngineStopPlayingNotes(engine)
    }

    /// Stop sequencer and send Note-Off messages for every note
    public func panic() {
        akSequencerEnginePanic(engine)
    }

    private var renderObserverToken: Int?

    private func updateSequence() {
        guard let block = targetNode?.avAudioUnit?.auAudioUnit.scheduleMIDIEventBlock else {
            Log("Failed to get AUScheduleMIDIEventBlock")
            return
        }

        let settings = SequenceSettings(length: length,
                                          tempo: tempo,
                                          loopEnabled: loopEnabled,
                                          numberOfLoops: Int32(numberOfLoops))

        let orderedEvents = sequence.beatTimeOrderedEvents()

        orderedEvents.withUnsafeBufferPointer { (eventsPtr: UnsafeBufferPointer<SequenceEvent>) -> Void in
            guard let observer = SequencerEngineUpdateSequence(engine,
                                                                 eventsPtr.baseAddress,
                                                                 orderedEvents.count,
                                                                 settings,
                                                                 Settings.sampleRate,
                                                                 block) else { return }

            guard let auAudioUnit = targetNode?.avAudioUnit?.auAudioUnit else { return }

            if let token = renderObserverToken {
                auAudioUnit.removeRenderObserver(token)
            }

            renderObserverToken = auAudioUnit.token(byAddingRenderObserver: observer)
        }
    }
}

#endif
