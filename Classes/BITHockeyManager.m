/*
 * Author: Andreas Linde <mail@andreaslinde.de>
 *         Kent Sutherland
 *
 * Copyright (c) 2012-2014 HockeyApp, Bit Stadium GmbH.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import "HockeySDK.h"
#import "HockeySDKPrivate.h"

#if HOCKEYSDK_FEATURE_CRASH_REPORTER
#import "BITHockeyBaseManagerPrivate.h"
#import "BITCrashManagerPrivate.h"
#endif /* HOCKEYSDK_FEATURE_CRASH_REPORTER */

#import "BITHockeyHelper.h"
#import "BITHockeyAppClient.h"
#import "BITKeychainUtils.h"

#include <stdint.h>

typedef struct {
  uint8_t       info_version;
  const char    hockey_version[16];
  const char    hockey_build[16];
} bitstadium_info_t;

bitstadium_info_t bitstadium_library_info __attribute__((section("__TEXT,__bit_hockey,regular,no_dead_strip"))) = {
  .info_version = 1,
  .hockey_version = BITHOCKEY_C_VERSION,
  .hockey_build = BITHOCKEY_C_BUILD
};

@interface BITHockeyManager ()

- (BOOL)shouldUseLiveIdentifier;

@end


@implementation BITHockeyManager {
  NSString *_appIdentifier;
  NSString *_liveIdentifier;
  
  BOOL _validAppIdentifier;
  
  BOOL _startManagerIsInvoked;
  
  BOOL _startUpdateManagerIsInvoked;
  
  BOOL _managersInitialized;
  
  BITHockeyAppClient *_hockeyAppClient;
}

#pragma mark - Private Class Methods

- (BOOL)checkValidityOfAppIdentifier:(NSString *)identifier {
  BOOL result = NO;
  
  if (identifier) {
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    NSCharacterSet *inStringSet = [NSCharacterSet characterSetWithCharactersInString:identifier];
    result = ([identifier length] == 32) && ([hexSet isSupersetOfSet:inStringSet]);
  }
  
  return result;
}

- (void)logInvalidIdentifier:(NSString *)environment {
  if (self.appEnvironment != BITEnvironmentAppStore) {
    if ([environment isEqualToString:@"liveIdentifier"]) {
      NSLog(@"[HockeySDK] WARNING: The liveIdentifier is invalid! The SDK will be disabled when deployed to the App Store without setting a valid app identifier!");
    } else {
      NSLog(@"[HockeySDK] ERROR: The %@ is invalid! Please use the HockeyApp app identifier you find on the apps website on HockeyApp! The SDK is disabled!", environment);
    }
  }
}


#pragma mark - Public Class Methods

+ (BITHockeyManager *)sharedHockeyManager {
  static BITHockeyManager *sharedInstance = nil;
  static dispatch_once_t pred;
  
  dispatch_once(&pred, ^{
    sharedInstance = [BITHockeyManager alloc];
    sharedInstance = [sharedInstance init];
  });
  
  return sharedInstance;
}

- (id)init {
  if ((self = [super init])) {
    _serverURL = nil;
    _delegate = nil;
    _managersInitialized = NO;
    
    _hockeyAppClient = nil;
    
#if HOCKEYSDK_FEATURE_CRASH_REPORTER
    _disableCrashManager = NO;
#endif
    _appEnvironment = BITEnvironmentOther;
    _startManagerIsInvoked = NO;
    _startUpdateManagerIsInvoked = NO;
    
    _liveIdentifier = nil;
    _installString = bit_appAnonID(NO);
    _disableInstallTracking = NO;
    
#if !TARGET_OS_SIMULATOR
    // check if we are really in an app store environment
    if (bit_isRunningInAppStoreEnvironment()) {
      _appEnvironment = BITEnvironmentAppStore;
    } else if (bit_isRunningInTestFlightEnvironment()) {
      _appEnvironment = BITEnvironmentTestFlight;
    } else {
      _appEnvironment = BITEnvironmentOther;
    }
#endif

    [self performSelector:@selector(validateStartManagerIsInvoked) withObject:nil afterDelay:0.0f];
  }
  return self;
}

#pragma mark - Public Instance Methods (Configuration)

- (void)configureWithIdentifier:(NSString *)appIdentifier {
  _appIdentifier = [appIdentifier copy];
  
  [self initializeModules];
}

- (void)configureWithIdentifier:(NSString *)appIdentifier delegate:(id)delegate {
  _delegate = delegate;
  _appIdentifier = [appIdentifier copy];
  
  [self initializeModules];
}

- (void)configureWithBetaIdentifier:(NSString *)betaIdentifier liveIdentifier:(NSString *)liveIdentifier delegate:(id)delegate {
  _delegate = delegate;

  // check the live identifier now, because otherwise invalid identifier would only be logged when the app is already in the store
  if (![self checkValidityOfAppIdentifier:liveIdentifier]) {
    [self logInvalidIdentifier:@"liveIdentifier"];
    _liveIdentifier = [liveIdentifier copy];
  }

  if ([self shouldUseLiveIdentifier]) {
    _appIdentifier = [liveIdentifier copy];
  }
  else {
    _appIdentifier = [betaIdentifier copy];
  }
  
  [self initializeModules];
}


- (void)startManager {
  if (!_validAppIdentifier) return;
  if (_startManagerIsInvoked) {
    NSLog(@"[HockeySDK] Warning: startManager should only be invoked once! This call is ignored.");
    return;
  }
  
  if (![self isSetUpOnMainThread]) return;
  
  if ((self.appEnvironment == BITEnvironmentAppStore) && [self isInstallTrackingDisabled]) {
    _installString = bit_appAnonID(YES);
  }

  BITHockeyLog(@"INFO: Starting HockeyManager");
  _startManagerIsInvoked = YES;
  
#if HOCKEYSDK_FEATURE_CRASH_REPORTER
  // start CrashManager
  if (![self isCrashManagerDisabled]) {
    BITHockeyLog(@"INFO: Start CrashManager");
    if (_serverURL) {
      [_crashManager setServerURL:_serverURL];
    }

    [_crashManager startManager];
  }
#endif /* HOCKEYSDK_FEATURE_CRASH_REPORTER */
  
  // App Extensions can only use BITCrashManager, so ignore all others automatically
  if (bit_isRunningInAppExtension()) {
    return;
  }
}


- (void)setServerURL:(NSString *)aServerURL {
  // ensure url ends with a trailing slash
  if (![aServerURL hasSuffix:@"/"]) {
    aServerURL = [NSString stringWithFormat:@"%@/", aServerURL];
  }
  
  if (_serverURL != aServerURL) {
    _serverURL = [aServerURL copy];
    
    if (_hockeyAppClient) {
      _hockeyAppClient.baseURL = [NSURL URLWithString:_serverURL ? _serverURL : BITHOCKEYSDK_URL];
    }
  }
}


- (void)setDelegate:(id<BITHockeyManagerDelegate>)delegate {
  if (self.appEnvironment != BITEnvironmentAppStore) {
    if (_startManagerIsInvoked) {
      NSLog(@"[HockeySDK] ERROR: The `delegate` property has to be set before calling [[BITHockeyManager sharedHockeyManager] startManager] !");
    }
  }
  
  if (_delegate != delegate) {
    _delegate = delegate;
    
#if HOCKEYSDK_FEATURE_CRASH_REPORTER
    if (_crashManager) {
      _crashManager.delegate = _delegate;
    }
#endif /* HOCKEYSDK_FEATURE_CRASH_REPORTER */
  }
}

- (void)modifyKeychainUserValue:(NSString *)value forKey:(NSString *)key {
  NSError *error = nil;
  BOOL success = YES;
  NSString *updateType = @"update";
  
  if (value) {
    success = [BITKeychainUtils storeUsername:key
                                  andPassword:value
                               forServiceName:bit_keychainHockeySDKServiceName()
                               updateExisting:YES
                                accessibility:kSecAttrAccessibleAlwaysThisDeviceOnly
                                        error:&error];
  } else {
    updateType = @"delete";
    if ([BITKeychainUtils getPasswordForUsername:key
                                  andServiceName:bit_keychainHockeySDKServiceName()
                                           error:&error]) {
      success = [BITKeychainUtils deleteItemForUsername:key
                                         andServiceName:bit_keychainHockeySDKServiceName()
                                                  error:&error];
    }
  }
  
  if (!success) {
    NSString *errorDescription = [error description] ?: @"";
    BITHockeyLog(@"ERROR: Couldn't %@ key %@ in the keychain. %@", updateType, key, errorDescription);
  }
}

- (void)setUserID:(NSString *)userID {
  // always set it, since nil value will trigger removal of the keychain entry
  _userID = userID;
  
  [self modifyKeychainUserValue:userID forKey:kBITHockeyMetaUserID];
}

- (void)setUserName:(NSString *)userName {
  // always set it, since nil value will trigger removal of the keychain entry
  _userName = userName;
  
  [self modifyKeychainUserValue:userName forKey:kBITHockeyMetaUserName];
}

- (void)setUserEmail:(NSString *)userEmail {
  // always set it, since nil value will trigger removal of the keychain entry
  _userEmail = userEmail;
  
  [self modifyKeychainUserValue:userEmail forKey:kBITHockeyMetaUserEmail];
}

- (void)testIdentifier {
  if (!_appIdentifier || (self.appEnvironment == BITEnvironmentAppStore)) {
    return;
  }
  
  NSDate *now = [NSDate date];
  NSString *timeString = [NSString stringWithFormat:@"%.0f", [now timeIntervalSince1970]];
  [self pingServerForIntegrationStartWorkflowWithTimeString:timeString appIdentifier:_appIdentifier];
  
  if (_liveIdentifier) {
    [self pingServerForIntegrationStartWorkflowWithTimeString:timeString appIdentifier:_liveIdentifier];
  }
}


- (NSString *)version {
  return [NSString stringWithUTF8String:bitstadium_library_info.hockey_version];
}

- (NSString *)build {
  return [NSString stringWithUTF8String:bitstadium_library_info.hockey_build];
}


#pragma mark - Private Instance Methods

- (BITHockeyAppClient *)hockeyAppClient {
  if (!_hockeyAppClient) {
    _hockeyAppClient = [[BITHockeyAppClient alloc] initWithBaseURL:[NSURL URLWithString:_serverURL ? _serverURL : BITHOCKEYSDK_URL]];
    
    _hockeyAppClient.baseURL = [NSURL URLWithString:_serverURL ? _serverURL : BITHOCKEYSDK_URL];
  }
  
  return _hockeyAppClient;
}

- (NSString *)integrationFlowTimeString {
  NSString *timeString = [[NSBundle mainBundle] objectForInfoDictionaryKey:BITHOCKEY_INTEGRATIONFLOW_TIMESTAMP];
  
  return timeString;
}

- (BOOL)integrationFlowStartedWithTimeString:(NSString *)timeString {
  if (timeString == nil || (self.appEnvironment == BITEnvironmentAppStore)) {
    return NO;
  }
  
  NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
  NSLocale *enUSPOSIXLocale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
  [dateFormatter setLocale:enUSPOSIXLocale];
  [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZ"];
  NSDate *integrationFlowStartDate = [dateFormatter dateFromString:timeString];
  
  if (integrationFlowStartDate && [integrationFlowStartDate timeIntervalSince1970] > [[NSDate date] timeIntervalSince1970] - (60 * 10) ) {
    return YES;
  }
  
  return NO;
}

- (void)pingServerForIntegrationStartWorkflowWithTimeString:(NSString *)timeString appIdentifier:(NSString *)appIdentifier {
  if (!appIdentifier || (self.appEnvironment == BITEnvironmentAppStore)) {
    return;
  }
  
  NSString *integrationPath = [NSString stringWithFormat:@"api/3/apps/%@/integration", bit_encodeAppIdentifier(appIdentifier)];
  
  BITHockeyLog(@"INFO: Sending integration workflow ping to %@", integrationPath);
  
  NSDictionary *params = @{@"timestamp": timeString,
                           @"sdk": BITHOCKEY_NAME,
                           @"sdk_version": BITHOCKEY_VERSION,
                           @"bundle_version": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]
                           };
  
  id nsurlsessionClass = NSClassFromString(@"NSURLSessionUploadTask");
  if (nsurlsessionClass && !bit_isRunningInAppExtension()) {
    NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfiguration];
    NSURLRequest *request = [[self hockeyAppClient] requestWithMethod:@"POST" path:integrationPath parameters:params];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler: ^(NSData *data, NSURLResponse *response, NSError *error) {
                                              NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*) response;
                                              [self logPingMessageForStatusCode:httpResponse.statusCode];
                                            }];
    [task resume];
  }else{
    [[self hockeyAppClient] postPath:integrationPath
                          parameters:params
                          completion:^(BITHTTPOperation *operation, NSData* responseData, NSError *error) {
                            [self logPingMessageForStatusCode:operation.response.statusCode];
                          }];
  }
  
}

- (void)logPingMessageForStatusCode:(NSInteger)statusCode {
  switch (statusCode) {
    case 400:
      BITHockeyLog(@"ERROR: App ID not found");
      break;
    case 201:
      BITHockeyLog(@"INFO: Ping accepted.");
      break;
    case 200:
      BITHockeyLog(@"INFO: Ping accepted. Server already knows.");
      break;
    default:
      BITHockeyLog(@"ERROR: Unknown error");
      break;
  }
}

- (void)validateStartManagerIsInvoked {
  if (_validAppIdentifier && (self.appEnvironment != BITEnvironmentAppStore)) {
    if (!_startManagerIsInvoked) {
      NSLog(@"[HockeySDK] ERROR: You did not call [[BITHockeyManager sharedHockeyManager] startManager] to startup the HockeySDK! Please do so after setting up all properties. The SDK is NOT running.");
    }
  }
}

- (BOOL)isSetUpOnMainThread {
  NSString *errorString = @"ERROR: HockeySDK has to be setup on the main thread!";
  
  if (!NSThread.isMainThread) {
    if (self.appEnvironment == BITEnvironmentAppStore) {
      BITHockeyLog(@"%@", errorString);
    } else {
      NSLog(@"%@", errorString);
      NSAssert(NSThread.isMainThread, errorString);
    }
    
    return NO;
  }
  
  return YES;
}

- (BOOL)shouldUseLiveIdentifier {
  BOOL delegateResult = NO;
  if ([_delegate respondsToSelector:@selector(shouldUseLiveIdentifierForHockeyManager:)]) {
    delegateResult = [(NSObject <BITHockeyManagerDelegate>*)_delegate shouldUseLiveIdentifierForHockeyManager:self];
  }

  return (delegateResult) || (_appEnvironment == BITEnvironmentAppStore);
}

- (void)initializeModules {
  if (_managersInitialized) {
    NSLog(@"[HockeySDK] Warning: The SDK should only be initialized once! This call is ignored.");
    return;
  }
  
  _validAppIdentifier = [self checkValidityOfAppIdentifier:_appIdentifier];
  
  if (![self isSetUpOnMainThread]) return;
  
  _startManagerIsInvoked = NO;
  
  if (_validAppIdentifier) {
#if HOCKEYSDK_FEATURE_CRASH_REPORTER
    BITHockeyLog(@"INFO: Setup CrashManager");
    _crashManager = [[BITCrashManager alloc] initWithAppIdentifier:_appIdentifier appEnvironment:_appEnvironment];
    _crashManager.hockeyAppClient = [self hockeyAppClient];
    _crashManager.delegate = _delegate;
#endif /* HOCKEYSDK_FEATURE_CRASH_REPORTER */

    if (self.appEnvironment != BITEnvironmentAppStore) {
      NSString *integrationFlowTime = [self integrationFlowTimeString];
      if (integrationFlowTime && [self integrationFlowStartedWithTimeString:integrationFlowTime]) {
        [self pingServerForIntegrationStartWorkflowWithTimeString:integrationFlowTime appIdentifier:_appIdentifier];
      }
    }
    _managersInitialized = YES;
  } else {
    [self logInvalidIdentifier:@"app identifier"];
  }
}

@end