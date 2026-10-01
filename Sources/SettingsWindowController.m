#import "SettingsWindowController.h"
#import "AuthorizationLink.h"
#import "BrowserSession.h"
#import "DeskUI.h"

@interface SettingsWindowController () <NSTextFieldDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSTextField *authField;
@property (nonatomic, strong) NSTextField *authError;
@property (nonatomic, strong) NSButton *safariToggle;
@end

@implementation SettingsWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 540, 330)
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
    NSTextField *webTitle = DeskLabel(@"网页", 13, NSFontWeightSemibold);
    self.safariToggle = [NSButton checkboxWithTitle:@"以 Safari 浏览器身份打开网页（推荐）" target:self action:@selector(safariToggled:)];
    self.safariToggle.state = BrowserPreferredUserAgent() ? NSControlStateValueOn : NSControlStateValueOff;
    NSTextField *webHint = [NSTextField wrappingLabelWithString:
        @"关闭后，ChatGPT 会把本应用识别为桌面客户端，只显示 Work 和 Codex，没有普通聊天，账单等设置也会要求前往网页版。修改后已打开的账号页面会重新载入。"];
    webHint.font = [NSFont systemFontOfSize:11];
    webHint.textColor = NSColor.secondaryLabelColor;
    webHint.preferredMaxLayoutWidth = 500;
    NSBox *separator = DeskSeparator();
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

    for (NSView *view in @[webTitle, self.safariToggle, webHint, separator, title, self.authField, hint, self.authError]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [webTitle.topAnchor constraintEqualToAnchor:root.topAnchor constant:20],
        [webTitle.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [self.safariToggle.topAnchor constraintEqualToAnchor:webTitle.bottomAnchor constant:10],
        [self.safariToggle.leadingAnchor constraintEqualToAnchor:webTitle.leadingAnchor],
        [webHint.topAnchor constraintEqualToAnchor:self.safariToggle.bottomAnchor constant:6],
        [webHint.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:40],
        [webHint.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [separator.topAnchor constraintEqualToAnchor:webHint.bottomAnchor constant:18],
        [separator.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [separator.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [title.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:18],
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

- (void)safariToggled:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:self.safariToggle.state == NSControlStateValueOn
        forKey:IdentifyAsSafariDefaultsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:BrowserUserAgentPreferenceDidChangeNotification object:nil];
}

- (void)commitEditing {
    if (self.authField.currentEditor) [self.window makeFirstResponder:nil];
}

- (void)windowWillClose:(NSNotification *)notification { [self commitEditing]; }
@end
