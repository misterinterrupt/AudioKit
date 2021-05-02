// Copyright AudioKit. All Rights Reserved. Revision History at http://github.com/AudioKit/AudioKit/

#import "TargetConditionals.h"

#if !TARGET_OS_TV

#include "SequencerEngine.h"
#include <vector>
#include <bitset>
#include <stdio.h>
#include <atomic>
#include "../../Internals/Utilities/readerwriterqueue.h"
#include <iostream>
#define NOTEON 0x90
#define NOTEOFF 0x80

using moodycamel::ReaderWriterQueue;

/// NOTE: To support more than a single channel, RunningStatus can be made larger
/// e.g. typedef std::bitset<128 * 16> RunningStatus; would track 16 channels of notes
typedef std::bitset<128> RunningStatus;

struct SequencerEvent {
    bool notesOff = false;
    bool panic = false;
    bool play = false;
    bool playFromStart = false;
    bool rewind = false;
    double seekPosition = NAN;
    bool stop = false;
};

struct SequencerEngine {
private:
    // tracks note on off msgs for note cleanup after transport events
    RunningStatus runningStatus;
    // counts samples by buffer while playing, resets to 0 when stopped
    long playbackSampleCount = 0;
    // counts samples since instantiation, currently unused
    UInt64 framesCounted = 0;
    // Current position as reported to the UI.
    double uiPosition = 0.0;
    // Current loop as reported to the UI.
    int currentLoop = 1;
    // flag and token used by process function when sequence data has changed
    std::atomic<bool> sequenceChanged = { false };
    std::atomic<int> sequenceToken = { 0 };

    // useful constants calculated when sequence settings change
    double beatsPerSecond           = 0.0;
    double secondsPerBeat           = 0.0;
    long   samplesPerBeat           = 0;
    long   sequenceLengthInSamples  = 0;
    // useful constants calculated at start of process() call
    long   lastFrameCount           = 0;
    double secondsPerBuffer         = 0.0;
    double beatsPerBuffer           = 0.0;

    void sendMidiData(UInt8 status, UInt8 data1, UInt8 data2, int offset, double time) {
        if(midiBlock) {
            UInt8 midiBytes[3] = {status, data1, data2};
            midiBlock(AUEventSampleTimeImmediate + offset, 0, 3, midiBytes);
            updateRunningStatus(status, data1, data2);
        }
    }

    /// Update note playing status
    void updateRunningStatus(UInt8 status, UInt8 data1, UInt8 data2) {
        if(status == NOTEOFF) {
            runningStatus.set(data1, 0);
//            coutPosition();
            std::cout << "note: " << (int)(data1)  << " status is Off " << std::endl;
            std::cout << runningStatus.to_string() << std::endl << std::endl;
        }
        if(status == NOTEON) {
//            coutPosition();
            runningStatus.set(data1, 1);
            std::cout << "note: " << (int)(data1)  << " status is On " << std::endl;
            std::cout << runningStatus.to_string() << std::endl << std::endl;
        }
    }

    /// Stop all notes whose running status is currently on
    /// If panic is set to true, a note-off message will be sent for all notes
    void stopAllPlayingNotes(bool panic = false) {
        coutPosition();
        std::cout << "stopAllPlayingNotes() -engine:" << this << std::endl;
        if(runningStatus.any() || (panic == true)) {
            for(int i = (int)runningStatus.size() - 1; i >= 0; i--) {
                if(runningStatus[i] == 1 || (panic == true)) {
                    sendMidiData(NOTEOFF, (UInt8)i, 0, 1, 0);
                }
            }
            std::cout << "stopAllPlayingNotes(): " << std::endl << runningStatus.to_string() << std::endl;
        }
    }

    void play() {
        std::cout << "play -engine: " << this << std::endl;
        isStarted = true;
    }

    void stop() {
        std::cout << "stop -engine: " << this << std::endl;
        isStarted = false;
    }

    void seekTo(double position) {
        std::cout << "seekTo -engine: " << this << std::endl;
        playbackSampleCount = beatToSamples(position);
    }

    void incrementLoop() {
        setCurrentLoop(currentLoop + 1);
    }

    void setCurrentLoop(int loop) {
        currentLoop = loop;
        std::cout << std::endl << "setting current loop: " << currentLoop << std::endl << std::endl;
    }

    void processEvents(int resetToken) {
        bool eventsProcessed = false;
        if(sequenceToken == resetToken && sequenceChanged == true) {
            std::cout << "sequenceChanged " << std::endl;
            sequenceChanged = false;
            stopAllPlayingNotes();
            updateConstants();
        }
        SequencerEvent event;
        if(eventQueue.size_approx() != 0) {
            eventsProcessed = true;
            std::cout << " procesing " << eventQueue.size_approx() << " events " << this << std::endl;
        }
        while(eventQueue.try_dequeue(event)) {
            if(event.notesOff) {
                std::cout << " - notesOff " << std::endl;
                stopAllPlayingNotes();
                continue;
            }
            if(event.play) {
                std::cout << " - play " << std::endl;
                play();
                continue;
            }
            if(event.playFromStart) {
                std::cout << " - playFromStart " << std::endl;
                stop();
                stopAllPlayingNotes();
                seekTo(0);
                setCurrentLoop(1);
                play();
                continue;
            }
            if(event.rewind) {
                std::cout << " - rewind " << std::endl;
                stop();
                stopAllPlayingNotes();
                seekTo(0);
                setCurrentLoop(1);
                continue;
            }
            if(!isnan(event.seekPosition)) {
                std::cout << " seekPosition: " << event.seekPosition << std::endl;
                stopAllPlayingNotes();
                seekTo(event.seekPosition);
                // TODO:: reset the loop correctly here
                // setCurrentLoop(1);
                continue;
            }
            if(event.stop) {
                std::cout << "stop" << std::endl;
                stopAllPlayingNotes();
                stop();
                continue;
            }
        }
        if(eventsProcessed) {
            std::cout << std::endl;
        }
    }

    void updateConstants() {
        // pre-calculate useful constants
        beatsPerSecond          = settings.tempo / 60.0;
        secondsPerBeat          = 60.0 / settings.tempo;
        samplesPerBeat          = secondsPerBeat * sampleRate;
        sequenceLengthInSamples = beatToSamples(settings.length);
        if(lastFrameCount > 0) {
            secondsPerBuffer    = (double)(lastFrameCount) / sampleRate;
            beatsPerBuffer      = samplesToBeats(lastFrameCount);
        }
    }
// beat time of note
    long beatToSamples(double beat) const {
        double samples = samplesPerBeat * beat;
//        std::cout << "beat: " << beat << " to samples: " << samples << " at " << samplesPerBeat << " samples/beat" << std::endl;
        return (long)(samples);
    }

    double samplesToBeats(long samples) const {
        double lengthInSeconds = (double)(samples) / sampleRate;
        double beat = lengthInSeconds * beatsPerSecond;
//        std::cout << "samples: " << samples << " to beat: " << beat << std::endl;
        return beat;
    }

    // return a multiple of the buffer size in beat time
    // modulo loop length if loopEnabled
    double quantizedBeatPosition() {
        long position = settings.loopEnabled ? currentPositionInSamples() : playbackSampleCount;
        double beat = (position / lastFrameCount) * beatsPerBuffer;
//        std::cout << "beat: " << beat << " total buffers: " << currentPositionInSamples() / lastFrameCount << std::endl;
        return beat;
    }

    long currentPositionInSamples() const {
        if (playbackSampleCount == 0 || sequenceLengthInSamples == 0) {
            return 0;
        } else if (playbackSampleCount < 0) {
            return playbackSampleCount;
        } else {
            if(settings.loopEnabled) {
                return playbackSampleCount % sequenceLengthInSamples;
            } else {
                return  playbackSampleCount;
            }
        }
    }
    
    // prefer quantizedBeatPosition() over this
//    double currentPositionInBeats() const {
//        auto currSamples = currentPositionInSamples();
//        auto currBeat = samplesToBeats(currSamples);
//        std::cout << "beat: " << currBeat << " to samples: " << currSamples << std::endl;
//        return currBeat;
//    }

    void coutPosition() {
        std::cout << "sample position " << currentPositionInSamples() << std::endl;
        std::cout << "beat position   " << samplesToBeats(currentPositionInSamples()) << std::endl;
    }

public:

    ReaderWriterQueue<SequencerEvent> eventQueue;

    AUScheduleMIDIEventBlock midiBlock = nullptr;

    std::atomic<bool> isStarted{false};

    SequenceSettings settings = {4.0, 120.0, true, 0};

    double sampleRate = 44100.0;

    SequencerEngine() {
        updateConstants();
        runningStatus.reset();
    }

    ~SequencerEngine() {
        stop();
        stopAllPlayingNotes();
        std::cout << "destroyed - frame count: " << framesCounted << std::endl;
    }

    int sequenceUpdated() {
        sequenceChanged = true;
        return ++sequenceToken;
    }

    double quantizedPosition() {
        return uiPosition;
    }

    int loopCount() {
        return currentLoop;
    }

    void process(const std::vector<SequenceEvent>& events, AUAudioFrameCount frameCount, int resetToken) {

        lastFrameCount = frameCount;

        processEvents(resetToken);

        if (isStarted) {
            // sample and beat times are 0-indexed - loops are 1-indexed
            long currentStartSample =               playbackSampleCount;
            long currentEndSample =                 currentStartSample + frameCount;

            // check if buffer includes the loop boundary
            bool bufferIncludesNextLoop =           settings.loopEnabled && (currentEndSample > sequenceLengthInSamples);
            bool bufferPastEnd =                    !settings.loopEnabled && (currentEndSample > sequenceLengthInSamples);
            bool bufferGTELoop =                    settings.loopEnabled && (frameCount >= sequenceLengthInSamples);

            // calculate window in current buffer that includes the next loop
            long nextLoopStartSample =              currentStartSample + fmax(0, sequenceLengthInSamples - currentStartSample);
            long nextLoopEndSample =                currentEndSample;

            if(bufferIncludesNextLoop || bufferPastEnd) {
                // set end of current buffer to end of current loop
                currentEndSample =                  nextLoopStartSample;
            }

            // handle finite looping state
            bool isFiniteLoop = settings.loopEnabled && (settings.numberOfLoops > 0);
                long lengthOfFiniteLoops =          isFiniteLoop ? (sequenceLengthInSamples * settings.numberOfLoops) : 0;
                bool inFinalLoop =                  isFiniteLoop && (currentLoop >= settings.numberOfLoops);
                bool isFinalBufferOfFiniteLoops =   isFiniteLoop && bufferIncludesNextLoop && inFinalLoop;

            // schedule events for the current loop in this buffer
            for (int i = 0; i < events.size(); i++) {

                long triggerTime = beatToSamples(events[i].beat);

                bool eventInCurrLoop = currentStartSample <= triggerTime && triggerTime < currentEndSample;
                bool eventAtLoopBoundary = (bufferIncludesNextLoop || bufferPastEnd) && (triggerTime == currentEndSample);
                bool noteOnLoopBoundary = eventAtLoopBoundary && events[i].status == NOTEON;

                // schedule note events
                if (eventInCurrLoop || eventAtLoopBoundary) {

                    long offset = (triggerTime - currentStartSample);

                    std::cout << "current loop <> " << (eventAtLoopBoundary ? (noteOnLoopBoundary ? " on at loop boundary" : " off at loop boundary") : "") << std::endl;
                    std::cout << "event offset:         " << offset << std::endl;
                    std::cout << "playbackSampleCount:  " << playbackSampleCount << std::endl;
                    std::cout << "currentStartSample:   " << currentStartSample << " triggerTime: " << triggerTime << std::endl;
                    std::cout << "song position:        " << samplesToBeats(playbackSampleCount) << " event pos: " << events[i].beat << std::endl;
                    std::cout << "currentEndSample:     " << currentEndSample << " frameCount: " << frameCount << std::endl;
                    std::cout << "loop                  # " << currentLoop << std::endl;
                    std::cout << "buffer                # " << (playbackSampleCount / frameCount) + 1  << std::endl;
                    std::cout << "buffer GTE loop       " << (bufferGTELoop ? "true" : "false") << std::endl;
                    std::cout << "buffer start          " << samplesToBeats(currentStartSample) << " " << currentStartSample << std::endl;
                    std::cout << "buffer end:           " << samplesToBeats(currentEndSample) << " " << currentEndSample << std::endl;
                    std::cout << "next loop start:      " << samplesToBeats(nextLoopStartSample) << " " << nextLoopStartSample << std::endl;
                    std::cout << "next loop end:        " << samplesToBeats(nextLoopEndSample) << " " << nextLoopEndSample << std::endl;
                    std::cout << "current loop samples: " << currentEndSample - currentStartSample << std::endl;
                    std::cout << "next loop samples:    " << nextLoopEndSample - nextLoopStartSample << std::endl;
                    std::cout << "sequence len samples: " << sequenceLengthInSamples << std::endl << std::endl;

                    // process note off msgs loop's boundary
                    if(noteOnLoopBoundary) {
                    std::cout << "xxxxxxxxxxxxxxxxxxxxx skipping event:  note " << (int)(events[i].data1) << (events[i].status == NOTEON ? " On" : " Off") << std::endl << std::endl;
                        continue;
                    }
                    sendMidiData(events[i].status, events[i].data1, events[i].data2, (int)(offset), events[i].beat);
                }
            }

            // schedule events for the next loop in this buffer
            if(bufferIncludesNextLoop && !isFinalBufferOfFiniteLoops && !bufferGTELoop) {

                for (int i = 0; i < events.size(); i++) {

                    long nextLoopWindowLength = nextLoopEndSample - nextLoopStartSample;
                    // save the offset in this buffer
                    long loopOffset = nextLoopStartSample - currentStartSample;

                    long triggerTime = beatToSamples(events[i].beat);

                    // next loop window starts at the begining of the loop to end of buffer
                    bool eventInNextLoop = 0 <= triggerTime && triggerTime < nextLoopWindowLength;

                    if(eventInNextLoop) {

                        long offset = loopOffset + triggerTime;

                        std::cout << std::endl << "next loop <> " << std::endl;
                        std::cout << "event offset:         " << offset << std::endl;
                        std::cout << "playbackSampleCount:  " << playbackSampleCount << std::endl;
                        std::cout << "currentStartSample:   " << currentStartSample << " triggerTime: " << triggerTime << std::endl;
                        std::cout << "song position:        " << samplesToBeats(playbackSampleCount) << " event pos: " << events[i].beat << std::endl;
                        std::cout << "currentEndSample:     " << currentEndSample << " frameCount: " << frameCount << std::endl;
                        std::cout << "loop                  # " << currentLoop << std::endl;
                        std::cout << "buffer                # " << (playbackSampleCount / frameCount) + 1  << std::endl;
                        std::cout << "buffer GTE loop       " << (bufferGTELoop ? "true" : "false") << std::endl;
                        std::cout << "buffer start          " << samplesToBeats(currentStartSample) << " " << currentStartSample << std::endl;
                        std::cout << "buffer end:           " << samplesToBeats(currentEndSample) << " " << currentEndSample << std::endl;
                        std::cout << "next loop start:      " << samplesToBeats(nextLoopStartSample) << " " << nextLoopStartSample << std::endl;
                        std::cout << "next loop end:        " << samplesToBeats(nextLoopEndSample) << " " << nextLoopEndSample << std::endl;
                        std::cout << "current loop samples: " << currentEndSample - currentStartSample << std::endl;
                        std::cout << "next loop samples:    " << nextLoopEndSample - nextLoopStartSample << std::endl;
                        std::cout << "sequence len samples: " << sequenceLengthInSamples << std::endl << std::endl;

                        sendMidiData(events[i].status, events[i].data1, events[i].data2, (int)(offset), events[i].beat);
                    }
                }
            }

            // count the samples processed
            playbackSampleCount += frameCount;

            if(settings.loopEnabled) {
                // stop when finite looping is done
                if(isFinalBufferOfFiniteLoops) {
                    // TODO:: add and expose config for this behavior..
                    // TODO: reset loopCount where appropriate
                    std::cout << "finite loop is finished - loop: " << currentLoop << " of " << settings.numberOfLoops << std::endl;
                    stop();
                    stopAllPlayingNotes();
                } else {
                    // increment loop only if isFinalBufferOfFiniteLoops == false
                    if(playbackSampleCount >= sequenceLengthInSamples) {
                        incrementLoop();
                    }
                }
                // clamp the samples counted to the sequence length
                playbackSampleCount = playbackSampleCount % sequenceLengthInSamples;
            } else if(playbackSampleCount >= sequenceLengthInSamples) {
                std::cout << "sequence is finished - playback sample count: " << playbackSampleCount << " of " << sequenceLengthInSamples << std::endl;
                stop();
                stopAllPlayingNotes();
            }

            uiPosition = quantizedBeatPosition();
        }

        framesCounted += frameCount;
    }
};

/// Creates the audio-thread-only state for the sequencer.
SequencerEngineRef akSequencerEngineCreate(void) {
    return new SequencerEngine;
}

void akSequencerEngineDestroy(SequencerEngineRef engine) {
    delete engine;
}

/// Updates the sequence and returns a new render observer.
AURenderObserver SequencerEngineUpdateSequence(SequencerEngineRef engine,
                                                 const SequenceEvent* eventsPtr,
                                                 size_t eventCount,
                                                 SequenceSettings settings,
                                                 double sampleRate,
                                                 AUScheduleMIDIEventBlock block) {

    const std::vector<SequenceEvent> events{eventsPtr, eventsPtr+eventCount};

    int token = engine->sequenceUpdated();

    return ^void(AudioUnitRenderActionFlags actionFlags,
                 const AudioTimeStamp *timestamp,
                 AUAudioFrameCount frameCount,
                 NSInteger outputBusNumber)
    {
        if (actionFlags != kAudioUnitRenderAction_PreRender) return;

        engine->sampleRate = sampleRate;
        engine->midiBlock = block;
        engine->settings = settings;
        engine->process(events, frameCount, token);
    };
}

double akSequencerEngineGetPosition(SequencerEngineRef engine) {
    return engine->quantizedPosition();
}

int akSequencerEngineGetCurrentLoop(SequencerEngineRef engine) {
    return engine->loopCount();
}

void akSequencerEngineSeekTo(SequencerEngineRef engine, double position) {
    std::cout << "enqueing seekPosition -engine: " << engine << std::endl;
    SequencerEvent event;
    event.seekPosition = position;
    engine->eventQueue.enqueue(event);
}

void akSequencerEnginePlayFromStart(SequencerEngineRef engine) {
    std::cout << "enqueing playFromStart -engine: " << engine << std::endl;
    SequencerEvent event;
    event.playFromStart = true;
    engine->eventQueue.enqueue(event);
}

void akSequencerEnginePlay(SequencerEngineRef engine) {
    std::cout << "enqueing play -engine: " << engine << std::endl;
    SequencerEvent event;
    event.play = true;
    engine->eventQueue.enqueue(event);
}

void akSequencerEngineStop(SequencerEngineRef engine) {
    std::cout << "enqueing stop -engine: " << engine << std::endl;
    SequencerEvent event;
    event.stop = true;
    engine->eventQueue.enqueue(event);
}

bool akSequencerEngineIsPlaying(SequencerEngineRef engine) {
    return engine->isStarted;
}

void akSequencerEngineStopPlayingNotes(SequencerEngineRef engine) {
    std::cout << "enqueing notesOff -engine: " << engine << std::endl;
    SequencerEvent event;
    event.notesOff = true;
    engine->eventQueue.enqueue(event);
}

void akSequencerEnginePanic(SequencerEngineRef engine) {
    std::cout << "enqueing panic -engine: " << engine << std::endl;
    SequencerEvent event;
    event.panic = true;
    engine->eventQueue.enqueue(event);
}

#endif
