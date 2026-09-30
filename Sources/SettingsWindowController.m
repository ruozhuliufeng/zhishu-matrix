#import "SettingsWindowController.h"
#import "AuthorizationLink.h"
#import "DeskUI.h"

@interface SettingsWindowController () <NSTextFieldDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSTextField *authField;
@property (nonatomic, strong) NSTextField *authError;
@end

@implementation SettingsWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 540, 220)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        window.title = @"设置";
        window.releasedWhenClosed = NO;
        window.restorable = NO;
        window.delegate = self;
        [self buildContent];
        [window center];
    }
    return self;
}

- (void)buildContent {
    NSView *root = [NSView new];
    self.window.contentView = root;
    NSTextField *title = DeskLabel(@"默认授权链接", 13, NSFontWeightSemibold);
    self.authField = [NSTextField new];
    self.authField.placeholderString = @"https://…";
    self.authField.usesSingleLineMode = NO;
    self.authField.cell.wraps = YES;
    self.authField.cell.scrollable = NO;
    self.authField.lineBreakMode = NSLineBreakByCharWrapping;
    self.authField.delegate = self;
    self.authField.stringValue = [NSUserDefaults.standardUserDefaults stringForKey:DefaultAuthorizationURLDefaultsKey] ?: @"";
    NSTextField *hint = [NSTextField wrappingLabelWithString:
        @"账号没有单独设置授权链接时，“打开授权链接”会预先填入此地址。每次登录都会生成新链接的客户端（如 Codex）不需要设置，打开时粘贴最新链接即可。"];
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = NSColor.secondaryLabelColor;
    self.authError = DeskLabel(@"无法识别为 http:// 或 https:// 链接，未保存。", 11, NSFontWeightRegular);
    self.authError.textColor = NSColor.systemRedColor;
    self.authError.hidden = YES;

    for (NSView *view in @[title, self.authField, hint, self.authError]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:root.topAnchor constant:20],
        [title.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [self.authField.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [self.authField.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [self.authField.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [self.authField.heightAnchor constraintEqualToConstant:58],
        [self.authError.topAnchor constraintEqualToAnchor:self.authField.bottomAnchor constant:6],
        [self.authError.leadingAnchor constraintEqualToAnchor:self.authField.leadingAnchor],
        [hint.topAnchor constraintEqualToAnchor:self.authError.bottomAnchor constant:4],
        [hint.leadingAnchor constraintEqualToAnchor:self.authField.leadingAnchor],
        [hint.trailingAnchor constraintEqualToAnchor:self.authField.trailingAnchor],
        [hint.bottomAnchor constraintLessThanOrEqualToAnchor:root.bottomAnchor constant:-20]
    ]];
    hint.preferredMaxLayoutWidth = 500;
}

- (void)saveAuthorizationURL {
    NSString *text = [self.authField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (!text.length) {
        [defaults removeObjectForKey:DefaultAuthorizationURLDefaultsKey];
        self.authError.hidden = YES;
        return;
    }
    NSURL *url = AuthorizationURLFromText(text);
    self.authError.hidden = url != nil;
    if (!url) return;
    [defaults setObject:url.absoluteString forKey:DefaultAuthorizationURLDefaultsKey];
    self.authField.stringValue = url.absoluteString;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification { [self saveAuthorizationURL]; }

- (void)commitEditing {
    if (self.authField.currentEditor) [self.window makeFirstResponder:nil];
}

- (void)windowWillClose:(NSNotification *)notification { [self commitEditing]; }
@end
