#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CacheLabPINMemoryBridge : NSObject
- (instancetype)initWithRootPath:(NSString *)rootPath costLimit:(NSUInteger)costLimit;
- (nullable NSData *)dataForKey:(NSString *)key;
- (void)setData:(NSData *)data forKey:(NSString *)key cost:(NSUInteger)cost;
- (void)removeDataForKey:(NSString *)key;
- (void)removeAllData;
@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic, readonly) NSUInteger totalCost;
@end

@interface CacheLabPINDiskBridge : NSObject
- (instancetype)initWithRootPath:(NSString *)rootPath name:(NSString *)name;
- (nullable NSData *)dataForKey:(NSString *)key;
- (void)setData:(NSData *)data forKey:(NSString *)key;
- (void)removeDataForKey:(NSString *)key;
- (void)removeAllData;
- (void)drainPendingOperations;
- (nullable NSURL *)fileURLForKey:(NSString *)key;
@property (nonatomic, readonly) NSUInteger byteCount;
@property (nonatomic, readonly) NSUInteger readExceptionCount;
@end

NS_ASSUME_NONNULL_END
