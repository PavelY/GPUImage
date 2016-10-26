//
//  GPUImageAudioPlayer.h
//  GPUImage
//
//  Created by Uzi Refaeli on 03/09/2013.
//  Copyright (c) 2013 Brad Larson. All rights reserved.
//

#import <Foundation/Foundation.h>
#include <AudioUnit/AudioUnit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import "TPCircularBuffer.h"


@interface GPUImageAudioPlayer : NSObject

- (void)initAudio;
- (void)startPlaying;
- (void)stopPlaying;
- (void)copyBuffer:(CMSampleBufferRef)buf;

- (TPCircularBuffer *)getBuffer;

@property(nonatomic, assign) BOOL hasBuffer;
@property(nonatomic, assign) SInt32 bufferSize;
@property(nonatomic, readonly) BOOL readyForMoreBytes;
@property (nonatomic, assign) NSUInteger volume;

@end
