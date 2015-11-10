//
//  AKVariableDelay.swift
//  AudioKit
//
//  Autogenerated by scripts by Aurelius Prochazka. Do not edit directly.
//  Copyright (c) 2015 Aurelius Prochazka. All rights reserved.
//

import AVFoundation

/** A delay line with cubic interpolation. */
public class AKVariableDelay: AKOperation {

    // MARK: - Properties

    private var internalAU: AKVariableDelayAudioUnit?
    private var token: AUParameterObserverToken?

    private var delayTimeParameter:        AUParameter?

    /** Delay time (in seconds) that can be changed during performance. This value must not exceed the maximum delay time. */
    public var delayTime: Float = 1.0 {
        didSet {
            delayTimeParameter?.setValue(delayTime, originator: token!)
        }
    }

    // MARK: - Initializers

    /** Initialize this delay operation */
    public init(
        _ input: AKOperation,
        delayTime: Float = 1.0)
    {
        self.delayTime = delayTime
        super.init()

        var description = AudioComponentDescription()
        description.componentType         = kAudioUnitType_Effect
        description.componentSubType      = 0x76646c61 /*'vdla'*/
        description.componentManufacturer = 0x41754b74 /*'AuKt'*/
        description.componentFlags        = 0
        description.componentFlagsMask    = 0

        AUAudioUnit.registerSubclass(
            AKVariableDelayAudioUnit.self,
            asComponentDescription: description,
            name: "Local AKVariableDelay",
            version: UInt32.max)

        AVAudioUnit.instantiateWithComponentDescription(description, options: []) {
            avAudioUnit, error in

            guard let avAudioUnitEffect = avAudioUnit else { return }

            self.output = avAudioUnitEffect
            self.internalAU = avAudioUnitEffect.AUAudioUnit as? AKVariableDelayAudioUnit
            AKManager.sharedInstance.engine.attachNode(self.output!)
            AKManager.sharedInstance.engine.connect(input.output!, to: self.output!, format: nil)
        }

        guard let tree = internalAU?.parameterTree else { return }

        delayTimeParameter        = tree.valueForKey("delayTime")        as? AUParameter

        token = tree.tokenByAddingParameterObserver {
            address, value in

            dispatch_async(dispatch_get_main_queue()) {
                if address == self.delayTimeParameter!.address {
                    self.delayTime = value
                }
            }
        }

    }
}
