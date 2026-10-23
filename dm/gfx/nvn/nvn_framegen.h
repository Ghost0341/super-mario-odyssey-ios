// Color-only, optional VideoToolbox interpolation. Game simulation remains 60 Hz.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

NS_ASSUME_NONNULL_BEGIN
@interface NVNFrameGenOutput : NSObject
@property(nonatomic, readonly) id<MTLTexture> texture;
@property(nonatomic, readonly) BOOL generated;
@property(nonatomic, readonly) uint64_t ticket;
@property(nonatomic, readonly) uint64_t gameFrame;
@property(nonatomic, readonly) double enqueuedTime;
// Logical geometry is immutable metadata of the source raster, including
// native snapshots and generated midpoints; it never follows late scene state.
@property(nonatomic, readonly) double logicalAspect;
@property(nonatomic, readonly) uint64_t geometryGeneration;
@end

@interface NVNFrameGenCapture : NSObject
@property(nonatomic, readonly) NVNFrameGenOutput *sourceOutput;
@end

@interface NVNFrameGenerator : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;
@property(atomic, readonly) BOOL captureReady;
@property(atomic, readonly) BOOL interpolationReady;
@property(atomic) BOOL interpolationEnabled;
@property(atomic) BOOL suspended; // Set before drainGPU; late ML results cannot submit GPU work.
// Capture worker ONLY. Waits for this GPU snapshot, never for the ML processor.
- (nullable NVNFrameGenCapture *)captureSource:(id<MTLTexture>)source
                                        crop:(MTLRegion)crop
                             originLowerLeft:(BOOL)flip
                                      ticket:(uint64_t)ticket
                                   gameFrame:(uint64_t)frame
                                enqueuedTime:(double)time
                               logicalAspect:(double)aspect
                          geometryGeneration:(uint64_t)generation
                                   waitEvent:(nullable id<MTLEvent>)event
                                   waitValue:(uint64_t)value;
// A DIFFERENT serial worker owns processing/history. Returns [midpoint, source]
// or [source] when warming, disabled, unsupported, discontinuous, or overloaded.
- (NSArray<NVNFrameGenOutput *> *)processCapture:(NVNFrameGenCapture *)capture;
- (void)resetHistory; // Processing worker ONLY; invalidates earlier outputs.
- (NSDictionary<NSString *, id> *)stats;
// Display callback: no waiting, compilation, drawable acquisition, or ML work.
// Completion reports the drawable's actual presentedTime, never GPU completion.
- (BOOL)presentOutput:(NVNFrameGenOutput *)output
             drawable:(id<CAMetalDrawable>)drawable
             viewport:(MTLViewport)viewport
           completion:(nullable void (^)(double presentedTime))completion;
- (BOOL)presentOutput:(NVNFrameGenOutput *)output
             drawable:(id<CAMetalDrawable>)drawable
             viewport:(MTLViewport)viewport
           completion:(nullable void (^)(double presentedTime))completion
        gpuCompletion:(nullable void (^)(BOOL success))gpuCompletion;
// Lifecycle worker ONLY, after capture/process/presentation submissions stop.
// Drains already submitted work on the independent Metal queues, not ML work.
- (void)drainGPU;
@end
NS_ASSUME_NONNULL_END
