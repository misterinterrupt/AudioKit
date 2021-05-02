// Copyright AudioKit. All Rights Reserved. Revision History at http://github.com/AudioKit/AudioKit/

import XCTest
import AudioKit
import CAudioKit
import AVFoundation

class SequencerEngineTests: XCTestCase {

    func buffersPerSecond(_ sampleRate: Double, _ frameCount: AUAudioFrameCount) -> Double {
        return sampleRate / Double(frameCount)
    }

    func samplesToSeconds(_ numSamples: AUAudioFrameCount, _ sampleRate: Double) -> Double {
        return Double(numSamples) / sampleRate
    }

    func beatsPerSecond(_ bpm: Double) -> Double {
        return bpm / 60;
    }

    func secondsPerBeat(_ bpm: Double) -> Double {
        return 60 / bpm;
    }

    func samplesToBeats(_ numSamples: AUAudioFrameCount, _ sampleRate: Double, _ bpm: Double) -> Double {
        let lengthInSeconds = samplesToSeconds(numSamples, sampleRate)
        return lengthInSeconds * beatsPerSecond(bpm);
    }

    func beatLengthInSeconds(_ bpm: Double, _ beatLength: Double) -> Double {
        return secondsPerBeat(bpm) * beatLength
    }

    func renderCount(_ beatLength: Double, bpm: Double, sampleRate: Double, frameCount: AUAudioFrameCount) -> Int {
        let bps = buffersPerSecond(sampleRate, frameCount)
        let lengthInSeconds = beatLengthInSeconds(bpm, beatLength)
        return Int((bps * lengthInSeconds).rounded(.up))
    }

    func testRenderCount() {
        var result1 = renderCount(1, bpm: 60, sampleRate: 44100.0, frameCount: 44100)
        var result2 = renderCount(60, bpm: 60, sampleRate: 44100.0, frameCount: 44100)
        XCTAssertEqual(result1, 1)
        XCTAssertEqual(result2, 60)
        result1 = renderCount(33, bpm: 60, sampleRate: 44100.0, frameCount: 44100)
        result2 = renderCount(45, bpm: 60, sampleRate: 44100.0, frameCount: 44100)
        XCTAssertEqual(result1, 33)
        XCTAssertEqual(result2, 45)
        result1 = renderCount(1, bpm: 120, sampleRate: 44100.0, frameCount: 44100)
        result2 = renderCount(2, bpm: 120, sampleRate: 44100.0, frameCount: 44100)
        XCTAssertEqual(result1, 1)
        XCTAssertEqual(result2, 1)
        result1 = renderCount(30, bpm: 120, sampleRate: 44100.0, frameCount: 44100)
        result2 = renderCount(45, bpm: 120, sampleRate: 44100.0, frameCount: 44100)
        XCTAssertEqual(result1, 15)
        XCTAssertEqual(result2, 23)
        result1 = renderCount(1, bpm: 120, sampleRate: 44100.0, frameCount: 256)
        result2 = renderCount(1, bpm: 120, sampleRate: 44100.0, frameCount: 512)
        XCTAssertEqual(result1, 87)
        XCTAssertEqual(result2, 44)
        result1 = renderCount(2, bpm: 120, sampleRate: 44100.0, frameCount: 256)
        result2 = renderCount(2, bpm: 120, sampleRate: 44100.0, frameCount: 512)
        XCTAssertEqual(result1, 173)
        XCTAssertEqual(result2, 87)
        result1 = renderCount(5, bpm: 120, sampleRate: 48000.0, frameCount: 1024)
        result2 = renderCount(8, bpm: 120, sampleRate: 48000.0, frameCount: 4096)
        XCTAssertEqual(result1, 118)
        XCTAssertEqual(result2, 47)
        result1 = renderCount(3, bpm: 75, sampleRate: 48000.0, frameCount: 256)
        XCTAssertEqual(result1, 451)
        // 48k sr / 512 fps => 93.75 buffers per second
        // 3 beats at 150 bpm = 112.5 buffers => 1.2~ seconds
        // 93.75 buffers per second * 1.2~ seconds = 112.5 buffers
        result2 = renderCount(3, bpm: 150, sampleRate: 48000.0, frameCount: 512)
        // 112.5 rounded up to be sure all data has a shot at being processed is 113
        XCTAssertEqual(result2, 113)
    }

    /// Note:
    /// when the sequence loop is set to play a finite # of times,
    /// or the sequencer is stopped or destroyed,
    /// the sequencer will send note off msgs at the end
    func observerTest(sequence: NoteEventSequence,
                      bpm: Double = 120,
                      sequenceLength: Double = 1.0,
                      playLength: Double = 1.0,
                      sampleRate: Double = 44100.0,
                      frameCount: AUAudioFrameCount = 44100,
                      loopEnabled: Bool = false,
                      loopCount: Int = 0) -> [MIDIEvent] {

        let engine = akSequencerEngineCreate()

        let settings = SequenceSettings(length: sequenceLength,
                                        tempo: bpm,
                                        loopEnabled: loopEnabled,
                                        numberOfLoops: Int32(loopCount))

        let renderCallCount = renderCount(playLength, bpm: bpm, sampleRate: sampleRate, frameCount: frameCount)

        var scheduledEvents = [MIDIEvent]()

        let block: AUScheduleMIDIEventBlock = { (sampleTime, cable, length, midiBytes) in
            var bytes = [MIDIByte]()
            for index in 0 ..< length {
                bytes.append(midiBytes[index])
            }
            let timeStamp = MIDITimeStamp(sampleTime - AUEventSampleTimeImmediate)
            scheduledEvents.append(MIDIEvent(data: bytes, timeStamp: timeStamp))
        }

        let orderedEvents = sequence.beatTimeOrderedEvents()

        orderedEvents.withUnsafeBufferPointer { (eventsPtr: UnsafeBufferPointer<SequenceEvent>) -> Void in
            let observer = SequencerEngineUpdateSequence(engine,
                                                         eventsPtr.baseAddress,
                                                         orderedEvents.count,
                                                         settings,
                                                         sampleRate,
                                                         block)!

            var timeStamp = AudioTimeStamp()
            timeStamp.mSampleTime = 0

            akSequencerEnginePlayFromStart(engine)

            for index in 0..<renderCallCount {
                timeStamp.mSampleTime = Double(Int(frameCount) * index)
                print(")))) render at \(timeStamp.mSampleTime)")
                observer(.unitRenderAction_PreRender, &timeStamp, frameCount, 0 /* outputBusNumber*/)
            }
        }

        let finalPosition = akSequencerEngineGetPosition(engine)

        // sequencer will not report positions before the time it takes to process one buffer
        let minimumLength = samplesToBeats(frameCount, sampleRate, settings.tempo)
        var expectedPosition = playLength < minimumLength ? minimumLength : playLength

        if loopEnabled {
            expectedPosition = playLength.remainder(dividingBy: sequenceLength)
            print("expected position  : \(expectedPosition) looping")
        } else {
            print("minlength          : \(minimumLength)")
            print("expected position  : \(expectedPosition)")
        }
        print("final position     : \(finalPosition)")

        // sequencer position is quantized to the frameCount passed to engine::process()
        // accuracy window is one buffer duration in beat time
        let beatPositionAccuracy = samplesToBeats(frameCount, sampleRate, settings.tempo)

        // One second at 120bpm is two quarter note beats
        XCTAssertEqual(finalPosition, expectedPosition, accuracy: beatPositionAccuracy)

        akSequencerEngineDestroy(engine)
        return scheduledEvents
    }

    func testBasicSequence() {

        var seq = NoteEventSequence()

        seq.add(noteNumber: 60, position: 0.5, duration: 0.1)

        let events = observerTest(sequence: seq)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].noteNumber!, 60)
        XCTAssertEqual(events[0].status!.type, .noteOn)
        XCTAssertEqual(events[0].timeStamp, 11025)
        XCTAssertEqual(events[1].noteNumber!, 60)
        XCTAssertEqual(events[1].status!.type, .noteOff)
        XCTAssertEqual(events[1].timeStamp, 13230)
    }

    func testEmpty() {

        let events = observerTest(sequence: NoteEventSequence())
        XCTAssertEqual(events.count, 0)
    }

    func testChord() {

        var seq = NoteEventSequence()

        seq.add(noteNumber: 60, position: 0.0, duration: 1.0)
        seq.add(noteNumber: 63, position: 0.0, duration: 1.0)
        seq.add(noteNumber: 67, position: 0.0, duration: 1.0)

        let events = observerTest(sequence: seq)
        XCTAssertEqual(events.count, 6)

        XCTAssertEqual(events.map { $0.noteNumber! }, [60, 63, 67, 60, 63, 67])
        XCTAssertEqual(events.map { $0.timeStamp! }, [0, 0, 0, 22050, 22050, 22050])
    }

    func testLoop() {
        var seq = NoteEventSequence()

        seq.add(noteNumber: 60, position: 0.0, duration: 0.1)
        seq.add(noteNumber: 63, position: 1.0, duration: 0.1)

        let events = observerTest(sequence: seq, sequenceLength: 2.0, playLength: 12.0, frameCount: 256, loopEnabled: true, loopCount: 6)

        XCTAssertEqual(events.count, 24)

        XCTAssertEqual(events.map { $0.noteNumber! },
                       [60, 60, 63, 63, // loop 1
                        60, 60, 63, 63, // loop 2
                        60, 60, 63, 63, // etc..
                        60, 60, 63, 63,
                        60, 60, 63, 63,
                        60, 60, 63, 63])
        XCTAssertEqual(events.map { $0.timeStamp! },
                       [0,   157, 34,  191,  // [0, 157, 34, 191,
                        68,  225, 102, 3  ,  //  0, 225, 102, 3,
                        136, 37,  170, 71 ,  //  0, 37, 170, 71,
                        204, 105, 238, 139,  //  0, 105, 238, 139,
                        16,  173, 50,  207,  //  0, 173, 50, 207,
                        84,  241, 118, 19 ]) //  0, 241, 118, 19]

    }

    func testFiniteLoopEnd() {
        var seq = NoteEventSequence()

        seq.add(noteNumber: 60, position: 0.0, duration: 1.0)
        seq.add(noteNumber: 50, position: 1.0, duration: 1.0)

        let events = observerTest(sequence: seq, sequenceLength: 1.0, playLength: 2.0, frameCount: 128, loopEnabled: true, loopCount: 2)

        XCTAssertEqual(events.count, 4)

        XCTAssertEqual(events.map { $0.noteNumber! },
                       [60, 60,     // loop 1
                        60, 60])    // loop 2
        XCTAssertEqual(events.map { $0.timeStamp! },
                       [0, 34,
                        34, 68])
    }

    func testSampleAccuracyLargeBufferSize() {
        var seq = NoteEventSequence()

        seq.add(noteNumber: 60, position: 0.0, duration: 0.1)
        seq.add(noteNumber: 63, position: 1.0, duration: 0.1)

        let events = observerTest(sequence: seq, sequenceLength: 2.0, playLength: 4.0, frameCount: 44100, loopEnabled: true, loopCount: 2)

        XCTAssertEqual(events.count, 8)

        XCTAssertEqual(events.map { $0.noteNumber! },
                       [60, 60, 63, 63,
                        60, 60, 63, 63])
        XCTAssertEqual(events.map { $0.timeStamp! },
                       [0, 2205, 22050, 24255,
                        0, 2205, 22050, 24255])
    }

    func testOverlap() {

        var seq = NoteEventSequence()

        seq.add(noteNumber: 60, position: 0.0, duration: 1.0)
        seq.add(noteNumber: 63, position: 0.1, duration: 0.1)

        let events = observerTest(sequence: seq)
        XCTAssertEqual(events.count, 4)

        XCTAssertEqual(events.map { $0.noteNumber! }, [60, 63, 63, 60])
        XCTAssertEqual(events.map { $0.timeStamp }, [0, 2205, 4410, 22050])
    }
    
    func testSameNoteRepeating() {

        var seq = NoteEventSequence()

        seq.add(noteNumber: 60, position: 0.0, duration: 1.0)
        seq.add(noteNumber: 60, position: 1.0, duration: 0.5)

        let events = observerTest(sequence: seq, sequenceLength: 2.0, playLength: 4.0, frameCount: 44100, loopEnabled: true, loopCount: 2)
        XCTAssertEqual(events.count, 8)

        XCTAssertEqual(events.map { $0.noteNumber! }, [60, 60, 60, 60, 60, 60, 60, 60])
        XCTAssertEqual(events.map { $0.status!.type }, [.noteOn, .noteOff, .noteOn, .noteOff, .noteOn, .noteOff, .noteOn, .noteOff])
        XCTAssertEqual(events.map { $0.timeStamp }, [0, 22050, 22050, 33075, 0, 22050, 22050, 33075])
    }

    func testStameNoteRepeatingInChords() {

        var seq = NoteEventSequence()

        seq.add(noteNumber: 60, position: 0.0, duration: 1.0)
        seq.add(noteNumber: 62, position: 0.0, duration: 1.0)
        seq.add(noteNumber: 64, position: 0.0, duration: 1.0)

        seq.add(noteNumber: 61, position: 1.0, duration: 0.5)
        seq.add(noteNumber: 64, position: 1.0, duration: 0.5)
        seq.add(noteNumber: 62, position: 1.0, duration: 0.5)

        let events = observerTest(sequence: seq, sequenceLength: 2.0, playLength: 4.0, frameCount: 44100, loopEnabled: true, loopCount: 2)
        XCTAssertEqual(events.count, 24)

        XCTAssertEqual(events.map { $0.noteNumber! }, [60, 62, 64, 60, 62, 64, 61, 64, 62, 61, 64, 62,
                                                       60, 62, 64, 60, 62, 64, 61, 64, 62, 61, 64, 62])
        XCTAssertEqual(events.map { $0.status!.type }, [.noteOn, .noteOn, .noteOn, .noteOff, .noteOff,.noteOff,
                                                        .noteOn, .noteOn, .noteOn, .noteOff, .noteOff,.noteOff,
                                                        .noteOn, .noteOn, .noteOn, .noteOff, .noteOff,.noteOff,
                                                        .noteOn, .noteOn, .noteOn, .noteOff, .noteOff,.noteOff])
        XCTAssertEqual(events.map { $0.timeStamp! }, [0, 0, 0, 22050, 22050, 22050, 22050, 22050, 22050, 33075, 33075, 33075,
                                                      0, 0, 0, 22050, 22050, 22050, 22050, 22050, 22050, 33075, 33075, 33075])
    }

    func testSameNoteRepeatingInChordsAcrossLoop() {

        var seq = NoteEventSequence()

        seq.add(noteNumber: 60, position: 0.0, duration: 1.0)
        seq.add(noteNumber: 62, position: 0.0, duration: 1.0)
        seq.add(noteNumber: 64, position: 0.0, duration: 1.0)
        seq.add(noteNumber: 50, position: 1.0, duration: 1.0)
        seq.add(noteNumber: 52, position: 1.0, duration: 1.0)
        seq.add(noteNumber: 54, position: 1.0, duration: 1.0)

        let events = observerTest(sequence: seq, sequenceLength: 2.0, playLength: 4.0, frameCount: 512, loopEnabled: true, loopCount: 2)
        XCTAssertEqual(events.count, 24)

        XCTAssertEqual(events.map { $0.noteNumber! }, [60, 62, 64, 60, 62, 64,
                                                       60, 62, 64, 60, 62, 64,
                                                       60, 62, 64, 60, 62, 64,
                                                       60, 62, 64, 60, 62, 64])
        XCTAssertEqual(events.compactMap { $0.status!.type }, [.noteOn, .noteOn, .noteOn, .noteOff, .noteOff,.noteOff,
                                                               .noteOn, .noteOn, .noteOn, .noteOff, .noteOff,.noteOff,
                                                               .noteOn, .noteOn, .noteOn, .noteOff, .noteOff,.noteOff,
                                                               .noteOn, .noteOn, .noteOn, .noteOff, .noteOff,.noteOff])
        XCTAssertEqual(events.map { $0.timeStamp! }, [0, 0, 0, 34, 34, 34,
                                                  34, 34, 34, 68, 68, 68,
                                                  136, 136, 136, 170, 170, 170,
                                                  170, 170, 170, 204, 204, 204])
    }

    func testShortNotesAcrossLoop() {

        var seq = NoteEventSequence()

        seq.add(noteNumber: 60, position: 0.0, duration: 2.0)
        seq.add(noteNumber: 62, position: 0.0, duration: 2.0)
        seq.add(noteNumber: 65, position: 0.0, duration: 2.0)
        seq.add(noteNumber: 60, position: 3.98, duration: 0.5)
        seq.add(noteNumber: 64, position: 3.98, duration: 0.5)
        seq.add(noteNumber: 67, position: 3.98, duration: 0.5)

        let events = observerTest(sequence: seq, sequenceLength: 4.0, playLength: 8.0, frameCount: 44100, loopEnabled: true, loopCount: 2)

        XCTAssertEqual(events.count, 30)

        var correctNotes = [60, 62, 65, 60, 62, 65,
                            60, 64, 67, 60, 62, 65,
                            60, 62, 65, 60, 64, 67,
                            60, 62, 65, 60, 62, 65,
                            67, 64, 60]
        // append final note off msgs
        correctNotes.append(contentsOf: [67, 64, 60])

        let resultNotes = events.map { Int($0.noteNumber!) }

//        print("\nnotes result : \(resultNotes)\n")
//        print("\nnotes correct: \(correctNotes)\n")

        XCTAssertEqual(resultNotes, correctNotes)

        let correctMIDIMessageSequence:[MIDIStatusType] =
            [.noteOn,  .noteOn,  .noteOn,  .noteOff, .noteOff, .noteOff,
             .noteOn,  .noteOn,  .noteOn,  .noteOn,  .noteOn,  .noteOn,
             .noteOff, .noteOff, .noteOff, .noteOn,  .noteOn,  .noteOn,
             .noteOn,  .noteOn,  .noteOn,  .noteOff, .noteOff, .noteOff,
             .noteOn,  .noteOn,  .noteOn,  .noteOff, .noteOff, .noteOff]

        let resultMIDIMessageSequence = events.compactMap { $0.status!.type }

//        print("\nMIDI msg result : \(resultMIDIMessageSequence.map { $0.rawValue == 8 ? "On" : "Off" })\n")
//        print("\nMIDI msg correct: \(correctMIDIMessageSequence.map { $0.rawValue == 8 ? "On" : "Off" })\n")

        XCTAssertEqual(resultMIDIMessageSequence, correctMIDIMessageSequence)
//
//        let correctTimeStamps = [0, 0, 0, 0, 0, 0,
//                           43658, 43658, 43658, 0, 0, 0,
//                           0, 0, 0, 43658, 43658, 43658,
//                           0, 0, 0, 0, 0, 0,
//                           43658, 43658, 43658]
//
//        diff = correctMIDIMessageSequence.diff(from: events.map { $0.timeStamp })
//
//        print("timeStamp diff: \(diff)\n")
//
//        XCTAssertEqual(events.map { $0.timeStamp }, correctTimeStamps)
    }
}
