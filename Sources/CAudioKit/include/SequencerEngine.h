// Copyright AudioKit. All Rights Reserved. Revision History at http://github.com/AudioKit/AudioKit/

#pragma once

#import <AVFoundation/AVFoundation.h>
#import "Interop.h"

/// Sequence Event
typedef struct {
    uint8_t status;
    uint8_t data1;
    uint8_t data2;
    double beat;
} SequenceEvent;

/// Sequence Note
typedef struct {
    SequenceEvent noteOn;
    SequenceEvent noteOff;
} SequenceNote;

/// Sequence Settings
typedef struct {
    double length;
    double tempo;
    bool loopEnabled;
    int32_t numberOfLoops;
} SequenceSettings;

typedef struct SequencerEngine* SequencerEngineRef;

/// Creates the audio-thread-only state for the sequencer.
AK_API SequencerEngineRef akSequencerEngineCreate(void);

/// Deallocate the sequencer.
AK_API void akSequencerEngineDestroy(SequencerEngineRef engine);

/// Updates the sequence and returns a new render observer.
AK_API AURenderObserver SequencerEngineUpdateSequence(SequencerEngineRef engine,
                                                        const SequenceEvent* events,
                                                        size_t eventCount,
                                                        SequenceSettings settings,
                                                        double sampleRate,
                                                        AUScheduleMIDIEventBlock block);

/// Returns the sequencer playhead position in beats.
AK_API double akSequencerEngineGetPosition(SequencerEngineRef engine);

/// Returns the current loop.
AK_API int akSequencerEngineGetCurrentLoop(SequencerEngineRef engine);

/// Move the playhead to a location in beats.
AK_API void akSequencerEngineSeekTo(SequencerEngineRef engine, double position);

AK_API void akSequencerEnginePlayFromStart(SequencerEngineRef engine);

AK_API void akSequencerEnginePlay(SequencerEngineRef engine);

AK_API void akSequencerEnginePanic(SequencerEngineRef engine);

AK_API void akSequencerEngineStop(SequencerEngineRef engine);

AK_API bool akSequencerEngineIsPlaying(SequencerEngineRef engine);

/// Stop all notes currently playing.
AK_API void akSequencerEngineStopPlayingNotes(SequencerEngineRef engine);
