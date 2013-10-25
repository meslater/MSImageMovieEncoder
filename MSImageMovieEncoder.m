//
//  MSImageMovieEncoder.m
//
//  Created by Michael Slater (www.michaelslater.net) on 17/02/2011.
//

#import "MSImageMovieEncoder.h"
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>

static BOOL checkedForFrameSize = NO;
static CGSize maxFrameSize;

@interface MSImageMovieEncoder ()

@property (nonatomic, assign, readwrite) CGSize frameSize;
@property (nonatomic, assign, readwrite) CMTime frameDuration;
@property (nonatomic, strong, readwrite) NSURL* fileURL;

@property (nonatomic, assign) CMTime currentTime; //the current frame timing
@property (nonatomic, strong) AVAssetWriter* assetWriter;
@property (nonatomic, strong) AVAssetWriterInput* assetWriterInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor* pixelBufferAdaptor;
@property (nonatomic, assign) MSMovieEncoderMode mode;
@property (nonatomic, assign) CGColorSpaceRef rgbColorSpace; //if we're making bitmapContexts keep this for the duration

@end

@implementation MSImageMovieEncoder

+(BOOL)_softwareAvailable {
    //if the required AV Foundation classes are not present we don't stand a chance.
    Class assetWriter = NSClassFromString(@"AVAssetWriter");
    return assetWriter == nil ? NO : YES;
}

+(BOOL)deviceSupportsVideoEncoding {
    if ([MSImageMovieEncoder _softwareAvailable]) {
        //If the maximum frame size is 0,0 then the required hardware is not present
        return !CGSizeEqualToSize(CGSizeMake(0, 0), [MSImageMovieEncoder maximumFrameSize]);
    }
    return NO;
}

+(CGSize)maximumFrameSize {
    //If there is a better way of determining the max video resolution I'd love to know what it is...
    //No point in doing this more than once so we remember the last result.
    if (!checkedForFrameSize) {
        int frameWidth = 0;
        int frameHeight = 0;
        if ([MSImageMovieEncoder _softwareAvailable]) {
            NSArray* availablePresents = [AVAssetExportSession allExportPresets];
            NSString *regex = @"AVAssetExportPreset\\d+x\\d+";
            for (NSString* preset in availablePresents) {
                NSPredicate *pred = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", regex];
                if ([pred evaluateWithObject:preset])
                {
                    //Chop the front off to leave just the resolution as text
                    NSString *presetCut = [preset substringFromIndex:19];
                    //split the res into height and width
                    NSArray* heightAndWidth = [presetCut componentsSeparatedByString:@"x"];
                    int testWidth = [[heightAndWidth objectAtIndex:0] intValue];
                    if (testWidth > frameWidth) {
                        frameWidth = testWidth;
                        frameHeight = [[heightAndWidth objectAtIndex:1] intValue];
                    }
                }
            }
            NSLog(@"%@", availablePresents);
            NSLog(@"%d, %d", frameWidth, frameHeight);
        }
        maxFrameSize = CGSizeMake(frameWidth, frameHeight);
        checkedForFrameSize = YES;
    }
    return maxFrameSize;
}

/** Initialise an auto-released movie encoder */
+(id)pixelBufferMovieEncoderWithURL:(NSURL *)fURL andFrameSize:(CGSize)fSize andFrameDuration:(CMTime)fDuration {
	return [[MSImageMovieEncoder alloc] initWithURL:fURL andFrameSize:fSize andFrameDuration:fDuration];
}

-(id)initWithURL:(NSURL *)fURL andFrameSize:(CGSize)fSize andFrameDuration:(CMTime)fDuration {
	if ((self = [super init])) {
		_frameSize = fSize;
		_frameDuration = fDuration;
		_fileURL = fURL;
		[self _initialiseWriterWithURL:self.fileURL];
	}
	return self;
}

-(void)_initialiseWriterWithURL:(NSURL*)videoLocation {
	NSError *error = nil;
	self.currentTime = kCMTimeZero; //set time to 0 when we begin
	self.assetWriter = [[AVAssetWriter alloc] initWithURL:videoLocation
                                                 fileType:AVFileTypeAppleM4V
                                                    error:&error];
	
	if(error) {
		if ([self.frameDelegate respondsToSelector:@selector(movieEncoderDidFailWithReason:)]) {
			[self.frameDelegate movieEncoder:self didFailWithReason:[NSString stringWithFormat:@"Initialisation of movie encoder failed, assetWriter has error: %@", error]];
		}
    }
	
	NSDictionary *videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
								   AVVideoCodecH264, AVVideoCodecKey,
								   [NSNumber numberWithFloat:self.frameSize.width], AVVideoWidthKey,
								   [NSNumber numberWithInt:self.frameSize.height], AVVideoHeightKey,
								   nil];
	self.assetWriterInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
	self.assetWriterInput.expectsMediaDataInRealTime = NO; //this is the default, here for clarity
	
	[_assetWriter addInput:_assetWriterInput];
	
	int local_bytesPerRow = self.frameSize.width * 4;
	
	NSDictionary *pixelBufferOptions = [[NSDictionary alloc] initWithObjectsAndKeys:
										[NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey, //BGRA is SERIOUSLY BLOODY QUICK!
										//kCFBooleanTrue, kCVPixelBufferCGImageCompatibilityKey,
										kCFBooleanTrue, kCVPixelBufferCGBitmapContextCompatibilityKey,
										[NSNumber numberWithInt:local_bytesPerRow], kCVPixelBufferBytesPerRowAlignmentKey,
										[NSNumber numberWithInt:self.frameSize.width], kCVPixelBufferWidthKey,
										[NSNumber numberWithInt:self.frameSize.height], kCVPixelBufferHeightKey,
										/* this doesn't work for the default allocator which is NULL itself */
										//(CFAllocatorRef)kCFAllocatorSystemDefault, kCVPixelBufferMemoryAllocatorKey,
										nil];
	
	self.pixelBufferAdaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:_assetWriterInput sourcePixelBufferAttributes:pixelBufferOptions];
}

/** This method starts the asset writer and sets the time to 0.  It then
 creates a dispatch queue on which it executes a block which requests
 frames from the frame delegate.  The delegate is passed a pointer to a CVPixelBuffer which it should
 draw in.  When the delegate no longer has any frames available it should set the bufer to NULL.
 This will cause the writer to finish writing, end the movie and begin compression.  Simple! */
-(void)startRequestingFrames {
	if (self.frameDelegate != nil) {
		if ([self.frameDelegate respondsToSelector:@selector(nextFrameInBGRCGBitmapContext:)]) {
			//prevents us from creating a colour space every time we produce a bitmap context.
			self.rgbColorSpace = CGColorSpaceCreateDeviceRGB();
			self.mode = MSMovieEncoderBGRCGBitmapContextModeMode;
		}
		else if ([self.frameDelegate respondsToSelector:@selector(nextFrameInCVPixelBuffer:)]) {
			self.mode = MSMovieEncoderCVPixelBufferMode;
		}
		//no use starting the whole thing up only to find the delegate doesn't exist.
		//rather than checking before each frame (unnecessary), just check now that the delegate implements the appropriate method.
	}
	else {
		return;
	}

	[_assetWriter startWriting];
	[_assetWriter startSessionAtSourceTime:kCMTimeZero];

	dispatch_queue_t queue = dispatch_queue_create("mscvpixelbuffer.framerequestqueue", NULL);
	[_assetWriterInput requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
        while ([_assetWriterInput isReadyForMoreMediaData])
        {
			//this will always be a pixelbuffer regardless of what we actually got handed,
			//requestFrameFromDelegate takes care of this for us.
			CVPixelBufferRef nextPixelBuffer = [self _requestFrameFromDelegate];
			
            if (nextPixelBuffer)
            {
                //if it can't be successfully appended let the delegate know and mark it as finished otherwise progress the time one frame
				if (![_pixelBufferAdaptor appendPixelBuffer:nextPixelBuffer withPresentationTime:_currentTime]) {
					if ([self.frameDelegate respondsToSelector:@selector(movieEncoderDidFailWithReason:)]) {
						dispatch_async(dispatch_get_main_queue(), ^{
                            [self.frameDelegate movieEncoder:self didFailWithReason:@"Bufer not appended successfully - Error compiling movie"];
                        });
					}
					[_assetWriterInput markAsFinished]; //since this one was unsuccessful we should bail... this prevents further calls from this block
					[self _encodeAndWriteToDisk];
				}
				else {
					//rather than notifying the delegate after every frame the operation can be assumed successful if you don't get a fail notification.
					self.currentTime = CMTimeAdd(_currentTime, _frameDuration); //progress frame to the end of the current frame
				}
				CVPixelBufferRelease(nextPixelBuffer);
			}
            else
            {
				if ([self.frameDelegate respondsToSelector:@selector(movieEncoderDidFinishAddingFrames)]) {
					dispatch_async(dispatch_get_main_queue(), ^{
                        [self.frameDelegate movieEncoderDidFinishAddingFrames:self];
                    });
				}
				//now we've added all of the frames we need to finish encoding and writing to disk
				[self _encodeAndWriteToDisk]; //this is blocking because it has the blocking finishWriting call in it. (doesn't matter)
                break;
            }
        }
    }];
}

-(void)_encodeAndWriteToDisk {
	if (_rgbColorSpace) {
		CGColorSpaceRelease(_rgbColorSpace);
		self.rgbColorSpace = NULL;
	}
    
    void(^successBlock)() = ^() {
        if ([self.frameDelegate respondsToSelector:@selector(movieEncoderDidFinishEncoding)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.frameDelegate movieEncoderDidFinishEncoding:self];
            });
        }
    };
    
    void(^failureBlock)() = ^() {
        if ([self.frameDelegate respondsToSelector:@selector(movieEncoderDidFailWithReason:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.frameDelegate movieEncoder:self didFailWithReason:[NSString stringWithFormat:@"Asset Writer could not write asset, returned with error: \n%@",
                                                                   [_assetWriter error]]];
            });
            
        }
    };
    
    
    if ([_assetWriter respondsToSelector:@selector(finishWritingWithCompletionHandler:)]) {
        [_assetWriter finishWritingWithCompletionHandler:^{
            if (_assetWriter.status != AVAssetWriterStatusFailed) {
                successBlock();
            } else {
                failureBlock();
            }
        }];
    } else {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        BOOL success = [_assetWriter finishWriting];
        #pragma clang diagnostic pop
        if (!success) {
            failureBlock();
        } else {
            successBlock();
        }
    }
}

/** This method efficiently allocates a pixel buffer and requests that the delegate fill it.  It can also produce
 a CGBitmapContext for you to save you some code / having to think about memory.
 
 Because these buffers are being efficiently reused you MUST draw the entire frame (every pixel)
 each time to avoid unexpected and unpredictable bits of other frames appearing.  The buffers are not reallocted
 they are generally just reused and they are not wiped.  */
-(CVPixelBufferRef)_requestFrameFromDelegate {
	//here we simply return a CVPixelBuffer and it is stuck to the end of the asset using the adaptor...
	//For maximum efficiency, you should create CVPixelBuffer objects for appendPixelBuffer:withPresentationTime: by using this pool with the CVPixelBufferPoolCreatePixelBuffer function.
	
	CVPixelBufferRef pixelBuffer = NULL;
	OSStatus err = CVPixelBufferPoolCreatePixelBuffer (kCFAllocatorDefault, _pixelBufferAdaptor.pixelBufferPool, &pixelBuffer);
	if (err) {
		if ([self.frameDelegate respondsToSelector:@selector(movieEncoderDidFailWithReason:)]) {
			dispatch_async(dispatch_get_main_queue(), ^{
                [self.frameDelegate movieEncoder:self didFailWithReason:[NSString stringWithFormat:@"CVPixelBufferPoolCreatePixelBuffer() failed with error %i", (int)err]];
            });
		}
	}
	
	BOOL success = NO;
	switch (_mode) {
		case MSMovieEncoderBGRCGBitmapContextModeMode: //make a bitmap context and get the delegate to draw in it
			if (pixelBuffer == NULL) {
				break;
			}
			
			CVPixelBufferLockBaseAddress(pixelBuffer, 0);
			void *pxdata = CVPixelBufferGetBaseAddress(pixelBuffer);
			if (pxdata == NULL) {
				return NO;
			}
			
			CGContextRef context = CGBitmapContextCreate(pxdata, _frameSize.width,
														 _frameSize.height, 8, 4*_frameSize.width, _rgbColorSpace,
														 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
			success = [self.frameDelegate nextFrameInBGRCGBitmapContext:&context];

			CGContextRelease(context);
			
			CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
			break;
		case MSMovieEncoderCVPixelBufferMode: //just pass a reference to the pixel buffer for the delegate to do with it what it likes
			success = [self.frameDelegate nextFrameInCVPixelBuffer:&pixelBuffer];
			break;
		default:
			break;
	}
	
	if (!success) {
		//the buffer won't be freed later (because it will never be appended) so do it here.
		CVPixelBufferRelease(pixelBuffer);
		pixelBuffer = NULL;
	}
	
	return pixelBuffer;
}

-(void)dealloc {
	if (_rgbColorSpace) {
		CGColorSpaceRelease(_rgbColorSpace);
	}
}

@end
