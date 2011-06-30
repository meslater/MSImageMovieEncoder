MSImageMovieEncoder
-------------------

This class provides a simple way of generating a movie from a series of 'images' (CVPixelBufferRefs or CGContextRefs).

You will need to include the CoreGraphics, AVFoundation, CoreMedia and CoreVideo frameworks in your project.  Remember to weak link (called 'optional' now) AVFoundation, CoreMedia and CoreVideo if you are supporting 3.x devices.  Call the class method +(BOOL)deviceSupportsVideoEncoding to determine if this class will work at all.  It checks both the availability of the appropriate classes and of the required hardware (by way of checking available presets).

Simply implement the 3 status methods and 1 (ONE and only ONE) of the optional frame provider methods.
 
Init a new instance of this class, set the delegate to wherever you've implemented the appropriate delegate methods and call -(void)startRequestingFrames.
 
Your frame provider method will be handed a pointer to either a CVPixelBufferRef or a CGContextRef (depending on which you've implemented).  Fill the bitmap or buffer and return a BOOL to say if you've filled it.
 
As soon as you return NO the movie encoding is finished and written to disk.


Initialising the Encoder
------------------------

Using the class method you can get an auto-released instance however I would recommend alloc init'ing it and releasing it when you receive the call telling you it's done encoding in your delegate.  Just a bit neater.  Remember to check if video encoding is available on the device first with +(BOOL)deviceSupportsVideoEncoding.  No further checks will be done by the class, it'll just crash and burn.

	-(id)initWithURL:(NSURL*)fURL andFrameSize:(CGSize)fSize andFrameDuration:(CMTime)fDuration;

You need to pass 3 things:

1. fURL is a fileURL.  No spaces

	NSURL* fURL = [NSURL fileURLWithPath:vid];

2. fSize is the frame size ie. 640x480, 1280x720 - Use +(CGSize)maximumFrameSize to get the maximum resolution the device is capable of encoding.

	CGSizeMake(1280, 720);

3. fDuration is the length of each frame.  This is a constant.  The asset writer starts doing very strange things if you ess with frame timings.  That's why the property is readonly.

	CMTimeMake(1, 30); //30fps
	CMTimeMake(1, 25); //25fps
	
Then you need to set the delegate.
	
	myMovieWriter.frameDelegate = myClassWhichImplemetsTheProtocol;
	
Then call startRequestingFrames

	[myMovieWriter startRequestingFrames];
	
That's it - the encoder will request frames until you return NO, at which point it will finish up, tidy up and then let you know.  Don't call start more than once it just won't work.  Release the instance and start again.
	

Example of Frame Provider Delegate
----------------------------------

A simple frame provider class might look like this: (note that if you are providing frames from the class you declared the movie encoder in you can get the frame size directly from the encoder when you need it rather than storing it twice)
 
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
 
Performance and Pixel Format
----------------------------

This class offers insanely good performance (through trial and error).  The key is that the assetWriter is writing in BGRA format.  Drawing and encoding 500 720p H264 frames with the assetWriter configured in RGBA takes about 3 minutes.  Drawing and encoding the same in BGRA takes under 30 seconds (iPhone 4 and iPad).  Why?  I have no idea, presumably the HW encoder is BGRA and everything else has to be manually rotated in the CPU (weird).  YMMV of course.

Note that to set a colour in this context you should use:

CGContextSetRGBFillColor(context, BLUE,GREEN,RED,ALPHA); (The colours are in reverse order, the alpha is in the same place)

	CGContextSetRGBFillColor(context, 0,0,1.0,0.5);

This is 100% red with a 50% alpha.

A small price to pay for such a huge speed increase.