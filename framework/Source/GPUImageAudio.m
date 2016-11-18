//
//  GPUImageAudio.m
//  Pods
//
//  Created by Pavel Yurchenko on 11/16/16.
//
//

#import "GPUImageAudio.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <TPCircularBuffer.h>
#import <TPCircularBuffer+AudioBufferList.h>

static const NSInteger kOutputBus = 0;
static const NSInteger kCircularBufferSize = 655360;


@interface GPUImageAudio(Callback)

- (void)feedOutBuffer:(AudioBuffer*)outBuffer;

@end



void checkStatus(int status)
{
    if (status)
    {
        NSLog(@"Status not 0! %d\n", status);
    }
}

static OSStatus playbackCallback(void *inRefCon,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp *inTimeStamp,
                                 UInt32 inBusNumber,
                                 UInt32 inNumberFrames,
                                 AudioBufferList *ioData)
{
    GPUImageAudio *audio = (__bridge GPUImageAudio*)inRefCon;
    if (audio)
    {
        AudioBuffer *outBuffer = &ioData->mBuffers[0];
        [audio feedOutBuffer:outBuffer];
    }
    
    return noErr;
}



@interface GPUImageAudio ()
{
    AudioComponentInstance audioUnit;
    TPCircularBuffer mCircularBuffer;
    
    /** This extra buffer is needed to handle main buffer overloading. We will keep only one audio buffer list in it
     that failed to be placed in the main buffer last time.
     */
    TPCircularBuffer mExtraCircularBuffer;
}

@property (nonatomic, readonly) BOOL isExtraBufferEmpty;

/** In the following member we keep length of the block from current top audio buffer that was copied to output buffer
 last time
 */
@property (nonatomic, assign) NSUInteger topBufferCursor;

@end


@implementation GPUImageAudio

+ (GPUImageAudio*)audioOutput
{
    return [[GPUImageAudio alloc] init];
}

- (BOOL)isExtraBufferEmpty
{
    return (mExtraCircularBuffer.fillCount == 0);
}

- (BOOL)canPlayMore
{
    return self.isExtraBufferEmpty;
}

- (instancetype)init
{
    self = [super init];
    
    // initialize audio component for output
    OSStatus status = noErr;
    
    // Describe audio component
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Get component
    AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
    
    // Get audio units
    status = AudioComponentInstanceNew(inputComponent, &audioUnit);
    checkStatus(status);
    
    // Describe format
    AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate			= 44100.00;
    audioFormat.mFormatID			= kAudioFormatLinearPCM;
    audioFormat.mFormatFlags		= kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mFramesPerPacket	= 1;
    audioFormat.mChannelsPerFrame	= 1;
    audioFormat.mBitsPerChannel		= 16;
    audioFormat.mBytesPerPacket		= 2;
    audioFormat.mBytesPerFrame		= 2;
    
    // Apply format
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, 
                                  kOutputBus, 
                                  &audioFormat, 
                                  sizeof(audioFormat));
    checkStatus(status);
    
    // Set output callback
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = playbackCallback;
    callbackStruct.inputProcRefCon = (__bridge void * _Nullable)(self);
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Global,
                                  kOutputBus,
                                  &callbackStruct,
                                  sizeof(callbackStruct));
    checkStatus(status);
    

    // Initialize circular buffer
    TPCircularBufferInit(&mCircularBuffer, kCircularBufferSize);
    TPCircularBufferInit(&mExtraCircularBuffer, kCircularBufferSize);
    
    // Initialise
    status = AudioUnitInitialize(audioUnit);
    checkStatus(status);
    
    AudioOutputUnitStart(audioUnit);
    
    return self;
}

- (void)dealloc
{
    AudioOutputUnitStop(audioUnit);
    AudioUnitUninitialize(audioUnit);
    
    TPCircularBufferClear(&mCircularBuffer);
    TPCircularBufferCleanup(&mCircularBuffer);
    TPCircularBufferClear(&mExtraCircularBuffer);
    TPCircularBufferCleanup(&mExtraCircularBuffer);
}

- (void)playSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    // Update output audio format to correspond sample buffer's one
    if (sampleBuffer)
    {
        CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
        const AudioStreamBasicDescription* const asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
        
        AudioStreamBasicDescription audioFormat;
        UInt32 oSize = sizeof(audioFormat);
        AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &audioFormat, &oSize);
        
        audioFormat.mBytesPerPacket = asbd->mBytesPerPacket;
        audioFormat.mFramesPerPacket = asbd->mFramesPerPacket;
        audioFormat.mBytesPerFrame = asbd->mBytesPerFrame;
        audioFormat.mChannelsPerFrame = asbd->mChannelsPerFrame;
        audioFormat.mBitsPerChannel = asbd->mBitsPerChannel;
        
        OSStatus status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &audioFormat, oSize);
        checkStatus(status);
    }
    
    // Queue audio buffer
    AudioBufferList  localBufferList;
    CMBlockBufferRef blockBuffer;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, NULL, &localBufferList, sizeof(localBufferList), NULL, NULL,
                                                            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &blockBuffer);
    
    if (status == noErr && blockBuffer && localBufferList.mBuffers[0].mDataByteSize > 0)
    {
        AudioBuffer *audioBuffer = &localBufferList.mBuffers[0];
        //NSLog(@"Queuing buffer: channels = %d, dataSize = %d", audioBuffer->mNumberChannels, audioBuffer->mDataByteSize);
        
        if (!TPCircularBufferCopyAudioBufferList(&mCircularBuffer, &localBufferList, NULL, kTPCircularBufferCopyAll, NULL))
        {
            // store the buffer that was not copied locally and use to determine whether it can play more samples or not
            TPCircularBufferCopyAudioBufferList(&mExtraCircularBuffer, &localBufferList, NULL, kTPCircularBufferCopyAll, NULL);
        }
        
        CFRelease(blockBuffer);
    }
}

- (void)processExtraBuffer
{
    if (!self.isExtraBufferEmpty)
    {
        // Try moving audio list from extra buffer to main buffer
        AudioBufferList *localBufferList = TPCircularBufferNextBufferList(&mExtraCircularBuffer, NULL);
        if (localBufferList)
        {
            if (TPCircularBufferCopyAudioBufferList(&mCircularBuffer, localBufferList, NULL, kTPCircularBufferCopyAll, NULL))
            {
                TPCircularBufferConsumeNextBufferList(&mExtraCircularBuffer);
            }
        }
    }
}

- (void)feedOutBuffer:(AudioBuffer*)outBuffer
{
    if (outBuffer)
    {
        // Zero data in out buffer
        memset(outBuffer->mData, 0, outBuffer->mDataByteSize);
        
        // if there is buffer queued use it
        AudioBufferList *nextBufferList = TPCircularBufferNextBufferList(&mCircularBuffer, NULL);
        if (nextBufferList)
        {
            const UInt32 size = outBuffer->mDataByteSize;
            
            AudioBuffer *buffer = &nextBufferList->mBuffers[0];
            if (buffer->mDataByteSize == outBuffer->mDataByteSize)
            {
                memcpy(outBuffer->mData, buffer->mData, size);
                
                TPCircularBufferConsumeNextBufferList(&mCircularBuffer);
                self.topBufferCursor = 0;
            }
            else if (buffer->mDataByteSize - self.topBufferCursor >= outBuffer->mDataByteSize)
            {
                memcpy(outBuffer->mData, buffer->mData + self.topBufferCursor, size);
                
                self.topBufferCursor += size;
                if (self.topBufferCursor == buffer->mDataByteSize)
                {
                    TPCircularBufferConsumeNextBufferList(&mCircularBuffer);
                    self.topBufferCursor = 0;
                }
            }
            else
            {
                const UInt32 availableSize = buffer->mDataByteSize - self.topBufferCursor;
                memcpy(outBuffer->mData, buffer->mData + self.topBufferCursor, availableSize);
                outBuffer->mDataByteSize = availableSize;
                
                TPCircularBufferConsumeNextBufferList(&mCircularBuffer);
                self.topBufferCursor = 0;
                
                AudioBufferList *nextBufferList = TPCircularBufferNextBufferList(&mCircularBuffer, NULL);
                if (nextBufferList)
                {
                    const UInt32 needSize = outBuffer->mDataByteSize - availableSize;
                    
                    AudioBuffer *buffer = &nextBufferList->mBuffers[0];
                    if (buffer->mDataByteSize > needSize)
                    {
                        memcpy(outBuffer->mData + availableSize, buffer->mData, needSize);
                        self.topBufferCursor = needSize;
                    }
                }
            }
        }
    }
    
    // Process extra buffer and consume it if we have space in main buffer
    [self processExtraBuffer];
}

@end
