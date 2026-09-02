#import "FoveaFLAnimatedImageBenchmarkView.h"

@implementation FoveaFLAnimatedImageBenchmarkView

- (void)displayLayer:(CALayer *)layer
{
    [super displayLayer:layer];
    UIImage *frame = self.currentFrame;
    FoveaFLAnimatedImageFrameDisplayBlock block = self.frameDisplayBlock;
    if (frame != nil && block != nil) {
        block(frame);
    }
}

@end
