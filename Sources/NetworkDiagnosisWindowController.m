#import "NetworkDiagnosisWindowController.h"
#import "Account.h"
#import "DeskUI.h"
#import "NetworkDiagnosis.h"
#import "NetworkProxy.h"

static CGFloat const ContentWidth = 560;

/// Spinner while a check runs, then a green check or a red cross.
@interface DiagnosisStatusView : NSView
@property (nonatomic, strong) NSImageView *icon;
@property (nonatomic, strong) NSProgressIndicator *spinner;
- (void)showPending;
- (void)showSucceeded:(BOOL)succeeded;
@end

@implementation DiagnosisStatusView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _icon = [NSImageView new];
        _icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
        _spinner = [NSProgressIndicator new];
        _spinner.style = NSProgressIndicatorStyleSpinning;
        _spinner.controlSize = NSControlSizeSmall;
        _spinner.displayedWhenStopped = NO;
        for (NSView *view in @[_icon, _spinner]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:view];
            [view.centerXAnchor constraintEqualToAnchor:self.centerXAnchor].active = YES;
            [view.centerYAnchor constraintEqualToAnchor:self.centerYAnchor].active = YES;
        }
        [self.widthAnchor constraintEqualToConstant:18].active = YES;
        [self.heightAnchor constraintEqualToConstant:18].active = YES;
    }
    return self;
}

- (void)showPending {
    self.icon.hidden = YES;
    [self.spinner startAnimation:nil];
}

- (void)showSucceeded:(BOOL)succeeded {
    [self.spinner stopAnimation:nil];
    self.icon.hidden = NO;
    self.icon.image = [NSImage imageWithSystemSymbolName:succeeded ? @"checkmark.circle.fill" : @"xmark.circle.fill"
        accessibilityDescription:succeeded ? @"正常" : @"失败"];
    self.icon.contentTintColor = succeeded ? NSColor.systemGreenColor : NSColor.systemRedColor;
}
@end

@interface NetworkDiagnosisWindowController () <NSWindowDelegate>
@property (nonatomic, strong, nullable) Account *account;
@property (nonatomic, strong) NetworkDiagnosis *diagnosis;
@property (nonatomic, strong, nullable) NetworkDiagnosisRunner *runner;
@property (nonatomic, strong) NSImageView *verdictIcon;
@property (nonatomic, strong) NSProgressIndicator *verdictSpinner;
@property (nonatomic, strong) NSTextField *headline;
@property (nonatomic, strong) NSTextField *proxyLabel;
@property (nonatomic, strong) NSTextField *exitLabel;
@property (nonatomic, strong) NSGridView *grid;
@property (nonatomic, strong) NSBox *adviceBox;
@property (nonatomic, strong) NSTextField *adviceLabel;
@property (nonatomic, strong) NSButton *reportButton;
@property (nonatomic, strong) NSButton *rerunButton;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rows;
@end

@implementation NetworkDiagnosisWindowController

+ (NetworkDiagnosisWindowController *)shared {
    static NetworkDiagnosisWindowController *shared;
    if (!shared) shared = [NetworkDiagnosisWindowController new];
    return shared;
}

+ (void)showForAccount:(Account *)account {
    NetworkDiagnosisWindowController *controller = [self shared];
    controller.account = account;
    controller.window.title = account ? [NSString stringWithFormat:@"网络诊断 · %@", account.name] : @"网络诊断";
    [controller run:nil];
    if (!controller.window.isVisible) [controller.window center];
    [controller showWindow:nil];
    [controller.window makeKeyAndOrderFront:nil];
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, ContentWidth, 360)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        window.releasedWhenClosed = NO;
        window.restorable = NO;
        window.delegate = self;
        _rows = [NSMutableArray array];
        [self buildContent];
    }
    return self;
}

- (void)buildContent {
    self.verdictIcon = [NSImageView new];
    self.verdictIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:26 weight:NSFontWeightRegular];
    self.verdictSpinner = [NSProgressIndicator new];
    self.verdictSpinner.style = NSProgressIndicatorStyleSpinning;
    self.verdictSpinner.displayedWhenStopped = NO;
    NSView *verdictMark = [NSView new];
    for (NSView *view in @[self.verdictIcon, self.verdictSpinner]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [verdictMark addSubview:view];
        [view.centerXAnchor constraintEqualToAnchor:verdictMark.centerXAnchor].active = YES;
        [view.centerYAnchor constraintEqualToAnchor:verdictMark.centerYAnchor].active = YES;
    }
    verdictMark.translatesAutoresizingMaskIntoConstraints = NO;
    [verdictMark.widthAnchor constraintEqualToConstant:34].active = YES;
    [verdictMark.heightAnchor constraintEqualToConstant:34].active = YES;

    self.headline = DeskLabel(@"", 16, NSFontWeightSemibold);
    self.proxyLabel = DeskLabel(@"", 12, NSFontWeightRegular);
    self.proxyLabel.textColor = NSColor.secondaryLabelColor;
    self.proxyLabel.selectable = YES;
    self.exitLabel = DeskLabel(@"", 12, NSFontWeightRegular);
    self.exitLabel.textColor = NSColor.secondaryLabelColor;
    self.exitLabel.selectable = YES;
    NSStackView *titles = [NSStackView stackViewWithViews:@[self.headline, self.proxyLabel, self.exitLabel]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 3;
    NSStackView *header = [NSStackView stackViewWithViews:@[verdictMark, titles]];
    header.alignment = NSLayoutAttributeTop;
    header.spacing = 12;

    self.grid = [NSGridView gridViewWithNumberOfColumns:4 rows:0];
    self.grid.rowSpacing = 9;
    self.grid.columnSpacing = 10;
    self.grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    self.grid.translatesAutoresizingMaskIntoConstraints = NO;

    self.adviceLabel = [NSTextField wrappingLabelWithString:@""];
    self.adviceLabel.font = [NSFont systemFontOfSize:12.5];
    self.adviceLabel.selectable = YES;
    self.adviceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.adviceBox = [NSBox new];
    self.adviceBox.boxType = NSBoxCustom;
    self.adviceBox.borderWidth = 0;
    self.adviceBox.cornerRadius = 8;
    self.adviceBox.fillColor = NSColor.quaternarySystemFillColor;
    self.adviceBox.contentViewMargins = NSMakeSize(12, 10);
    self.adviceBox.translatesAutoresizingMaskIntoConstraints = NO;
    [self.adviceBox.contentView addSubview:self.adviceLabel];
    NSView *boxContent = self.adviceBox.contentView;
    [NSLayoutConstraint activateConstraints:@[
        [self.adviceLabel.topAnchor constraintEqualToAnchor:boxContent.topAnchor],
        [self.adviceLabel.bottomAnchor constraintEqualToAnchor:boxContent.bottomAnchor],
        [self.adviceLabel.leadingAnchor constraintEqualToAnchor:boxContent.leadingAnchor],
        [self.adviceLabel.trailingAnchor constraintEqualToAnchor:boxContent.trailingAnchor]
    ]];
    self.adviceLabel.preferredMaxLayoutWidth = ContentWidth - 40 - 24;

    self.reportButton = DeskButton(@"复制结果", @"doc.on.doc", self, @selector(copyReport:));
    self.rerunButton = DeskButton(@"重新检测", @"arrow.clockwise", self, @selector(run:));
    NSButton *done = DeskButton(@"完成", nil, self, @selector(close));
    done.keyEquivalent = @"\r";
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.reportButton, spacer, self.rerunButton, done]];
    buttons.spacing = 8;

    NSStackView *stack = [NSStackView stackViewWithViews:@[header, DeskSeparator(), self.grid, self.adviceBox, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 16, 20);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:18 afterView:self.adviceBox];
    NSView *root = [NSView new];
    [root addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:root.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [root.widthAnchor constraintEqualToConstant:ContentWidth]
    ]];
    for (NSView *view in @[stack.arrangedSubviews[1], self.grid, self.adviceBox, buttons])
        [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40].active = YES;
    self.window.contentView = root;
}

#pragma mark - Running

- (void)run:(id)sender {
    [self.runner cancel];
    self.diagnosis = [NetworkDiagnosisRunner diagnosisForAccount:self.account];
    [self rebuildRows];
    [self refresh];
    __weak typeof(self) weakSelf = self;
    self.runner = [NetworkDiagnosisRunner run:self.diagnosis update:^(NetworkDiagnosis *diagnosis) {
        NetworkDiagnosisWindowController *strongSelf = weakSelf;
        if (strongSelf.diagnosis == diagnosis) [strongSelf refresh];
    }];
}

- (void)rebuildRows {
    while (self.grid.numberOfRows) [self.grid removeRowAtIndex:0];
    [self.rows removeAllObjects];
    NetworkDiagnosis *diagnosis = self.diagnosis;
    if (diagnosis.proxyHost)
        [self addRowTitle:@"代理端口" host:[NSString stringWithFormat:@"%@:%ld", diagnosis.proxyHost, (long)diagnosis.proxyPort] check:nil];
    for (NetworkCheck *check in diagnosis.checks) [self addRowTitle:check.title host:check.host check:check];
    if (self.grid.numberOfColumns == 4) {
        [self.grid columnAtIndex:3].xPlacement = NSGridCellPlacementTrailing;
        [self.grid columnAtIndex:2].width = 190;
    }
}

- (void)addRowTitle:(NSString *)title host:(NSString *)host check:(NetworkCheck *)check {
    DiagnosisStatusView *status = [DiagnosisStatusView new];
    NSTextField *titleLabel = DeskLabel(title, 13, NSFontWeightMedium);
    if (check.control) titleLabel.textColor = NSColor.secondaryLabelColor;
    NSTextField *hostLabel = DeskLabel(host, 12, NSFontWeightRegular);
    hostLabel.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    hostLabel.textColor = NSColor.secondaryLabelColor;
    NSTextField *detail = DeskLabel(@"", 12, NSFontWeightRegular);
    detail.alignment = NSTextAlignmentRight;
    [self.grid addRowWithViews:@[status, titleLabel, hostLabel, detail]];
    NSMutableDictionary *row = [@{@"status": status, @"detail": detail} mutableCopy];
    if (check) row[@"check"] = check;
    [self.rows addObject:row];
}

- (void)refresh {
    NetworkDiagnosis *diagnosis = self.diagnosis;
    for (NSDictionary *row in self.rows) {
        DiagnosisStatusView *status = row[@"status"];
        NSTextField *detail = row[@"detail"];
        NetworkCheck *check = row[@"check"];
        BOOL finished = check ? check.finished : diagnosis.proxyReachable != nil;
        BOOL succeeded = check ? check.succeeded : diagnosis.proxyReachable.boolValue;
        if (!finished) {
            [status showPending];
            detail.stringValue = @"正在检测…";
            detail.textColor = NSColor.secondaryLabelColor;
            continue;
        }
        [status showSucceeded:succeeded];
        detail.stringValue = check ? check.detail : (succeeded ? @"可连接" : @"连不上");
        detail.textColor = succeeded ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
        detail.toolTip = check.errorText;
    }

    self.proxyLabel.stringValue = [@"代理：" stringByAppendingString:diagnosis.proxyDescription];
    NSString *exit = nil;
    if (diagnosis.exitIP.length || diagnosis.region.length)
        exit = [NSString stringWithFormat:@"出口 IP %@ · 地区 %@", diagnosis.exitIP ?: @"未知", diagnosis.region ?: @"未知"];
    self.exitLabel.stringValue = exit ?: @"";
    self.exitLabel.hidden = !exit;

    NetworkVerdict verdict = diagnosis.verdict;
    self.headline.stringValue = diagnosis.headline;
    if (verdict == NetworkVerdictPending) {
        self.verdictIcon.hidden = YES;
        [self.verdictSpinner startAnimation:nil];
    } else {
        [self.verdictSpinner stopAnimation:nil];
        self.verdictIcon.hidden = NO;
        BOOL ok = verdict == NetworkVerdictOK;
        BOOL warning = verdict == NetworkVerdictPartial || verdict == NetworkVerdictUnsupportedRegion;
        self.verdictIcon.image = [NSImage imageWithSystemSymbolName:ok ? @"checkmark.seal.fill"
            : (warning ? @"exclamationmark.triangle.fill" : @"xmark.octagon.fill") accessibilityDescription:nil];
        self.verdictIcon.contentTintColor = ok ? NSColor.systemGreenColor : (warning ? NSColor.systemOrangeColor : NSColor.systemRedColor);
    }
    NSString *advice = diagnosis.advice;
    self.adviceLabel.stringValue = advice ?: @"";
    self.adviceBox.hidden = !advice.length;
    self.reportButton.enabled = diagnosis.finished;
    self.rerunButton.enabled = diagnosis.finished;
    [self.window.contentView layoutSubtreeIfNeeded];
    NSRect frame = self.window.frame;
    NSSize size = self.window.contentView.fittingSize;
    NSRect content = [self.window frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)];
    frame.origin.y += frame.size.height - content.size.height;
    frame.size = content.size;
    [self.window setFrame:frame display:YES];
}

- (void)copyReport:(id)sender {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.diagnosis.textReport forType:NSPasteboardTypeString];
    self.reportButton.title = @"已复制";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.reportButton.title = @"复制结果";
    });
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.runner cancel];
    self.runner = nil;
}
@end
