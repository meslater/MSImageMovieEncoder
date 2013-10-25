//
//  MSImageMovieEncoder.h
//
//  Created by Michael Slater (www.michaelslater.net) on 17/02/2011.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

@class MSImageMovieEncoder;

/** This protocol has 3 methods you must implement and a choice of 2 more, you must implement 1 of these optional methods for the class to function. */
@protocol MSImageMovieEncoderFrameProvider <NSObject>

//Information methods should all be implemented so you know what is going on.
-(void)movieEncoder:(MSImageMovieEncoder *)movieEncoder didFailWithReason:(NSString*)reason;
-(void)movieEncoderDidFinishAddingFrames:(MSImageMovieEncoder *)movieEncoder;
-(void)movieEncoderDidFinishEncoding:(MSImageMovieEncoder *)movieEncoder;

@optional
//Just implement one of these methods - we check when we start requesting frames which one you've implemented
//yes this adds a few instructions to requesting each frame but in the grand scheme of what's going on it's insignificant
//and very convenient...

/** Provides the delegate with a pointer to the CVPixelBuffer into which the frame should be drawn.
 
 I recommend using -(BOOL)nextFrameInBGRCGBitmapContext:(CGContextRef*)contextRef if you want a bitmap context */
-(BOOL)nextFrameInCVPixelBuffer:(CVPixelBufferRef*)pixelBuf;

/** If you are going to be generating bitmap contexts anyway I recommend using this.
 
 The only real optimisation is that it doesn't generate a colorSpace every frame, it caches it.  It just means you don't have to think about memory. 
 */
-(BOOL)nextFrameInBGRCGBitmapContext:(CGContextRef*)contextRef;

@end

typedef NS_ENUM(NSInteger, MSMovieEncoderMode) {
	MSMovieEncoderBGRCGBitmapContextModeMode,
	MSMovieEncoderCVPixelBufferMode,
};

/** This class provides a simple way of generating a movie from a series of 'images' (CVPixelBufferRefs or CGContextRefs).
 
 Simply implement the 3 status methods and 1 (ONE and only ONE) of the optional frame provider methods.
 
 Init a new instance of this class, set the delegate to wherever you've implemented the apropriate delegate methods and call -(void)startRequestingFrames.
 
 Your frame provider method will be handed a pointer to either a CVPixelBufferRef or a CGContextRef (depending on which you've implemented).  Fill the bitmap or buffer and return a BOOL to say if you've filled it.
 
 As soon as you return NO the the movie encoding is finished and written to disk.
 
 A simple frame provider class might look like this: (note that if you are providing frames from the class you declared the movie encoder in you can get the frame size directly from the encoder when you need it.)
 
 CGSize frameSize;
 int counter;
 
 -(id)init {
	 if (self = [super init]) {
		 counter = 0;
		 frameSize = CGSizeMake(1280, 720);
	 }
	 return self;
 }
 
 -(BOOL)drawNextAnimationFrameInContext:(CGContextRef *)contextRef {
	 counter++;
	 if (counter == 100) {
		 return NO;
	 }
	 CGContextRef context = *contextRef;
	 
	 CGContextSetRGBFillColor(context, 0,0,1,1); //RED
	 CGContextFillRect(context, CGRectMake(0, 0, frameSize.width, frameSize.height));
	 
	 CGContextSetRGBFillColor(context, 1,0,0,0.5); //BLUE with alpha of 0.5
	 CGContextFillEllipseInRect(context, CGRectMake(1*counter, 200, 1*counter, 1*counter));
	 return YES;
 }
 
 -(void)movieEncoderDidFinishAddingFrames {
	//all that's left is the remaining compression (very quick)
	NSLog(@"All frames added");
 }
 
 -(void)movieEncoderDidFinishEncoding {
	//it's actually finished now, you can release it, if you like you can ask for the fileURL first so you know where the movie went
	NSLog(@"Movie written to disk");
 }
 
 -(void)movieEncoderDidFailWithReason:(NSString *)reason {
	//it's failed.  It's in an unpredictable state, the movie may exist but it's probably garbage if it does.
	NSLog(@"%@", reason);
 }
 
 
 This class offers insanely good performance (through trial and error).  The key is that the assetWriter is writing in BGRA format.  Encoding 500 720p H264 frames in RGBA takes about 3 minutes.
 Encoding the same in BGRA takes under 30 seconds.  Why?  I have no idea, presumably the HW encoder is BGRA and everything else has to be manually rotated in the CPU (weird).

 Note that to set a colour in this context you should use:

 CGContextSetRGBFillColor(context, BLUE,GREEN,RED,ALPHA); (The colours are in reverse order, the alpha is in the same place)

 ie. CGContextSetRGBFillColor(context, 0,0,1.0,0.5); is 100% red with a 50% alpha.

 For this slight annoyance of backwards colour declaration you get a 7x performance increase. */

@class AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor;

@interface MSImageMovieEncoder : NSObject

+(BOOL)deviceSupportsVideoEncoding;
+(CGSize)maximumFrameSize;

/** fURL MUST be a fileURL, fSize is the video frame size and the size of the buffers you will be handed (ie CGSizeMake(1280,720), fDuration is the length of each frame */
+(id)pixelBufferMovieEncoderWithURL:(NSURL*)fURL andFrameSize:(CGSize)fSize andFrameDuration:(CMTime)fDuration;
-(id)initWithURL:(NSURL*)fURL andFrameSize:(CGSize)fSize andFrameDuration:(CMTime)fDuration;

//call this after you have set the delgate.  Calling while the delegate is nil will have no effect
-(void)startRequestingFrames;

@property (nonatomic, assign, readonly) CGSize frameSize; /**< The size of the video frame (ie. 1280x720) */
@property (nonatomic, assign, readonly) CMTime frameDuration; /**< The required duration of each still image.  ie. CMTimeMake(1, 25) would be 1/25th of a second (PAL) */
@property (nonatomic, strong, readonly) NSURL* fileURL; /**< The fileURL of the video, readonly as it cannot me changed after the writer is initialised. */
@property (nonatomic, weak) id<MSImageMovieEncoderFrameProvider> frameDelegate; /**< The delegate providing frames */

@end