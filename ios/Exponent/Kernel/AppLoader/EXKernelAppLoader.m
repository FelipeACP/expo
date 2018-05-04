// Copyright 2015-present 650 Industries. All rights reserved.

#import "EXErrorRecoveryManager.h"
#import "EXFileDownloader.h"
#import "EXKernel.h"
#import "EXKernelAppFetcher.h"
#import "EXKernelAppFetcherDevelopmentMode.h"
#import "EXKernelAppFetcherCacheOnly.h"
#import "EXKernelAppFetcherWithTimeout.h"
#import "EXKernelAppLoader+Updates.h"
#import "EXKernelAppRecord.h"
#import "EXKernelAppRegistry.h"
#import "EXKernelLinkingManager.h"
#import "EXManifestResource.h"
#import "EXShellManager.h"

#import <React/RCTUtils.h>

NS_ASSUME_NONNULL_BEGIN

int EX_DEFAULT_TIMEOUT_LENGTH = 30000;
NSTimeInterval const kEXJSBundleTimeout = 60 * 5;

@interface EXKernelAppLoader ()

@property (nonatomic, strong) NSURL * _Nullable manifestUrl;
@property (nonatomic, strong) NSDictionary * _Nullable localManifest; // used by Home. TODO: ben: clean up
@property (nonatomic, strong) NSURL * _Nullable httpManifestUrl;

@property (nonatomic, strong) NSDictionary * _Nullable confirmedManifest; // manifest that is actually being used
@property (nonatomic, strong) NSDictionary * _Nullable cachedManifest; // manifest that is cached and we definitely have, may fall back to it

@property (nonatomic, strong) EXKernelAppFetcher * _Nullable appFetcher;
@property (nonatomic, strong) NSError * _Nullable error;

@property (nonatomic, assign) BOOL hasFinished;
@property (nonatomic, assign) BOOL shouldUseCacheOnly;

@end

@implementation EXKernelAppLoader

- (instancetype)initWithManifestUrl:(NSURL *)url
{
  if (self = [super init]) {
    _manifestUrl = url;
    _httpManifestUrl = [EXKernelAppLoader _httpUrlFromManifestUrl:_manifestUrl];
  }
  return self;
}

- (instancetype)initWithLocalManifest:(NSDictionary *)manifest
{
  if (self = [super init]) {
    _localManifest = manifest;
  }
  return self;
}

#pragma mark - getters and lifecycle

- (void)_reset
{
  _confirmedManifest = nil;
  _cachedManifest = nil;
  _error = nil;
  _appFetcher = nil;
  _hasFinished = NO;
  _shouldUseCacheOnly = NO;
}

- (EXKernelAppLoaderStatus)status
{
  if (_error || (_appFetcher && _appFetcher.error)) {
    return kEXKernelAppLoaderStatusError;
  } else if (_appFetcher && _appFetcher.bundle && _confirmedManifest) {
    return kEXKernelAppLoaderStatusHasManifestAndBundle;
  } else if (_cachedManifest || (_appFetcher && _appFetcher.manifest)) {
    return kEXKernelAppLoaderStatusHasManifest;
  }
  return kEXKernelAppLoaderStatusNew;
}

- (NSDictionary * _Nullable)manifest
{
  if (_confirmedManifest) {
    return _confirmedManifest;
  }
  // remote manifest
  if (_appFetcher && _appFetcher.manifest) {
    return _appFetcher.manifest;
  }
  if (_cachedManifest) {
    return _cachedManifest;
  }
  return nil;
}

- (NSData * _Nullable)bundle
{
  if (_appFetcher) {
    return _appFetcher.bundle;
  }
  return nil;
}

- (void)forceBundleReload
{
  if (self.status == kEXKernelAppLoaderStatusNew) {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"Tried to load a bundle from an AppLoader with no manifest."
                                 userInfo:@{}];
  }
  RCTAssert([_appFetcher isKindOfClass:[EXKernelAppFetcherDevelopmentMode class]], @"Tried to force a bundle reload on a non-development bundle");
  [(EXKernelAppFetcherDevelopmentMode *)_appFetcher forceBundleReload];
}

#pragma mark - public

- (void)request
{
  [self _reset];
  if (_localManifest) {
    [self _beginRequestWithLocalManifest];
  } else if (_manifestUrl) {
    [self _beginRequestWithRemoteManifest];
  } else {
    [self _finishWithError:RCTErrorWithMessage(@"Can't load app with no remote url nor local manifest.")];
  }
}

- (void)requestFromCache
{
  [self _reset];
  _shouldUseCacheOnly = YES;
  if (_localManifest) {
    [self _beginRequestWithLocalManifest];
  } else if (_manifestUrl) {
    [self _beginRequestWithRemoteManifest];
  } else {
    [self _finishWithError:RCTErrorWithMessage(@"Can't load app with no remote url nor local manifest.")];
  }
}

#pragma mark - internal

+ (NSURL *)_httpUrlFromManifestUrl:(NSURL *)url
{
  NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
  // keep https if it's already there, otherwise replace any other scheme with http
  if (!components.scheme || ![components.scheme isEqualToString:@"https"]) {
    components.scheme = @"http";
  }
  NSMutableString *path = [((components.path) ? components.path : @"") mutableCopy];
  path = [[EXKernelLinkingManager stringByRemovingDeepLink:path] mutableCopy];
  if (path.length == 0 || [path characterAtIndex:path.length - 1] != '/') {
    [path appendString:@"/"];
  }
  [path appendString:@"index.exp"];
  components.path = path;
  return [components URL];
}

- (void)_beginRequestWithLocalManifest
{
  _confirmedManifest = _localManifest;
  _cachedManifest = _localManifest;
  [self _fetchCachedManifest];
}

- (void)_beginRequestWithRemoteManifest
{
  // if we're in dev mode, don't try loading cached manifest
  if ([_httpManifestUrl.host isEqualToString:@"localhost"] || ([EXShellManager sharedInstance].isShell && [EXShellManager sharedInstance].isLocalDetach)) {
    // we can't pre-detect if this person is using a developer tool, but using localhost is a pretty solid indicator.
    [self _startAppFetcher:[[EXKernelAppFetcherDevelopmentMode alloc] initWithAppLoader:self]];
  } else {
    [self _fetchCachedManifest];
  }
}

- (void)_fetchCachedManifest
{
  [self fetchManifestWithCacheBehavior:EXCachedResourceOnlyCache success:^(NSDictionary * cachedManifest) {
    _cachedManifest = cachedManifest;
    [self _fetchBundleWithManifest:cachedManifest];
  } failure:^(NSError * error) {
    [self _startAppFetcher:[[EXKernelAppFetcherWithTimeout alloc] initWithAppLoader:self timeoutLengthInMs:EX_DEFAULT_TIMEOUT_LENGTH]];
  }];
}

- (void)_fetchBundleWithManifest:(NSDictionary *)manifest
{
  BOOL shouldCheckForUpdate = YES;
  int fallbackToCacheTimeout = EX_DEFAULT_TIMEOUT_LENGTH;

  // in case check for dev mode failed before, check again
  if ([EXKernelAppFetcher areDevToolsEnabledWithManifest:manifest]) {
    [self _startAppFetcher:[[EXKernelAppFetcherDevelopmentMode alloc] initWithAppLoader:self]];
    return;
  }

  id updates = manifest[@"updates"];
  id ios = manifest[@"ios"];
  if (updates && [updates isKindOfClass:[NSDictionary class]]) {
    NSDictionary *updatesDict = (NSDictionary *)updates;
    id checkAutomaticallyVal = updatesDict[@"checkAutomatically"];
    if (checkAutomaticallyVal && [checkAutomaticallyVal isKindOfClass:[NSString class]] && [(NSString *)checkAutomaticallyVal isEqualToString:@"ON_ERROR_RECOVERY"]) {
      shouldCheckForUpdate = NO;
    }

    id fallbackToCacheTimeoutVal = updatesDict[@"fallbackToCacheTimeout"];
    if (fallbackToCacheTimeoutVal && [fallbackToCacheTimeoutVal isKindOfClass:[NSNumber class]]) {
      fallbackToCacheTimeout = [(NSNumber *)fallbackToCacheTimeoutVal intValue];
    }
  } else if (ios && [ios isKindOfClass:[NSDictionary class]]) {
    NSDictionary *iosDict = (NSDictionary *)ios;
    // map loadJSInBackgroundExperimental internally to
    // checkAutomatically: ON_LOAD and fallbackToCacheTimeout: 0
    if (iosDict[@"loadJSInBackgroundExperimental"]) {
      shouldCheckForUpdate = YES;
      fallbackToCacheTimeout = 0;
    }
  }

  // only support checkAutomatically: ON_ERROR_RECOVERY in shell & detached apps
  if (![EXKernel sharedInstance].appRegistry.standaloneAppRecord) {
    shouldCheckForUpdate = YES;
  }

  // if this experience id encountered a loading error before,
  // we should always check for an update, even if the manifest says not to
  if ([[EXKernel sharedInstance].serviceRegistry.errorRecoveryManager experienceIdIsRecoveringFromError:[EXKernelAppFetcher experienceIdWithManifest:manifest]]) {
    shouldCheckForUpdate = YES;
  }

  // if remote updates are disabled, or we're using `reloadFromCache`, don't check for an update.
  // these checks need to be here because they need to happen after the dev mode check above.
  if (_shouldUseCacheOnly || ([EXShellManager sharedInstance].isShell && ![EXShellManager sharedInstance].areRemoteUpdatesEnabled)) {
    shouldCheckForUpdate = NO;
  }

  if (shouldCheckForUpdate) {
    [self _startAppFetcher:[[EXKernelAppFetcherWithTimeout alloc] initWithAppLoader:self timeoutLengthInMs:fallbackToCacheTimeout]];
  } else {
    [self _startAppFetcher:[[EXKernelAppFetcherCacheOnly alloc] initWithAppLoader:self manifest:manifest]];
  }
}

- (void)_startAppFetcher:(EXKernelAppFetcher *)appFetcher
{
  _appFetcher = appFetcher;
  _appFetcher.delegate = self;
  _appFetcher.dataSource = _dataSource;
  _appFetcher.cacheDataSource = self;
  if ([_appFetcher isKindOfClass:[EXKernelAppFetcherDevelopmentMode class]]) {
    ((EXKernelAppFetcherDevelopmentMode *)_appFetcher).developmentModeDelegate = self;
  } else if ([_appFetcher isKindOfClass:[EXKernelAppFetcherWithTimeout class]]) {
    ((EXKernelAppFetcherWithTimeout *)_appFetcher).withTimeoutDelegate = self;
  }
  [_appFetcher start];
}

- (void)_finishWithError:(NSError * _Nullable)err
{
  _error = err;
  if (_delegate) {
    [_delegate appLoader:self didFailWithError:err];
  }
}

#pragma mark - EXKernelAppFetcherCacheDataSource

- (BOOL)isCacheUpToDateWithAppFetcher:(EXKernelAppFetcher *)appFetcher
{
  if (_localManifest) {
    // local manifest won't give us sufficient information to tell
    return NO;
  }
  if (!self.cachedManifest || !appFetcher.manifest) {
    // if either of these don't exist, we don't have enough information to tell
    return NO;
  }
  return appFetcher.manifest[@"revisionId"]
  ? [appFetcher.manifest[@"revisionId"] isEqualToString:self.cachedManifest[@"revisionId"]]
  : NO;
}

#pragma mark - EXKernelAppFetcherDelegate

- (void)appFetcher:(EXKernelAppFetcher *)appFetcher didSwitchToAppFetcher:(EXKernelAppFetcher *)newAppFetcher
{
  [self _startAppFetcher:newAppFetcher];
}

- (void)appFetcher:(EXKernelAppFetcher *)appFetcher didLoadOptimisticManifest:(NSDictionary *)manifest
{
  if (_delegate) {
    [_delegate appLoader:self didLoadOptimisticManifest:manifest];
  }
}

- (void)appFetcher:(EXKernelAppFetcher *)appFetcher didFinishLoadingManifest:(NSDictionary *)manifest bundle:(NSData *)bundle
{
  _confirmedManifest = manifest;
  if (_delegate) {
    [_delegate appLoader:self didFinishLoadingManifest:manifest bundle:bundle];
  }
}

- (void)appFetcher:(EXKernelAppFetcher *)appFetcher didFailWithError:(NSError *)error
{
  _error = error;
  _appFetcher = nil;
  if (_delegate) {
    [_delegate appLoader:self didFailWithError:error];
  }
}

#pragma mark - EXKernelAppFetcherDevelopmentModeDelegate

- (void)appFetcher:(EXKernelAppFetcher *)appFetcher didLoadBundleWithProgress:(EXLoadingProgress *)progress
{
  if (_delegate) {
    [_delegate appLoader:self didLoadBundleWithProgress:progress];
  }
}

#pragma mark - EXKernelAppFetcherWithTimeoutDelegate

- (void)appFetcher:(EXKernelAppFetcher *)appFetcher didResolveUpdatedBundleWithManifest:(NSDictionary * _Nullable)manifest isFromCache:(BOOL)isFromCache error:(NSError * _Nullable)error
{
  if (_delegate) {
    [_delegate appLoader:self didResolveUpdatedBundleWithManifest:manifest isFromCache:isFromCache error:error];
  }
}

#pragma mark - helper methods for fetching

- (void)fetchManifestWithCacheBehavior:(EXCachedResourceBehavior)cacheBehavior success:(void (^)(NSDictionary *))success failure:(void (^)(NSError *))failure
{
  // this fetch behavior should never be used, as we re-create it ourselves within this class
  if (cacheBehavior == EXCachedResourceFallBackToCache) {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"EXManifestResource should never be loaded with FallBackToCache behavior"
                                 userInfo:nil];
  }
  
  // if we're using a localManifest, just return it immediately
  if (_localManifest) {
    success(_localManifest);
    return;
  }

  if (!([_httpManifestUrl.scheme isEqualToString:@"http"] || [_httpManifestUrl.scheme isEqualToString:@"https"])) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:_httpManifestUrl resolvingAgainstBaseURL:NO];
    components.scheme = @"http";
    _httpManifestUrl = [components URL];
  }
  EXManifestResource *manifestResource = [[EXManifestResource alloc] initWithManifestUrl:_httpManifestUrl originalUrl:_manifestUrl];
  [manifestResource loadResourceWithBehavior:cacheBehavior progressBlock:nil successBlock:^(NSData * _Nonnull data) {
    NSError *error;
    id manifest = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
    if (!manifest) {
      failure(error);
      return;
    }
    if (![manifest isKindOfClass:[NSDictionary class]]) {
      NSDictionary *errorInfo = @{
                                  NSLocalizedDescriptionKey: @"Cannot parse manifest",
                                  NSLocalizedFailureReasonErrorKey: @"Tried to load a manifest which was not in the proper format",
                                  };
      failure([NSError errorWithDomain:EXNetworkErrorDomain code:-1 userInfo:errorInfo]);
      return;
    }
    
    // insert loadedFromCache: boolean key into manifest
    NSMutableDictionary *mutableManifest = [(NSDictionary *)manifest mutableCopy];
    BOOL loadedFromCache = YES;
    if (cacheBehavior == EXCachedResourceNoCache || cacheBehavior == EXCachedResourceWriteToCache) {
      loadedFromCache = NO;
    }
    mutableManifest[@"loadedFromCache"] = @(loadedFromCache);

    success([NSDictionary dictionaryWithDictionary:mutableManifest]);
  } errorBlock:^(NSError * _Nonnull error) {
#if DEBUG
    if ([EXShellManager sharedInstance].isShell && error &&
        (error.code == 404 || error.domain == EXNetworkErrorDomain)) {
      NSString *message = error.localizedDescription;
      message = [NSString stringWithFormat:@"Make sure you are serving your project from XDE or exp (%@)", message];
      error = [NSError errorWithDomain:error.domain code:error.code userInfo:@{ NSLocalizedDescriptionKey: message }];
    }
#endif
    failure(error);
  }];
}

- (void)fetchJSBundleWithManifest:(NSDictionary *)manifest
                     cacheBehavior:(EXCachedResourceBehavior)cacheBehavior
                   timeoutInterval:(NSTimeInterval)timeoutInterval
                          progress:(void (^ _Nullable )(EXLoadingProgress *))progressBlock
                           success:(void (^)(NSData *))successBlock
                             error:(void (^)(NSError *))errorBlock
{
  RCTAssert(_appFetcher != nil, @"Tried to fetch a JS Bundle before appFetcher was initialized");
  [_appFetcher fetchJSBundleWithManifest:manifest cacheBehavior:cacheBehavior timeoutInterval:timeoutInterval progress:progressBlock success:successBlock error:errorBlock];
}

@end

NS_ASSUME_NONNULL_END
