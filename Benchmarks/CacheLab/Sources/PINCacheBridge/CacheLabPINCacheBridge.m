#import "CacheLabPINCacheBridge.h"
#import <PINCache/PINCache.h>
#import <PINOperation/PINOperationQueue.h>

@interface CacheLabPINMemoryBridge ()
@property (nonatomic, strong) PINCache *owner;
@property (nonatomic, strong) NSMutableSet<NSString *> *keys;
@property (nonatomic, strong) NSLock *keysLock;
@end

@implementation CacheLabPINMemoryBridge
- (instancetype)initWithRootPath:(NSString *)rootPath costLimit:(NSUInteger)costLimit {
    self = [super init];
    if (self) {
        _owner = [[PINCache alloc] initWithName:[NSString stringWithFormat:@"FoveaCacheLab-%@", NSUUID.UUID.UUIDString]
                                       rootPath:rootPath];
        _owner.memoryCache.costLimit = costLimit;
        _owner.memoryCache.removeAllObjectsOnMemoryWarning = NO;
        _owner.memoryCache.removeAllObjectsOnEnteringBackground = NO;
        _keys = [NSMutableSet set];
        _keysLock = [[NSLock alloc] init];
    }
    return self;
}

- (NSData *)dataForKey:(NSString *)key {
    id value = [self.owner.memoryCache objectForKey:key];
    return [value isKindOfClass:NSData.class] ? value : nil;
}

- (void)setData:(NSData *)data forKey:(NSString *)key cost:(NSUInteger)cost {
    [self.owner.memoryCache setObject:data forKey:key withCost:cost];
    [self.keysLock lock];
    [self.keys addObject:key];
    [self.keysLock unlock];
}

- (void)removeDataForKey:(NSString *)key {
    [self.owner.memoryCache removeObjectForKey:key];
    [self.keysLock lock];
    [self.keys removeObject:key];
    [self.keysLock unlock];
}

- (void)removeAllData {
    [self.owner.memoryCache removeAllObjects];
    [self.keysLock lock];
    [self.keys removeAllObjects];
    [self.keysLock unlock];
}

- (NSUInteger)count {
    [self.keysLock lock];
    NSUInteger result = self.keys.count;
    [self.keysLock unlock];
    return result;
}

- (NSUInteger)totalCost {
    return self.owner.memoryCache.totalCost;
}
@end

@interface CacheLabPINDiskBridge ()
@property (nonatomic, strong) PINDiskCache *cache;
@property (nonatomic, strong) PINOperationQueue *operationQueue;
@property (nonatomic) NSUInteger mutableReadExceptionCount;
@end

@implementation CacheLabPINDiskBridge
- (instancetype)initWithRootPath:(NSString *)rootPath name:(NSString *)name {
    self = [super init];
    if (self) {
        _operationQueue = [[PINOperationQueue alloc] initWithMaxConcurrentOperations:10];
        _cache = [[PINDiskCache alloc] initWithName:name
                                             prefix:@"dev.fovea.CacheLabPINDiskCache"
                                           rootPath:rootPath
                                         serializer:nil
                                       deserializer:nil
                                         keyEncoder:nil
                                         keyDecoder:nil
                                     operationQueue:_operationQueue
                                           ttlCache:NO
                                          byteLimit:512 * 1024 * 1024
                                           ageLimit:0
                                   evictionStrategy:PINCacheEvictionStrategyLeastRecentlyUsed];
    }
    return self;
}

- (NSData *)dataForKey:(NSString *)key {
    @try {
        id value = [self.cache objectForKey:key];
        return [value isKindOfClass:NSData.class] ? value : nil;
    } @catch (NSException *exception) {
        self.mutableReadExceptionCount += 1;
        return nil;
    }
}

- (void)setData:(NSData *)data forKey:(NSString *)key {
    [self.cache setObject:data forKey:key];
}

- (void)removeDataForKey:(NSString *)key {
    [self.cache removeObjectForKey:key];
}

- (void)removeAllData {
    [self.operationQueue waitUntilAllOperationsAreFinished];
    [self.cache removeAllObjects];
    [self.operationQueue waitUntilAllOperationsAreFinished];
}

- (void)drainPendingOperations {
    [self.operationQueue waitUntilAllOperationsAreFinished];
}

- (NSURL *)fileURLForKey:(NSString *)key {
    return [self.cache fileURLForKey:key];
}

- (NSUInteger)readExceptionCount {
    return self.mutableReadExceptionCount;
}

- (NSUInteger)byteCount {
    __block NSUInteger result = 0;
    [self.cache synchronouslyLockFileAccessWhileExecutingBlock:^(PINDiskCache *cache) {
        result = cache.byteCount;
    }];
    return result;
}
@end
