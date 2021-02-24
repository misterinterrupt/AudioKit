// Copyright AudioKit. All Rights Reserved. Revision History at http://github.com/AudioKit/AudioKit/

#import "TargetConditionals.h"

#if !TARGET_OS_TV

#include "SequencerEngine.h"
#include <vector>
#include <mach/mach_time.h>
#include <bitset>
#include <stdio.h>
#include <atomic>
#include "../../Internals/Utilities/readerwriterqueue.h"

#define NOTEON 0x90
#define NOTEOFF 0x80

using moodycamel::ReaderWriterQueue;

/// NOTE: To support more than a single channel, RunningStatus can be made larger
/// e.g. typedef std::bitset<128 * 16> RunningStatus; would track 16 channels of notes
typedef std::bitset<128> RunningStatus;

struct SequencerEvent {
    bool notesOff = false;
    double seekPosition = NAN;
};

struct BeatTimeNoteValues {
    double whole;
    double half;
    double quarter;
    double eighth;
    double sixteenth;
    double thirtysecond;
    double sixtyfourth;
    double onehundredtwentyeighth;
    void print() {
        printf("whole:%f, half:%f, quarter:%f, 8th:%f, 16th:%f, 32nd:%f, 64th:%f, 128th:%f\n",
               this->whole, this->half, this->quarter, this->eighth, this->sixteenth,
               this->thirtysecond, this->sixtyfourth, this->onehundredtwentyeighth);
    }
};

struct SequencerEngine {
    RunningStatus runningStatus;
    UInt64 engineStartTimeHost = 0;
    double engineStartTimeSample = NAN;
    uint64_t nsStartTime = 0;
    UInt64 engineLastTimeHost = 0;
    double engineLastTimeSample = NAN;
    uint64_t engineLastNSTime = 0;
    long positionInSamples = 0;
    uint64_t positionInNanoSeconds = 0;
    UInt64 framesCounted = 0;
    SequenceSettings settings = {0, 4.0, 120.0, true, 0};
    BeatTimeNoteValues beatTimeNoteValues = BeatTimeNoteValues();
    double sampleRate = 44100.0;
    std::atomic<bool> isStarted{false};
    AUScheduleMIDIEventBlock midiBlock = nullptr;

    ReaderWriterQueue<SequencerEvent> eventQueue;

    // Current position as reported to the UI.
    std::atomic<double> uiPosition{0};

    SequencerEngine() {}

    BeatTimeNoteValues noteValuesInBeatTime() {
        double bps = beatsPerSecond();
        return BeatTimeNoteValues { (bps*4), bps*2, bps, bps*0.5, bps*0.25, bps*0.125, bps*0.0625, bps*0.03125 };
    }

    double nsToBeatTime(uint64_t nsValue) {
        double ns = 0.000000001;
        double sec = (double)nsValue * ns;
        double beat = sec / beatsPerSecond();
        return beatTimeModLoopLength(beat);
    }

    double samplesToBeatTime(double sampleValue) {
        double samplesPerSecond = sampleRate * beatsPerSecond();
        double beat = sampleValue / samplesPerSecond;
        return beatTimeModLoopLength(beat);
    }

    double beatsPerSecond() {
        return 60.0 / settings.tempo;
    }

    double beatTimeModLoopLength(double beat) {
        return fmod(beat, settings.length);
    }

    int beatToSamples(double beat) const {
        return (int)(beat / settings.tempo * 60 * sampleRate);
    }

    long lengthInSamples() const {
        return beatToSamples(settings.length);
    }

    long positionModulo() const {
        long length = lengthInSamples();
        if (positionInSamples == 0 || length == 0) {
            return 0;
        } else if (positionInSamples < 0) {
            return positionInSamples;
        } else {
            return positionInSamples % length;
        }
    }

    double currentPositionInBeats() const {
        return (double)positionModulo() / sampleRate * (settings.tempo / 60);
    }

    bool validTriggerTime(double beat) {
        return true;
    }

    void sendMidiData(UInt8 status, UInt8 data1, UInt8 data2, int offset, double time) {
        if(midiBlock) {
            UInt8 midiBytes[3] = {status, data1, data2};
            midiBlock(AUEventSampleTimeImmediate + offset, 0, 3, midiBytes);
        }
    }

    /// Update note playing status
    void updateRunningStatus(UInt8 status, UInt8 data1, UInt8 data2) {
        if(status == NOTEOFF) {
            runningStatus.set(data1, 0);
        }
        if(status == NOTEON) {
            runningStatus.set(data1, 1);
        }
    }

    /// Stop all notes whose running status is currently on
    /// If panic is set to true, a note-off message will be sent for all notes
    void stopAllPlayingNotes(bool panic = false) {
        if(runningStatus.any() || panic) {
            for(int i = (int)runningStatus.size(); i >= 0; i--) {
                if(runningStatus[i] == 1 || panic) {
                    sendMidiData(NOTEOFF, (UInt8)i, 0, 1, 0);
                }
            }
        }
    }

    void stop() {
        isStarted = false;
        stopAllPlayingNotes();
    }

    void seekTo(double position) {
        positionInSamples = beatToSamples(position);
    }

    void processEvents() {

        SequencerEvent event;
        while(eventQueue.try_dequeue(event)) {
            if(event.notesOff) {
                stopAllPlayingNotes();
            }

            if(!isnan(event.seekPosition)) {
//                seekTo(event.seekPosition);
            }
        }

    }

    void process(const std::vector<SequenceEvent>& events, AUAudioFrameCount frameCount, const AudioTimeStamp *timeStamp) {

        uint64_t nsNow = monotonicTimeNanos();

        processEvents();

        if (isStarted) {
            if(isnan(engineStartTimeSample)) {
                engineStartTimeSample = timeStamp->mSampleTime;
                engineStartTimeHost = timeStamp->mHostTime;
                nsStartTime = nsNow;
                printf("\nEngine Started - sample: %f, host: %llu, ns: %llu \n\n", engineStartTimeSample, engineStartTimeHost, nsStartTime);
            }

            /// Log timestamps
            printf("- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - engine ref: %p\n", this);
            printf("Start - sample: %12.12f, host: %12llu, ns: %12llu \n", engineStartTimeSample, engineStartTimeHost, nsStartTime);
            printf("Now   - sample: %12.12f, host: %12llu, ns: %12llu \n", timeStamp->mSampleTime, timeStamp->mHostTime, nsNow);
            printf("Var   - sample: %12.12ld, host: %12llu, ns: %12llu \nframeCount: %i \n",
                   positionInSamples,
                   timeStamp->mHostTime - engineLastTimeHost,
                   positionInNanoSeconds,
                   frameCount);

            printf("beats per second: %f\n", beatsPerSecond());

            double nsBeatTime = nsToBeatTime(positionInNanoSeconds);
            double sampleBeatTime = samplesToBeatTime((double)positionInSamples);

            printf("beat time derived from mach/ns: %f \n", nsBeatTime);
            printf("beat time derived from samples: %f \n", sampleBeatTime);

            double beatTimeVariance = nsBeatTime - sampleBeatTime;
            printf("drifted %f (beat time) \n", beatTimeVariance);
            beatTimeNoteValues.print();


            if (positionInSamples >= lengthInSamples()) {
                if (!settings.loopEnabled) { //stop if played enough
                    stop();
                    return;
                }
            }

            long currentStartSample = positionModulo();
            long currentEndSample = currentStartSample + frameCount;

            for (int i = 0; i < events.size(); i++) {
                // go through every event
                int triggerTime = beatToSamples(events[i].beat);

                if (currentEndSample > lengthInSamples() && settings.loopEnabled) {
                // this buffer extends beyond the length of the loop and looping is on
                int loopRestartInBuffer = (int)(lengthInSamples() - currentStartSample);
                int samplesOfBufferForNewLoop = frameCount - loopRestartInBuffer;
                    if (triggerTime < samplesOfBufferForNewLoop) {
                        // this event would trigger early enough in the next loop that it should happen in this buffer
                        // ie. this buffer contains events from the previous loop, and the next loop
                        int offset = (int)triggerTime + loopRestartInBuffer;
                        sendMidiData(events[i].status, events[i].data1, events[i].data2,
                                     offset, events[i].beat);
                    }
                } else if (currentStartSample <= triggerTime && triggerTime < currentEndSample) {
                    // this event is supposed to trigger between currentStartSample and currentEndSample
                    int offset = (int)(triggerTime - currentStartSample);
                    sendMidiData(events[i].status, events[i].data1, events[i].data2,
                                 offset, events[i].beat);
                }
            }
            positionInSamples += (timeStamp->mSampleTime - engineLastTimeSample);
            positionInNanoSeconds += (nsNow - engineLastNSTime);
//            uiPosition = samplesToBeatTime(sampleBeatTime);
            uiPosition = nsToBeatTime(nsNow);
        }
        
        framesCounted += frameCount; // currently unused
        engineLastTimeHost = timeStamp->mHostTime;
        engineLastTimeSample = timeStamp->mSampleTime;
        engineLastNSTime = nsNow;
    }

    uint64_t monotonicTimeNanos() {
        uint64_t now = mach_absolute_time();
        static struct Data {
            Data(uint64_t bias_) : bias(bias_) {
                kern_return_t mtiStatus = mach_timebase_info(&tb);
                assert(mtiStatus == KERN_SUCCESS);
            }
            uint64_t scale(uint64_t i) {
                return scaleHighPrecision(i - bias, tb.numer, tb.denom);
            }
            static uint64_t scaleHighPrecision(uint64_t i, uint32_t numer, uint32_t denom) {
                uint64_t high = (i >> 32) * numer;
                uint64_t low = (i & 0xffffffffull) * numer / denom;
                uint64_t highRem = ((high % denom) << 32) / denom;
                high /= denom;
                return (high << 32) + highRem + low;
            }
            mach_timebase_info_data_t tb;
            uint64_t bias;
        } data(now);
        return data.scale(now);
    }

    bool losslessRoundTrip(int64_t valueToTest)
    {
        double newRepresentation;
        *((volatile double *)&newRepresentation) = static_cast<double>(valueToTest);
        int64_t roundTripValue = static_cast<int64_t>(newRepresentation);
        return roundTripValue == valueToTest;
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
//    printf("- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - engine ref: %p\n", engine);
    const std::vector<SequenceEvent> events{eventsPtr, eventsPtr+eventCount};
    return ^void(AudioUnitRenderActionFlags actionFlags,
                 const AudioTimeStamp *timestamp,
                 AUAudioFrameCount frameCount,
                 NSInteger outputBusNumber)
    {
        if (actionFlags != kAudioUnitRenderAction_PreRender) return;

        engine->sampleRate = sampleRate;
        engine->midiBlock = block;
        engine->settings = settings;
        engine->beatTimeNoteValues = engine->noteValuesInBeatTime();
        engine->process(events, frameCount, timestamp);
    };
}

double akSequencerEngineGetPosition(SequencerEngineRef engine) {
    return engine->uiPosition;
}

void akSequencerEngineSeekTo(SequencerEngineRef engine, double position) {
    SequencerEvent event;
    event.seekPosition = position;
    engine->eventQueue.enqueue(event);
}

void akSequencerEngineSetPlaying(SequencerEngineRef engine, bool playing) {
    // force position reset to zero when set to play
    if(!playing) {
        engine->engineStartTimeSample = NAN;
        engine->engineStartTimeHost = 0;
        engine->positionInSamples = 0;
        engine->positionInNanoSeconds = 0;
    }
    engine->isStarted = playing;
}

bool akSequencerEngineIsPlaying(SequencerEngineRef engine) {
    return engine->isStarted;
}

void akSequencerEngineStopPlayingNotes(SequencerEngineRef engine) {
    SequencerEvent event;
    event.notesOff = true;
    engine->eventQueue.enqueue(event);
}

#endif
