// Independent, bounded RGB snapshot / color-only frame interpolation / presentation.
// No NVN resource or ticket is retained after captureSource returns. Original
// frames retain RGB quality; only generated frames pass through video-range NV12.
#import "nvn_framegen.h"
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor_LowLatencyFrameInterpolation.h>
#import <IOSurface/IOSurfaceRef.h>
#include <stdatomic.h>
#include <time.h>
#include <TargetConditionals.h>

static double fg_now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) * 1e-9; }
enum { FG_SOURCE_LIMIT = 8, FG_MIDPOINT_LIMIT = 4 };

// All coordinates in owned frames are upright and tightly cropped. Encoded RGB
// follows NVN scanout bytes, not linear-light values. BT.709 matrix, video range.
static NSString *const fg_metal = @
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; float2 uv; };\n"
"vertex V fg_vertex(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(-1,3),float2(3,-1)}; V v; v.p=float4(p[i],0,1); v.uv=float2((p[i].x+1)*.5,(1-p[i].y)*.5); return v; }\n"
"struct Rect { float4 rect; float4 bounds; };\n"
"fragment float4 fg_copy(V v [[stage_in]],texture2d<float> t [[texture(0)]],constant Rect &r [[buffer(0)]]) { constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear); float2 uv=clamp(r.rect.xy+v.uv*r.rect.zw,r.bounds.xy,r.bounds.zw); return float4(t.sample(s,uv).rgb,1); }\n"
"kernel void fg_to_nv12(texture2d<float,access::read> rgb [[texture(0)]],texture2d<float,access::write> y [[texture(1)]],texture2d<float,access::write> uv [[texture(2)]],uint2 p [[thread_position_in_grid]]) {\n"
" uint2 size=uint2(rgb.get_width(),rgb.get_height()); if(p.x<y.get_width()&&p.y<y.get_height()){ float3 c=rgb.read(min(p,size-1)).rgb; float l=dot(c,float3(.2126,.7152,.0722)); y.write(float4((16.+219.*l)/255.,0,0,1),p); }\n"
" if(p.x<uv.get_width()&&p.y<uv.get_height()){ uint2 q=p*2; float3 c=(rgb.read(min(q,size-1)).rgb+rgb.read(min(q+uint2(1,0),size-1)).rgb+rgb.read(min(q+uint2(0,1),size-1)).rgb+rgb.read(min(q+uint2(1,1),size-1)).rgb)*.25; float l=dot(c,float3(.2126,.7152,.0722)); float2 ch=float2((c.b-l)/1.8556,(c.r-l)/1.5748); uv.write(float4((128.+224.*ch)/255.,0,1),p); } }\n"
"kernel void fg_from_nv12(texture2d<float,access::read> y [[texture(0)]],texture2d<float,access::sample> uv [[texture(1)]],texture2d<float,access::write> rgb [[texture(2)]],uint2 p [[thread_position_in_grid]]) {\n"
" if(p.x>=rgb.get_width()||p.y>=rgb.get_height())return; constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear); float l=(y.read(p).r*255.-16.)/219.; float2 tc=((float2(p)+.5)*.5)/float2(uv.get_width(),uv.get_height()); float2 c=(uv.sample(s,tc).rg*255.-128.)/224.; float3 v=float3(l+1.5748*c.y,l-.187324*c.x-.468124*c.y,l+1.8556*c.x); rgb.write(float4(clamp(v,0.,1.),1),p); }\n";

// One budget shared by old/new dimensions bounds allocations even while outputs
// from an old configuration are still owned by GPU completion handlers.
@interface NVNFGBudget : NSObject {
@public atomic_uint sourceCount, midpointCount;
}
@end
@implementation NVNFGBudget @end

@interface NVNFGSurface : NSObject {
@public id<MTLTexture> rgb, y, uv;
    CVPixelBufferRef pixelBuffer;
    BOOL midpoint;
    NVNFGBudget *budget;
}
@end
@implementation NVNFGSurface
- (void)dealloc {
    if (pixelBuffer) CVPixelBufferRelease(pixelBuffer);
    if (budget) atomic_fetch_sub_explicit(midpoint ? &budget->midpointCount : &budget->sourceCount, 1, memory_order_relaxed);
}
@end

@interface NVNFGContext : NSObject {
@public NSUInteger width, height;
    id<MTLDevice> device;
    NVNFGBudget *budget;
    atomic_bool poolsReady, sessionReady, failed, retired;
    CVPixelBufferPoolRef sourcePool, destinationPool;
    VTFrameProcessor *processor;
    NSLock *poolLock;
    NSMutableArray<NVNFGSurface *> *sourceFree, *midpointFree;
    NSString *reason;
    double modelLoadMS;
}
- (nullable NVNFGSurface *)acquire:(BOOL)midpoint;
- (void)recycle:(NVNFGSurface *)surface;
- (BOOL)addPixelBuffer:(NVNFGSurface *)surface;
- (void)retire;
@end

static CVPixelBufferPoolRef fg_pool(NSDictionary *attributes, CVReturn *status) {
    NSDictionary *extra = @{(__bridge NSString *)kCVPixelBufferMetalCompatibilityKey:@YES,
                           (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    CFDictionaryRef resolved = NULL;
    *status = CVPixelBufferCreateResolvedAttributesDictionary(NULL, (__bridge CFArrayRef)@[attributes, extra], &resolved);
    if (*status != kCVReturnSuccess) return NULL;
    CVPixelBufferPoolRef pool = NULL;
    *status = CVPixelBufferPoolCreate(NULL, NULL, resolved, &pool);
    CFRelease(resolved);
    return pool;
}

@implementation NVNFGContext
- (instancetype)init {
    if ((self = [super init])) { poolLock = [NSLock new]; sourceFree = [NSMutableArray new]; midpointFree = [NSMutableArray new]; reason = @"warming"; }
    return self;
}
- (void)dealloc {
    // ML teardown must never be the surprise cost of releasing an output on the
    // display callback. No processing can still own this context at this point.
    VTFrameProcessor *retiredProcessor = processor;
    if (retiredProcessor) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [retiredProcessor endSession]; });
    if (sourcePool) CVPixelBufferPoolRelease(sourcePool);
    if (destinationPool) CVPixelBufferPoolRelease(destinationPool);
}
- (NVNFGSurface *)acquire:(BOOL)isMidpoint {
    [poolLock lock];
    if (atomic_load(&retired)) { [poolLock unlock]; return nil; }
    NSMutableArray *free = isMidpoint ? midpointFree : sourceFree;
    NVNFGSurface *surface = free.lastObject;
    if (surface) [free removeLastObject];
    [poolLock unlock];
    if (!surface) {
        atomic_uint *count = isMidpoint ? &budget->midpointCount : &budget->sourceCount;
        unsigned limit = isMidpoint ? FG_MIDPOINT_LIMIT : FG_SOURCE_LIMIT;
        unsigned old = atomic_load_explicit(count, memory_order_relaxed);
        do { if (old >= limit) return nil; }
        while (!atomic_compare_exchange_weak_explicit(count, &old, old + 1, memory_order_relaxed, memory_order_relaxed));
        surface = [NVNFGSurface new]; surface->budget = budget; surface->midpoint = isMidpoint;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        surface->rgb = [device newTextureWithDescriptor:td];
        surface->rgb.label = isMidpoint ? @"NVN generated RGB" : @"NVN owned native RGB";
        if (!surface->rgb) return nil;
    }
    if (!surface->pixelBuffer && atomic_load_explicit(&poolsReady, memory_order_acquire) && ![self addPixelBuffer:surface]) {
        if (isMidpoint) { [self recycle:surface]; return nil; }
        // A missing optional NV12 buffer must not prevent the RGB native path.
    }
    return surface;
}
- (void)recycle:(NVNFGSurface *)surface {
    [poolLock lock]; if (!atomic_load(&retired)) [(surface->midpoint ? midpointFree : sourceFree) addObject:surface]; [poolLock unlock];
}
- (void)retire { [poolLock lock]; atomic_store(&retired, true); [sourceFree removeAllObjects]; [midpointFree removeAllObjects]; [poolLock unlock]; }
- (BOOL)addPixelBuffer:(NVNFGSurface *)surface {
    CVPixelBufferPoolRef pool = surface->midpoint ? destinationPool : sourcePool;
    if (!pool) return NO;
    NSDictionary *aux = @{(__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey:@(surface->midpoint ? FG_MIDPOINT_LIMIT : FG_SOURCE_LIMIT)};
    CVPixelBufferRef pb = NULL;
    CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, pool, (__bridge CFDictionaryRef)aux, &pb);
    if (result != kCVReturnSuccess || !pb) {
        [poolLock lock]; reason = [NSString stringWithFormat:@"NV12 pool allocation failed (%d); native RGB fallback", result]; [poolLock unlock];
        return NO;
    }
    size_t left = 0, right = 0, top = 0, bottom = 0;
    CVPixelBufferGetExtendedPixels(pb, &left, &right, &top, &bottom);
    IOSurfaceRef io = CVPixelBufferGetIOSurface(pb);
    // The public IOSurface texture initializer exposes the allocated extended
    // rows too. Fill all of them on GPU, equivalent to edge replication.
    BOOL valid = io && !left && !top && !(width & 1) && !(height & 1) && !(right & 1) && !(bottom & 1);
    id<MTLTexture> planes[2] = {nil, nil};
    for (size_t plane = 0; valid && plane < 2; plane++) {
        size_t pw = (width + right) >> plane, ph = (height + bottom) >> plane;
        // Address subtraction queries allocation layout only; never reads pixels.
        uintptr_t base = (uintptr_t)IOSurfaceGetBaseAddress(io);
        size_t offset = (uintptr_t)IOSurfaceGetBaseAddressOfPlane(io, plane) - base;
        size_t bytes = IOSurfaceGetBytesPerRowOfPlane(io, plane) * ph;
        size_t end = plane == 0 ? (uintptr_t)IOSurfaceGetBaseAddressOfPlane(io, 1) - base : IOSurfaceGetAllocSize(io);
        if (offset + bytes > end || pw * (plane ? 2 : 1) > IOSurfaceGetBytesPerRowOfPlane(io, plane)) { valid = NO; break; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:plane ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm width:pw height:ph mipmapped:NO];
        td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        planes[plane] = [device newTextureWithDescriptor:td iosurface:io plane:plane];
        valid = planes[plane] != nil;
    }
    if (!valid) {
        CVPixelBufferRelease(pb);
        [poolLock lock]; reason = @"Processor NV12 padding cannot be safely exposed to Metal; native RGB fallback"; [poolLock unlock];
        atomic_store_explicit(&failed, true, memory_order_release); return NO;
    }
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    surface->pixelBuffer = pb; surface->y = planes[0]; surface->uv = planes[1]; return YES;
}
@end

@interface NVNFGLease : NSObject
@property(nonatomic) NVNFGContext *context;
@property(nonatomic) NVNFGSurface *surface;
@end
@implementation NVNFGLease
- (void)dealloc { [_context recycle:_surface]; }
@end

@interface NVNFrameGenOutput ()
@property(nonatomic, readwrite) id<MTLTexture> texture;
@property(nonatomic, readwrite) BOOL generated;
@property(nonatomic, readwrite) uint64_t ticket, gameFrame;
@property(nonatomic, readwrite) double enqueuedTime;
@property(nonatomic) NVNFGLease *lease;
@property(nonatomic) uint64_t epoch;
@end
@implementation NVNFrameGenOutput @end

@interface NVNFrameGenCapture ()
@property(nonatomic, readwrite) NVNFrameGenOutput *sourceOutput;
@end
@implementation NVNFrameGenCapture @end

@interface NVNFrameGenerator () {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _captureQueue, _conversionQueue, _presentQueue;
    id<MTLRenderPipelineState> _copyPipeline, _presentBGRA, _presentRGBA;
    id<MTLComputePipelineState> _toNV12, _fromNV12;
    dispatch_queue_t _warmQueue;
    NSLock *_contextLock, *_submissionLock;
    NVNFGContext *_context;
    NVNFGBudget *_budget;
    NVNFrameGenCapture *_previous; // Process worker ONLY.
    atomic_bool _captureReady, _enabled, _suspended;
    atomic_uint _loadingContexts;
    atomic_ullong _epoch;
    atomic_ullong _captures, _captureErrors, _processErrors, _generated, _nativeOnly, _presentSubmissions, _actualPresents, _actualGenerated, _resets, _poolMisses;
    atomic_uint _processingInFlight;
    _Atomic(double) _lastCopyMS, _copyTotalMS, _lastProcessMS, _processTotalMS, _lastConversionMS, _conversionTotalMS, _lastPresentTime;
    NSString *_pipelineFailure;
}
@end

static id<MTLRenderPipelineState> fg_render_pipeline(id<MTLDevice> device, id<MTLLibrary> library, MTLPixelFormat format, NSError **error) {
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"fg_vertex"]; pd.fragmentFunction = [library newFunctionWithName:@"fg_copy"];
    pd.colorAttachments[0].pixelFormat = format;
    return [device newRenderPipelineStateWithDescriptor:pd error:error];
}
static void fg_dispatch(id<MTLComputeCommandEncoder> e, id<MTLComputePipelineState> pipeline, NSUInteger width, NSUInteger height) {
    [e setComputePipelineState:pipeline];
    [e dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
}
static NVNFrameGenOutput *fg_output(NVNFGLease *lease, BOOL generated, uint64_t ticket, uint64_t gameFrame, double time, uint64_t epoch) {
    NVNFrameGenOutput *o = [NVNFrameGenOutput new]; o.texture = lease.surface->rgb; o.lease = lease;
    o.generated = generated; o.ticket = ticket; o.gameFrame = gameFrame; o.enqueuedTime = time; o.epoch = epoch; return o;
}

@implementation NVNFrameGenerator
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _device = device; _contextLock = [NSLock new]; _submissionLock = [NSLock new]; _budget = [NVNFGBudget new];
        atomic_init(&_enabled, true); atomic_init(&_epoch, 1);
        _captureQueue = [device newCommandQueue]; _captureQueue.label = @"NVN framegen snapshot";
        _conversionQueue = [device newCommandQueue]; _conversionQueue.label = @"NVN framegen generated RGB";
        _presentQueue = [device newCommandQueue]; _presentQueue.label = @"NVN framegen display";
        _warmQueue = dispatch_queue_create("dm.nvn.framegen.warm", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        dispatch_async(_warmQueue, ^{ @autoreleasepool {
            NSError *error = nil;
            id<MTLLibrary> library = [device newLibraryWithSource:fg_metal options:nil error:&error];
            if (library) {
                self->_copyPipeline = fg_render_pipeline(device, library, MTLPixelFormatRGBA8Unorm, &error);
                self->_presentRGBA = self->_copyPipeline;
                self->_presentBGRA = fg_render_pipeline(device, library, MTLPixelFormatBGRA8Unorm, &error);
                self->_toNV12 = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"fg_to_nv12"] error:&error];
                self->_fromNV12 = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"fg_from_nv12"] error:&error];
            }
            BOOL ready = self->_captureQueue && self->_conversionQueue && self->_presentQueue && self->_copyPipeline && self->_presentBGRA && self->_toNV12 && self->_fromNV12;
            if (!ready) { [self->_contextLock lock]; self->_pipelineFailure = error.localizedDescription ?: @"Metal pipeline/queue unavailable"; [self->_contextLock unlock]; }
            atomic_store_explicit(&self->_captureReady, ready, memory_order_release);
        } });
    }
    return self;
}
- (BOOL)captureReady { return atomic_load_explicit(&_captureReady, memory_order_acquire); }
- (BOOL)interpolationEnabled { return atomic_load_explicit(&_enabled, memory_order_acquire); }
- (void)setInterpolationEnabled:(BOOL)enabled { atomic_store_explicit(&_enabled, enabled, memory_order_release); }
- (BOOL)suspended { return atomic_load_explicit(&_suspended, memory_order_acquire); }
- (void)setSuspended:(BOOL)suspended {
    // The lock serializes only CPU encoding/submission, never a GPU or ML wait.
    [_submissionLock lock]; atomic_store_explicit(&_suspended, suspended, memory_order_release); [_submissionLock unlock];
}
- (BOOL)interpolationReady {
    [_contextLock lock]; NVNFGContext *context = _context; [_contextLock unlock];
    return context && atomic_load_explicit(&context->sessionReady, memory_order_acquire) && !atomic_load_explicit(&context->failed, memory_order_acquire);
}
- (NVNFGContext *)contextWidth:(NSUInteger)width height:(NSUInteger)height {
    [_contextLock lock];
    NVNFGContext *context = _context;
    if (!context || context->width != width || context->height != height) {
        [context retire];
        context = [NVNFGContext new]; context->width = width; context->height = height; context->device = _device; context->budget = _budget;
        _context = context;
        // Avoid an unbounded queue of multi-second model loads if a title changes
        // its render dimensions repeatedly while the initial model is loading.
        unsigned expected = 0;
        if (!atomic_compare_exchange_strong(&_loadingContexts, &expected, 1)) {
            context->reason = @"Source dimensions changed during model load; native RGB fallback";
            atomic_store(&context->failed, true); [_contextLock unlock]; return context;
        }
        // Session/model load is entirely separate from snapshot and processing.
        dispatch_async(_warmQueue, ^{ @autoreleasepool {
            NSString *failure = nil;
#if !TARGET_OS_SIMULATOR
            if (@available(macOS 26.0, iOS 26.0, tvOS 26.0, *)) {
                if (!VTLowLatencyFrameInterpolationConfiguration.supported) failure = @"VideoToolbox low-latency interpolation unsupported";
                if ((width & 1) || (height & 1)) failure = @"NV12 requires even source dimensions; source kept unchanged";
                if (@available(macOS 27.0, iOS 27.0, tvOS 27.0, *)) {
                    NSInteger dim = [VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1];
                    NSInteger pixels = [VTLowLatencyFrameInterpolationConfiguration maximumPixelCountForSpatialScaleFactor:1];
                    if (width > (NSUInteger)MAX(dim, 0) || height > (NSUInteger)MAX(dim, 0) || width * height > (NSUInteger)MAX(pixels, 0)) failure = @"Source exceeds VideoToolbox dimensions; source kept unchanged";
                }
                VTLowLatencyFrameInterpolationConfiguration *config = failure ? nil : [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:width frameHeight:height numberOfInterpolatedFrames:1];
                if (!failure && (!config || ![config.frameSupportedPixelFormats containsObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)])) failure = @"VideoToolbox does not support source-sized video-range NV12";
                if (!failure) {
                    CVReturn status = kCVReturnSuccess;
                    context->sourcePool = fg_pool(config.sourcePixelBufferAttributes, &status);
                    if (context->sourcePool) context->destinationPool = fg_pool(config.destinationPixelBufferAttributes, &status);
                    if (!context->sourcePool || !context->destinationPool) failure = [NSString stringWithFormat:@"Pixel buffer pool creation failed (%d)", status];
                    else {
                        atomic_store_explicit(&context->poolsReady, true, memory_order_release);
                        VTFrameProcessor *processor = [VTFrameProcessor new]; NSError *error = nil; double start = fg_now();
                        BOOL ok = [processor startSessionWithConfiguration:config error:&error];
                        [context->poolLock lock]; context->modelLoadMS = (fg_now() - start) * 1000; [context->poolLock unlock];
                        if (!ok) failure = error.localizedDescription ?: @"VideoToolbox model session failed";
                        else if (atomic_load_explicit(&context->failed, memory_order_acquire)) {
                            [context->poolLock lock]; failure = context->reason; [context->poolLock unlock];
                            [processor endSession];
                        } else { context->processor = processor; atomic_store_explicit(&context->sessionReady, true, memory_order_release); }
                    }
                }
            } else failure = @"VideoToolbox interpolation requires OS 26 or later";
#else
            failure = @"VideoToolbox frame interpolation unavailable in Simulator";
#endif
            [context->poolLock lock]; context->reason = failure ?: @"ready"; [context->poolLock unlock];
            if (failure) atomic_store_explicit(&context->failed, true, memory_order_release);
            atomic_store(&self->_loadingContexts, 0);
        } });
    }
    [_contextLock unlock]; return context;
}
- (NVNFrameGenCapture *)captureSource:(id<MTLTexture>)source crop:(MTLRegion)crop originLowerLeft:(BOOL)flip ticket:(uint64_t)ticket gameFrame:(uint64_t)frame enqueuedTime:(double)time waitEvent:(id<MTLEvent>)event waitValue:(uint64_t)value {
    if (!self.captureReady || self.suspended) return nil;
    uint64_t epoch = atomic_load_explicit(&_epoch, memory_order_acquire);
    if (!source || source.textureType != MTLTextureType2D || source.sampleCount != 1 || crop.origin.z || crop.size.depth != 1 || !crop.size.width || !crop.size.height || crop.origin.x > source.width || crop.size.width > source.width - crop.origin.x || crop.origin.y > source.height || crop.size.height > source.height - crop.origin.y) {
        atomic_fetch_add(&_captureErrors, 1); return nil;
    }
    MTLPixelFormat format = source.pixelFormat;
    if (format == MTLPixelFormatRGBA8Unorm_sRGB || format == MTLPixelFormatBGRA8Unorm_sRGB) {
        source = [source newTextureViewWithPixelFormat:format == MTLPixelFormatRGBA8Unorm_sRGB ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatBGRA8Unorm];
        if (!source) { atomic_fetch_add(&_captureErrors, 1); return nil; }
    } else if (format != MTLPixelFormatRGBA8Unorm && format != MTLPixelFormatBGRA8Unorm) { atomic_fetch_add(&_captureErrors, 1); return nil; }
    NVNFGContext *context = [self contextWidth:crop.size.width height:crop.size.height];
    NVNFGSurface *surface = [context acquire:NO];
    if (!surface) { atomic_fetch_add(&_poolMisses, 1); return nil; }
    NVNFGLease *lease = [NVNFGLease new]; lease.context = context; lease.surface = surface;
    id<MTLCommandBuffer> cb = [_captureQueue commandBuffer]; cb.label = @"NVN snapshot and RGB to NV12";
    if (!cb) { atomic_fetch_add(&_captureErrors, 1); return nil; }
    if (event) [cb encodeWaitForEvent:event value:value];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = surface->rgb; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    if (!e) { atomic_fetch_add(&_captureErrors, 1); return nil; }
    float x = (float)crop.origin.x / source.width, y = (float)crop.origin.y / source.height, w = (float)crop.size.width / source.width, h = (float)crop.size.height / source.height;
    float rect[8] = {x, flip ? y + h : y, w, flip ? -h : h, (crop.origin.x + .5f) / source.width, (crop.origin.y + .5f) / source.height, (crop.origin.x + crop.size.width - .5f) / source.width, (crop.origin.y + crop.size.height - .5f) / source.height};
    [e setRenderPipelineState:_copyPipeline]; [e setFragmentTexture:source atIndex:0]; [e setFragmentBytes:rect length:sizeof rect atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    if (surface->pixelBuffer) {
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        if (!ce) { atomic_fetch_add(&_captureErrors, 1); return nil; }
        [ce setTexture:surface->rgb atIndex:0]; [ce setTexture:surface->y atIndex:1]; [ce setTexture:surface->uv atIndex:2];
        fg_dispatch(ce, _toNV12, surface->y.width, surface->y.height); [ce endEncoding];
    }
    // Only this dedicated snapshot worker waits. Parent can release its original
    // game input ticket immediately on return, before any ML work is queued.
    [_submissionLock lock];
    if (self.suspended) { [_submissionLock unlock]; return nil; }
    double started = fg_now(); [cb commit]; [_submissionLock unlock];
    [cb waitUntilCompleted]; double ms = (fg_now() - started) * 1000;
    atomic_store(&_lastCopyMS, ms); atomic_fetch_add(&_copyTotalMS, ms);
    if (cb.status != MTLCommandBufferStatusCompleted || self.suspended || epoch != atomic_load_explicit(&_epoch, memory_order_acquire)) { atomic_fetch_add(&_captureErrors, 1); return nil; }
    NVNFrameGenCapture *capture = [NVNFrameGenCapture new]; capture.sourceOutput = fg_output(lease, NO, ticket, frame, time, epoch);
    atomic_fetch_add(&_captures, 1); return capture;
}
- (NSArray<NVNFrameGenOutput *> *)processCapture:(NVNFrameGenCapture *)capture {
    NVNFrameGenOutput *source = capture.sourceOutput;
    uint64_t epoch = atomic_load_explicit(&_epoch, memory_order_acquire);
    if (!source || self.suspended || source.epoch != epoch) return @[];
    NVNFrameGenCapture *previous = _previous; _previous = capture;
    NVNFrameGenOutput *p = previous.sourceOutput;
    NVNFGContext *context = source.lease.context;
    // Gaps and loading transitions are discontinuities, not invented motion.
    double delta = source.enqueuedTime - p.enqueuedTime;
    if (!self.interpolationEnabled || !p || p.epoch != epoch || p.lease.context != context || source.ticket <= p.ticket || source.gameFrame != p.gameFrame + 1 || delta < .004 || delta > .05 || !source.lease.surface->pixelBuffer || !p.lease.surface->pixelBuffer || !atomic_load_explicit(&context->sessionReady, memory_order_acquire) || atomic_load_explicit(&context->failed, memory_order_acquire)) {
        atomic_fetch_add(&_nativeOnly, 1); return @[source];
    }
    NVNFGSurface *surface = [context acquire:YES];
    if (!surface || !surface->pixelBuffer) { atomic_fetch_add(&_poolMisses, 1); atomic_fetch_add(&_nativeOnly, 1); return @[source]; }
    NVNFGLease *lease = [NVNFGLease new]; lease.context = context; lease.surface = surface;
#if !TARGET_OS_SIMULATOR
    if (@available(macOS 26.0, iOS 26.0, tvOS 26.0, *)) {
        VTFrameProcessorFrame *pf = [[VTFrameProcessorFrame alloc] initWithBuffer:p.lease.surface->pixelBuffer presentationTimeStamp:CMTimeMakeWithSeconds(p.enqueuedTime, 600000)];
        VTFrameProcessorFrame *cf = [[VTFrameProcessorFrame alloc] initWithBuffer:source.lease.surface->pixelBuffer presentationTimeStamp:CMTimeMakeWithSeconds(source.enqueuedTime, 600000)];
        double midpointTime = (p.enqueuedTime + source.enqueuedTime) * .5;
        VTFrameProcessorFrame *df = [[VTFrameProcessorFrame alloc] initWithBuffer:surface->pixelBuffer presentationTimeStamp:CMTimeMakeWithSeconds(midpointTime, 600000)];
        VTLowLatencyFrameInterpolationParameters *params = pf && cf && df ? [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:cf previousFrame:pf interpolationPhase:@[@.5] destinationFrames:@[df]] : nil;
        NSError *error = nil; double started = fg_now();
        atomic_fetch_add(&_processingInFlight, 1);
        BOOL ok = params && [context->processor processWithParameters:params error:&error];
        atomic_fetch_sub(&_processingInFlight, 1);
        double ms = (fg_now() - started) * 1000; atomic_store(&_lastProcessMS, ms); atomic_fetch_add(&_processTotalMS, ms);
        // Disabling or resetting while ML runs must not publish a stale result
        // or submit the subsequent RGB conversion during lifecycle suspension.
        if (self.suspended || epoch != atomic_load_explicit(&_epoch, memory_order_acquire)) return @[];
        if (!self.interpolationEnabled) { atomic_fetch_add(&_nativeOnly, 1); return @[source]; }
        if (!ok) {
            atomic_fetch_add(&_processErrors, 1); atomic_fetch_add(&_nativeOnly, 1);
            [context->poolLock lock]; context->reason = error.localizedDescription ?: @"VideoToolbox frame processing failed"; [context->poolLock unlock];
            return @[source];
        }
        id<MTLCommandBuffer> cb = [_conversionQueue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        if (!cb || !ce) { atomic_fetch_add(&_processErrors, 1); atomic_fetch_add(&_nativeOnly, 1); return @[source]; }
        [ce setTexture:surface->y atIndex:0]; [ce setTexture:surface->uv atIndex:1]; [ce setTexture:surface->rgb atIndex:2];
        fg_dispatch(ce, _fromNV12, context->width, context->height); [ce endEncoding];
        [_submissionLock lock];
        if (self.suspended || epoch != atomic_load_explicit(&_epoch, memory_order_acquire)) { [_submissionLock unlock]; return @[]; }
        if (!self.interpolationEnabled) { [_submissionLock unlock]; atomic_fetch_add(&_nativeOnly, 1); return @[source]; }
        double conversionStarted = fg_now(); [cb commit]; [_submissionLock unlock]; [cb waitUntilCompleted];
        double conversionMS = (fg_now() - conversionStarted) * 1000; atomic_store(&_lastConversionMS, conversionMS); atomic_fetch_add(&_conversionTotalMS, conversionMS);
        if (self.suspended || epoch != atomic_load_explicit(&_epoch, memory_order_acquire)) return @[];
        if (!self.interpolationEnabled) { atomic_fetch_add(&_nativeOnly, 1); return @[source]; }
        if (cb.status != MTLCommandBufferStatusCompleted) { atomic_fetch_add(&_processErrors, 1); atomic_fetch_add(&_nativeOnly, 1); return @[source]; }
        NVNFrameGenOutput *midpoint = fg_output(lease, YES, source.ticket, source.gameFrame, midpointTime, epoch);
        atomic_fetch_add(&_generated, 1); return @[midpoint, source];
    }
#endif
    atomic_fetch_add(&_nativeOnly, 1); return @[source];
}
- (void)resetHistory {
    atomic_fetch_add_explicit(&_epoch, 1, memory_order_acq_rel); _previous = nil; atomic_fetch_add(&_resets, 1);
}
- (BOOL)presentOutput:(NVNFrameGenOutput *)output drawable:(id<CAMetalDrawable>)drawable viewport:(MTLViewport)viewport completion:(void (^)(double))completion {
    return [self presentOutput:output drawable:drawable viewport:viewport completion:completion gpuCompletion:nil];
}
- (BOOL)presentOutput:(NVNFrameGenOutput *)output drawable:(id<CAMetalDrawable>)drawable viewport:(MTLViewport)viewport completion:(void (^)(double))completion gpuCompletion:(void (^)(BOOL))gpuCompletion {
    if (!self.captureReady || self.suspended || !output || !drawable || output.epoch != atomic_load_explicit(&_epoch, memory_order_acquire)) return NO;
    id<MTLRenderPipelineState> pipeline = drawable.texture.pixelFormat == MTLPixelFormatBGRA8Unorm ? _presentBGRA : drawable.texture.pixelFormat == MTLPixelFormatRGBA8Unorm ? _presentRGBA : nil;
    if (!pipeline) return NO;
    id<MTLCommandBuffer> cb = [_presentQueue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    if (!cb || !e) return NO;
    float rect[8] = {0, 0, 1, 1, .5f / output.texture.width, .5f / output.texture.height, 1 - .5f / output.texture.width, 1 - .5f / output.texture.height};
    [e setViewport:viewport]; [e setRenderPipelineState:pipeline]; [e setFragmentTexture:output.texture atIndex:0]; [e setFragmentBytes:rect length:sizeof rect atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    BOOL generated = output.generated;
    [_submissionLock lock];
    if (self.suspended || output.epoch != atomic_load_explicit(&_epoch, memory_order_acquire)) { [_submissionLock unlock]; return NO; }
    [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
        double actualTime = shown.presentedTime;
        if (actualTime > 0) { atomic_fetch_add(&self->_actualPresents, 1); if (generated) atomic_fetch_add(&self->_actualGenerated, 1); atomic_store(&self->_lastPresentTime, actualTime); }
        if (completion) completion(actualTime);
    }];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)output.texture; /* Retain lease through GPU completion. */ if (gpuCompletion) gpuCompletion(done.status == MTLCommandBufferStatusCompleted); }];
    [cb presentDrawable:drawable]; [cb commit]; [_submissionLock unlock]; atomic_fetch_add(&_presentSubmissions, 1); return YES;
}
- (void)drainGPU {
    // Call only after producers stop; no queue marker can cover later submissions.
    id<MTLCommandQueue> queues[3] = {_captureQueue, _conversionQueue, _presentQueue};
    for (int i = 0; i < 3; i++) { id<MTLCommandBuffer> cb = [queues[i] commandBuffer]; [cb commit]; [cb waitUntilCompleted]; }
}
- (NSDictionary<NSString *, id> *)stats {
    [_contextLock lock]; NVNFGContext *context = _context; NSString *pipelineFailure = _pipelineFailure; [_contextLock unlock];
    NSString *reason = pipelineFailure ?: @"waiting for first source"; double load = 0;
    if (context) { [context->poolLock lock]; reason = context->reason; load = context->modelLoadMS; [context->poolLock unlock]; }
    return @{ @"capture_ready":@(self.captureReady), @"interpolation_ready":@(self.interpolationReady), @"interpolation_enabled":@(self.interpolationEnabled), @"suspended":@(self.suspended), @"reason":reason,
        @"width":@(context ? context->width : 0), @"height":@(context ? context->height : 0), @"model_load_ms":@(load),
        @"captures":@(atomic_load(&_captures)), @"capture_errors":@(atomic_load(&_captureErrors)), @"native_only":@(atomic_load(&_nativeOnly)),
        @"generated_outputs":@(atomic_load(&_generated)), @"process_errors":@(atomic_load(&_processErrors)), @"pool_misses":@(atomic_load(&_poolMisses)),
        @"last_copy_ms":@(atomic_load(&_lastCopyMS)), @"copy_total_ms":@(atomic_load(&_copyTotalMS)),
        @"last_process_ms":@(atomic_load(&_lastProcessMS)), @"process_total_ms":@(atomic_load(&_processTotalMS)),
        @"processing_in_flight":@(atomic_load(&_processingInFlight)), @"last_generated_rgb_ms":@(atomic_load(&_lastConversionMS)), @"generated_rgb_total_ms":@(atomic_load(&_conversionTotalMS)),
        @"present_submissions":@(atomic_load(&_presentSubmissions)), @"actual_presents":@(atomic_load(&_actualPresents)), @"actual_generated_presents":@(atomic_load(&_actualGenerated)),
        @"last_presented_time":@(atomic_load(&_lastPresentTime)), @"history_resets":@(atomic_load(&_resets)),
        @"allocated_source_surfaces":@(atomic_load(&_budget->sourceCount)), @"allocated_midpoint_surfaces":@(atomic_load(&_budget->midpointCount)) };
}
@end
