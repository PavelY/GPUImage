//
//  GPUImageAudio.h
//  Pods
//
//  Created by Pavel Yurchenko on 11/16/16.
//
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

@interface GPUImageAudio : NSObject

@property (nonatomic, readonly) BOOL canPlayMore;


+ (GPUImageAudio*)audioOutput;

- (void)playSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end
