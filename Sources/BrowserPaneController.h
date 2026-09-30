#import <Cocoa/Cocoa.h>
#import "AccountCoordinator.h"

@class BrowserSession;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserPaneController : NSViewController
@property (nonatomic, readonly, nullable) BrowserSession *session;
- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator;
- (void)showSession:(nullable BrowserSession *)session;
- (void)updateState;
@end

NS_ASSUME_NONNULL_END
