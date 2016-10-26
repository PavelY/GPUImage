//
//  GPUImageAudioPlayer.m
//  GPUImage
//
//  Created by Uzi Refaeli on 03/09/2013.
//  Copyright (c) 2013 Brad Larson. All rights reserved.
//
// TODO: Find replacement for AudioSampleType that works.

#import "GPUImageAudioPlayer.h"
#define kOutputBus 0
#define kInputBus 1
#define SAMPLE_RATE 44100.0


#define kUnitSize sizeof(AudioSampleType)
#define kBufferUnit 655360
#define kTotalBufferSize kBufferUnit * kUnitSize
#define kRescueBufferSize kBufferUnit / 2

static void CheckStatus(OSStatus status)
{
    if(status != noErr)
    {
        char fourCC[16];
        *(UInt32 *)fourCC = CFSwapInt32HostToBig(status);
        fourCC[4] = '\0';
        
        if(isprint(fourCC[0]) && isprint(fourCC[1]) && isprint(fourCC[2]) && isprint(fourCC[3]))
            NSLog(@"Error: %s", fourCC);
        else
            NSLog(@"Error: %ld", status);
    }
}

@interface GPUImageAudioPlayer(){
    AUGraph processingGraph;
    AudioUnit mixerUnit;
    
    TPCircularBuffer circularBuffer;
    BOOL firstBufferReached;
    
    void *rescueBuffer;
    UInt32 rescueBufferSize;
}

- (void)setReadyForMoreBytes;
@end

static OSStatus playbackCallback(void *inRefCon,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp *inTimeStamp,
                                 UInt32 inBusNumber,
                                 UInt32 inNumberFrames,
                                 AudioBufferList *ioData) {
    
    
    int numberOfChannels = ioData->mBuffers[0].mNumberChannels;
    AudioSampleType *outSample = (AudioSampleType *)ioData->mBuffers[0].mData;
    
    // Zero-out all the output samples first
    memset(outSample, 0, ioData->mBuffers[0].mDataByteSize);
    
    GPUImageAudioPlayer *p = (__bridge GPUImageAudioPlayer *)inRefCon;
    
    if (p.hasBuffer){
        int32_t availableBytes;
        AudioSampleType *bufferTail = TPCircularBufferTail([p getBuffer], &availableBytes);
        
        int32_t requestedBytesSize = inNumberFrames * kUnitSize * numberOfChannels;
        
        int bytesToRead = MIN(availableBytes, requestedBytesSize);
        memcpy(outSample, bufferTail, bytesToRead);
        TPCircularBufferConsume([p getBuffer], bytesToRead);
        
        if (availableBytes <= requestedBytesSize*2){
            [p setReadyForMoreBytes];
        }
        
        if (availableBytes <= requestedBytesSize) {
            p.hasBuffer = NO;
        }
        
    }
    
    return noErr;
}



@implementation GPUImageAudioPlayer

- (id)init{
    self = [super init];
    
    if (self)
    {
        firstBufferReached = NO;
        rescueBuffer = nil;
        rescueBufferSize = 0;
        _readyForMoreBytes = YES;
        [self initAudio];
    }
    
    return self;
}

- (void)dealloc{
    DisposeAUGraph(processingGraph);
    if (rescueBuffer != nil){
        free(rescueBuffer);
    }
    
    TPCircularBufferCleanup(&circularBuffer);
    [self stopPlaying];
}

- (void)setVolume:(NSUInteger)volume
{
    CheckStatus(AudioUnitSetParameter(mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, kOutputBus, volume, 0));
    AUGraphUpdate(processingGraph, NULL);
}

- (NSUInteger)volume
{
    float volume;
    AudioUnitGetParameter(mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, kOutputBus, &volume);
    return volume;
}

#pragma mark -
#pragma mark audio player methods

- (void)initAudio
{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryAmbient error:nil];
    [session setActive:YES error:nil];
    
    // create a new AUGraph
    NewAUGraph(&processingGraph);
    
    // AUNodes represent AudioUnits on the AUGraph and provide an
    // easy means for connecting audioUnits together.
    AUNode outputNode;
    AUNode mixerNode;
    
    // Create AudioComponentDescriptions for the AUs we want in the graph
    // mixer component
    AudioComponentDescription mixer_desc;
    mixer_desc.componentType = kAudioUnitType_Mixer;
    mixer_desc.componentSubType = kAudioUnitSubType_MultiChannelMixer;
    mixer_desc.componentFlags = 0;
    mixer_desc.componentFlagsMask = 0;
    mixer_desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    //  output component
    AudioComponentDescription output_desc;
    output_desc.componentType = kAudioUnitType_Output;
    output_desc.componentSubType = kAudioUnitSubType_RemoteIO;
    output_desc.componentFlags = 0;
    output_desc.componentFlagsMask = 0;
    output_desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Add nodes to the graph to hold our AudioUnits,
    // You pass in a reference to the  AudioComponentDescription
    // and get back an  AudioUnit
    AUGraphAddNode(processingGraph, &output_desc, &outputNode);
    AUGraphAddNode(processingGraph, &mixer_desc, &mixerNode );
    
    // Now we can manage connections using nodes in the graph.
    // Connect the mixer node's output to the output node's input
    AUGraphConnectNodeInput(processingGraph, mixerNode, 0, outputNode, 0);
    
    // open the graph AudioUnits are open but not initialized (no resource allocation occurs here)
    AUGraphOpen(processingGraph);
    
    // Get a link to the mixer AU so we can talk to it later
    AUGraphNodeInfo(processingGraph, mixerNode, NULL, &mixerUnit);
    
    UInt32 elementCount = 1;
    AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &elementCount, sizeof(elementCount));
    
    // Set output callback
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = playbackCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)(self);
    AUGraphSetNodeInputCallback(processingGraph, mixerNode, 0, &callbackStruct);
    
    
    // Describe format
    AudioStreamBasicDescription audioFormat;
    audioFormat.mFormatID	= kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagsCanonical;
    audioFormat.mSampleRate = SAMPLE_RATE;
    audioFormat.mReserved = 0;
    
    audioFormat.mBytesPerPacket = 2;
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mBytesPerFrame = 2;
    audioFormat.mChannelsPerFrame = 1;
    audioFormat.mBitsPerChannel = 16;
    
    // Apply format
    AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &audioFormat, sizeof(audioFormat));
    
    //init the processing graph
    AUGraphInitialize(processingGraph);
    
    TPCircularBufferInit(&circularBuffer, kTotalBufferSize);
    self.hasBuffer = NO;
}

- (void)startPlaying {
    // Start playing
    AUGraphStart(processingGraph);
}

- (void)stopPlaying {
    // Start playing
    AUGraphStop(processingGraph);
    TPCircularBufferClear(&circularBuffer);
    [self readyForMoreBytes];
}


- (void)copyBuffer:(CMSampleBufferRef)buf {
    if (!_readyForMoreBytes) return;
    
    if (!firstBufferReached)
    {
        firstBufferReached = YES;
        CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(buf);
        const AudioStreamBasicDescription* const asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
        
        AudioStreamBasicDescription audioFormat;
        UInt32 oSize = sizeof(audioFormat);
        AudioUnitGetProperty(mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &audioFormat, &oSize);
        
        audioFormat.mBytesPerPacket = asbd->mBytesPerPacket;
        audioFormat.mFramesPerPacket = asbd->mFramesPerPacket;
        audioFormat.mBytesPerFrame = asbd->mBytesPerFrame;
        audioFormat.mChannelsPerFrame = asbd->mChannelsPerFrame;
        audioFormat.mBitsPerChannel = asbd->mBitsPerChannel;
        
        NSLog(@"[AudioStreamBasicDescription] updating graph uppon first buffer");
        AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &audioFormat, oSize);
        AUGraphUpdate(processingGraph, NULL);
    }
    
    AudioBufferList abl;
    CMBlockBufferRef blockBuffer;
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buf, NULL, &abl, sizeof(abl), NULL, NULL, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &blockBuffer);
    
    UInt32 size = (unsigned int)CMSampleBufferGetTotalSampleSize(buf);
    BOOL bytesCopied = TPCircularBufferProduceBytes(&circularBuffer, abl.mBuffers[0].mData, size);
    
    if (!bytesCopied){
        //        NSLog(@"TPBuffer limit reached blocking more bytes (%ld)", size);
        _readyForMoreBytes = NO;
        
        if (size > kRescueBufferSize){
            NSLog(@"Unable to allocate enought space for rescue buffer, dropping audio frame");
        } else {
            if (rescueBuffer == nil) {
                rescueBuffer = malloc(kRescueBufferSize);
            }
            
            rescueBufferSize = size;
            memcpy(rescueBuffer, abl.mBuffers[0].mData, size);
        }
    }
    
    CFRelease(blockBuffer);
    
    
    if (!self.hasBuffer && bytesCopied > 0) {
        self.hasBuffer = YES;
    }
}

- (TPCircularBuffer *)getBuffer
{
    return &circularBuffer;
}

- (void)setReadyForMoreBytes{
    if (rescueBufferSize > 0){
        BOOL bytesCopied = TPCircularBufferProduceBytes(&circularBuffer, rescueBuffer, rescueBufferSize);
        if (!bytesCopied){
            NSLog(@"Unable to copy resuce buffer into main buffer, dropping frame");
        }
        rescueBufferSize = 0;
    }
    
    _readyForMoreBytes = YES;
}

@end
