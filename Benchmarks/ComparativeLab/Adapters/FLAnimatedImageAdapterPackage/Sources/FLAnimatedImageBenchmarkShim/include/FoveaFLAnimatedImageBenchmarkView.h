#import <FLAnimatedImageView.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^FoveaFLAnimatedImageFrameDisplayBlock)(UIImage *frame);

/// Comparator-only public-API shim. It observes the actual layer-display callback without
/// declaring FLAnimatedImageView private properties or adding an independent display link.
@interface FoveaFLAnimatedImageBenchmarkView : FLAnimatedImageView
@property (nonatomic, copy, nullable) FoveaFLAnimatedImageFrameDisplayBlock frameDisplayBlock;
@end

NS_ASSUME_NONNULL_END
