//
//  MUImageIconCache.m
//  ZPWIM_Example
//
//  Created by Jekity on 2018/7/30.
//  Copyright © 2018年 392071745@qq.com. All rights reserved.
//

#import "MUImageIconCache.h"
#import "MUImageDataFileManager.h"
#import "MUImageEncoder.h"
#import "MUImageDecoder.h"
#import "MUImageRetrieveOperation.h"

static NSString* kFlyImageKeyVersion = @"v";
static NSString* kFlyImageKeyFile = @"f";
static NSString* kFlyImageKeyImages = @"i";
static NSString* kFlyImageKeyFilePointer = @"p";

#define kImageInfoIndexWidth 0
#define kImageInfoIndexHeight 1
#define kImageInfoIndexOffset 2
#define kImageInfoIndexLength 3
#define kImageInfoCount 4

@interface MUImageIconCache ()
@property (nonatomic, strong) MUImageEncoder* encoder;
@property (nonatomic, strong) MUImageDecoder* decoder;
@property (nonatomic, strong) MUImageDataFile* dataFile;

@end

@implementation MUImageIconCache {
    NSRecursiveLock* _lock;
    NSString* _metaPath;
    
    NSMutableDictionary* _metas;
    NSMutableDictionary* _images;
    NSMutableDictionary* _addingImages;
    NSOperationQueue* _retrievingQueue;
}

+ (instancetype)sharedInstance
{
    static dispatch_once_t onceToken;
    static MUImageIconCache* __instance = nil;
    dispatch_once(&onceToken, ^{
        NSString *metaPath = [[MUImageCacheUtils directoryPath] stringByAppendingPathComponent:@"/__icons"];
        __instance = [[[self class] alloc] initWithMetaPath:metaPath];
    });
    
    return __instance;
}

- (instancetype)initWithMetaPath:(NSString*)metaPath
{
    if (self = [self init]) {
        
        _lock = [[NSRecursiveLock alloc] init];
        _addingImages = [[NSMutableDictionary alloc] init];
        _retrievingQueue = [NSOperationQueue new];
        _retrievingQueue.qualityOfService = NSQualityOfServiceUserInteractive;
        _retrievingQueue.maxConcurrentOperationCount = 6;
        
        _metaPath = [metaPath copy];
        NSString* folderPath = [[_metaPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"/files"];
        self.dataFileManager = [[MUImageDataFileManager alloc] initWithFolderPath:folderPath];
        [self loadMetadata];
        
        _decoder = [[MUImageDecoder alloc] init];
        _encoder = [[MUImageEncoder alloc] init];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onWillTerminate)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];
    }
    return self;
}

#pragma mark - LifeCircle
- (void)onWillTerminate
{
    // 取消内存映射
    _dataFile = nil;
    [_retrievingQueue cancelAllOperations];
}

- (void)dealloc
{
    _dataFile = nil;
    [_retrievingQueue cancelAllOperations];
}

#pragma mark - APIs
- (void)addImageWithKey:(NSString*)key
                   size:(CGSize)size
           drawingBlock:(MUImageCacheDrawingBlock)drawingBlock
              completed:(MUImageCacheRetrieveBlock)completed
{
    
    NSParameterAssert(key != nil);
    NSParameterAssert(drawingBlock != nil);
    
    if ([self isImageExistWithKey:key]) {
        [self asyncGetImageWithKey:key completed:completed];
        return;
    }
    
    size_t bytesToAppend = [MUImageEncoder dataLengthWithImageSize:size];
    [self doAddImageWithKey:key
                       size:size
                     offset:-1
                     length:bytesToAppend
               drawingBlock:drawingBlock
                  completed:completed];
}

- (void)doAddImageWithKey:(NSString*)key
                     size:(CGSize)size
                   offset:(size_t)offset
                   length:(size_t)length
             drawingBlock:(MUImageCacheDrawingBlock)drawingBlock
                completed:(MUImageCacheRetrieveBlock)completed
{
    
    NSParameterAssert(completed != nil);
    
    if (_dataFile == nil) {
        if (completed != nil) {
            completed(key, nil ,nil);
        }
        return;
    }
    
    if (completed != nil) {
        @synchronized(_addingImages)
        {
            if ([_addingImages objectForKey:key] == nil) {
                [_addingImages setObject:[NSMutableArray arrayWithObject:completed] forKey:key];
            } else {
                NSMutableArray* blocks = [_addingImages objectForKey:key];
                [blocks addObject:completed];
                return;
            }
        }
    }
    
    static dispatch_queue_t __drawingQueue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *name = [NSString stringWithFormat:@"com.MUImage.drawicon.%@", [[NSUUID UUID] UUIDString]];
        __drawingQueue = dispatch_queue_create([name cStringUsingEncoding:NSASCIIStringEncoding], NULL);
    });
    
    __weak typeof(self)weakSelf = self;
    // 使用dispatch_sync 代替 dispatch_async，防止大规模写入时出现异常
    dispatch_async(__drawingQueue, ^{
        
        size_t newOffset = offset == -1 ? (size_t)weakSelf.dataFile.pointer : offset;
        __block  BOOL success = NO;
        dispatch_main_sync_safe(^{
            if ( ![weakSelf.dataFile prepareAppendDataWithOffset:newOffset length:length] ) {
                [self afterAddImage:nil key:key  filePath:nil];
                return;
            }
            
            
            
            [weakSelf.encoder encodeWithImageSize:size bytes:weakSelf.dataFile.address + newOffset drawingBlock:drawingBlock];
           success = [weakSelf.dataFile appendDataWithOffset:newOffset length:length];
            if ( !success ) {
                // TODO: consider rollback
                [weakSelf afterAddImage:nil key:key filePath:nil];
                return;
            }
        });
        
        if (!success) {
            return ;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wimplicit-retain-self"
        // number of dataFile, width of image, height of image, offset, length
        @synchronized (_images) {
            NSArray *imageInfo = @[ @(size.width),
                                    @(size.height),
                                    @(newOffset),
                                    @(length) ];
            
            [_images setObject:imageInfo forKey:key];
        }
#pragma clang diagnostic pop
        // callback with image
        UIImage *image = [weakSelf.decoder iconImageWithBytes:weakSelf.dataFile.address
                                                       offset:newOffset
                                                       length:length
                                                     drawSize:size];
        if (!image) {
            [weakSelf afterAddImage:nil key:nil filePath:nil];
            return;
        }else{
            NSData* tempData = UIImagePNGRepresentation(image);
            if (tempData == nil) {//验证生成的图片是否损坏
                [weakSelf afterAddImage:nil key:nil filePath:nil];
                return;
            } else {
                [weakSelf afterAddImage:image key:key filePath:weakSelf.dataFile.filePath];
            }
        }
        
        // save meta
        [weakSelf saveMetadata];
    });
}

- (void)afterAddImage:(UIImage*)image key:(NSString*)key filePath:(NSString *)filePath
{
    NSArray* blocks = nil;
    @synchronized(_addingImages)
    {
        blocks = [[_addingImages objectForKey:key] copy];
        [_addingImages removeObjectForKey:key];
    }
    
    dispatch_main_async_safe(^{
        for ( MUImageCacheRetrieveBlock block in blocks) {
            block( key, image ,filePath);
        }
    });
}

- (void)replaceImageWithKey:(NSString*)key
               drawingBlock:(MUImageCacheDrawingBlock)drawingBlock
                  completed:(MUImageCacheRetrieveBlock)completed
{
    
    NSParameterAssert(key != nil);
    NSParameterAssert(drawingBlock != nil);
    
    id imageInfo = nil;
    @synchronized(_images)
    {
        imageInfo = _images[key];
    }
    if (imageInfo == nil) {
        if (completed != nil) {
            completed(key, nil ,nil);
        }
        return;
    }
    
    // width of image, height of image, offset, length
    CGFloat imageWidth = [[imageInfo objectAtIndex:kImageInfoIndexWidth] floatValue];
    CGFloat imageHeight = [[imageInfo objectAtIndex:kImageInfoIndexHeight] floatValue];
    size_t imageOffset = [[imageInfo objectAtIndex:kImageInfoIndexOffset] unsignedLongValue];
    size_t imageLength = [[imageInfo objectAtIndex:kImageInfoIndexLength] unsignedLongValue];
    
    CGSize size = CGSizeMake(imageWidth, imageHeight);
    
    
    
    
    [self doAddImageWithKey:key
                       size:size
                     offset:imageOffset
                     length:imageLength
               drawingBlock:drawingBlock
                  completed:completed];
    
}

- (void)removeImageWithKey:(NSString*)key
{
    @synchronized(_images)
    {
        [_images removeObjectForKey:key];
    }
}

- (void)changeImageKey:(NSString*)oldKey newKey:(NSString*)newKey
{
    @synchronized(_images)
    {
        
        id imageInfo = [_images objectForKey:oldKey];
        if (imageInfo == nil) {
            return;
        }
        
        [_images setObject:imageInfo forKey:newKey];
        [_images removeObjectForKey:oldKey];
    }
}

- (BOOL)isImageExistWithKey:(NSString*)key
{
    @synchronized(_images)
    {
        return [_images objectForKey:key] != nil;
    }
}

- (void)asyncGetImageWithKey:(NSString*)key completed:(MUImageCacheRetrieveBlock)completed
{
    NSParameterAssert(key != nil);
    NSParameterAssert(completed != nil);
    
    if (_dataFile == nil) {
        completed(key, nil ,nil);
        return;
    }
    
    NSArray* imageInfo;
    @synchronized(_images)
    {
        imageInfo = _images[key];
    }
    
    if (imageInfo == nil || [imageInfo count] < kImageInfoCount) {
        completed(key, nil ,nil);
        return;
    }
    
    // width of image, height of image, offset, length
    CGFloat imageWidth = [[imageInfo objectAtIndex:kImageInfoIndexWidth] floatValue];
    CGFloat imageHeight = [[imageInfo objectAtIndex:kImageInfoIndexHeight] floatValue];
    size_t imageOffset = [[imageInfo objectAtIndex:kImageInfoIndexOffset] unsignedLongValue];
    size_t imageLength = [[imageInfo objectAtIndex:kImageInfoIndexLength] unsignedLongValue];
    
    __weak __typeof__(self) weakSelf = self;
    MUImageRetrieveOperation* operation = [[MUImageRetrieveOperation alloc] initWithRetrieveBlock:^UIImage * {
        return [weakSelf.decoder iconImageWithBytes:weakSelf.dataFile.address
                                             offset:imageOffset
                                             length:imageLength
                                           drawSize:CGSizeMake(imageWidth, imageHeight)];
        
    }];
    operation.name = key;
    operation.filePath = _dataFile.filePath;
    [operation addBlock:completed];
    [_retrievingQueue addOperation:operation];
}

- (void)cancelGetImageWithKey:(NSString*)key
{
    NSParameterAssert(key != nil);
    
    for (MUImageRetrieveOperation* operation in _retrievingQueue.operations) {
        if (!operation.cancelled && !operation.finished && [operation.name isEqualToString:key]) {
            [operation cancel];
            return;
        }
    }
}

- (void)purge
{
    [self removeImages];
    
    _dataFile = nil;
    NSString* fileName = [_metas objectForKey:kFlyImageKeyFile];
    if (fileName != nil) {
        [self.dataFileManager removeFileWithName:fileName];
        [self createDataFile:fileName];
    }
    
    [self saveMetadata];
}

- (void)removeImages
{
    @synchronized(_images)
    {
        [_images removeAllObjects];
    }
    
    [_retrievingQueue cancelAllOperations];
    
    @synchronized(_addingImages)
    {
        for (NSString* key in _addingImages) {
            NSArray* blocks = [_addingImages objectForKey:key];
            dispatch_main_async_safe(^{
                for ( MUImageCacheRetrieveBlock block in blocks) {
                    block( key, nil ,nil);
                }
            });
        }
        
        [_addingImages removeAllObjects];
    }
}

#pragma mark - Working with Metadata
- (void)saveMetadata
{
    static dispatch_queue_t __metadataQueue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *name = [NSString stringWithFormat:@"com.MUImage.iconmeta.%@", [[NSUUID UUID] UUIDString]];
        __metadataQueue = dispatch_queue_create([name cStringUsingEncoding:NSASCIIStringEncoding], NULL);
    });
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wimplicit-retain-self"
    dispatch_async(__metadataQueue, ^{
        [_lock lock];
        
        NSMutableDictionary *tempMetas = [_metas mutableCopy];
        if (tempMetas.allKeys.count > 0) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:tempMetas options:kNilOptions error:NULL];
            BOOL fileWriteResult = [data writeToFile:_metaPath atomically:YES];//atomically要设置为YES，避免多次写入时carsh
            if (fileWriteResult == NO) {
                MUImageErrorLog(@"couldn't save metadata");
            }
        }
        
        
        [_lock unlock];
    });
    
#pragma clang diagnostic pop
}

- (void)loadMetadata
{
    // load content from index file
    NSError* error;
    NSData* metadataData = [NSData dataWithContentsOfURL:[NSURL fileURLWithPath:_metaPath] options:NSDataReadingMappedAlways error:&error];
    if (error != nil || metadataData == nil) {
        [self createMetadata];
        return;
    }
    
    NSDictionary* parsedObject = (NSDictionary*)[NSJSONSerialization JSONObjectWithData:metadataData options:kNilOptions error:&error];
    if (error != nil || parsedObject == nil) {
        [self createMetadata];
        return;
    }
    
    // 客户端升级后，图标极有可能发生变化，为了适应这种变化，自动清理本地缓存，所有图标都重新生成
    NSString* lastVersion = [parsedObject objectForKey:kFlyImageKeyVersion];
    NSString* currentVersion = [MUImageCacheUtils clientVersion];
    if (lastVersion != nil && ![lastVersion isEqualToString:currentVersion]) {
        [self purge];
        [self createMetadata];
        return;
    }
    
    // load infos
    _metas = [NSMutableDictionary dictionaryWithDictionary:parsedObject];
    
    _images = [NSMutableDictionary dictionaryWithDictionary:[_metas objectForKey:kFlyImageKeyImages]];
    [_metas setObject:_images forKey:kFlyImageKeyImages];
    
    NSString* fileName = [_metas objectForKey:kFlyImageKeyFile];
    [self createDataFile:fileName];
}

- (void)createMetadata
{
    _metas = [NSMutableDictionary dictionaryWithCapacity:100];
    
    // 记录当前版本号
    NSString* currentVersion = [MUImageCacheUtils clientVersion];
    if (currentVersion != nil) {
        [_metas setObject:currentVersion forKey:kFlyImageKeyVersion];
    }
    
    // images
    _images = [NSMutableDictionary dictionary];
    [_metas setObject:_images forKey:kFlyImageKeyImages];
    
    // file
    NSString* fileName = [[NSUUID UUID] UUIDString];
    [_metas setObject:fileName forKey:kFlyImageKeyFile];
    
    [self createDataFile:fileName];
}

- (void)createDataFile:(NSString*)fileName
{
    _dataFile = [self.dataFileManager createFileWithName:fileName];
    _dataFile.step = [MUImageCacheUtils pageSize] * 128; // 512KB
    [_dataFile open];
}
@end
