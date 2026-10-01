#import "AccountInspectorController.h"
#import "Account.h"
#import "AccountCardItem.h"
#import "AccountInsights.h"
#import "AuthorizationLink.h"
#import "DeskUI.h"
#import "NetworkProxy.h"

static NSString *const UnknownPlanTitle = @"未获取";

/// Sections collapsed when nothing was saved yet for a mode: management favours the overview, browsing the essentials.
static NSArray<NSString *> *DefaultCollapsedSections(DeskMode mode) {
    return mode == DeskModeManagement ? @[@"auth", @"network", @"notes", @"record"] : @[@"network", @"record"];
}

static NSString *CollapsedDefaultsKey(DeskMode mode) {
    return mode == DeskModeManagement ? @"inspectorCollapsed.management" : @"inspectorCollapsed.browser";
}

static NSString *ShortDateTime(NSDate *date) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = [NSCalendar.currentCalendar isDateInToday:date] ? @"今天 HH:mm"
        : ([NSCalendar.currentCalendar isDateInTomorrow:date] ? @"明天 HH:mm" : @"M月d日 HH:mm");
    return [formatter stringFromDate:date];
}

static NSString *SourceName(NSString *source, id value) {
    if (!value) return @"未获取";
    if ([source isEqualToString:@"page"]) return @"页面识别";
    if ([source isEqualToString:@"manual"]) return @"手动填写";
    if ([source isEqualToString:@"api"]) return @"接口读取";
    return @"已保存";
}

@interface AccountInspectorController () <NSTextFieldDelegate, NSComboBoxDelegate, NSTextViewDelegate, NSTokenFieldDelegate>
@property (nonatomic, weak) id<AccountCoordinator> coordinator;
@property (nonatomic, copy, nullable) NSString *accountID;
@property (nonatomic) NSUInteger selectionCount;

@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSStackView *placeholder;
@property (nonatomic, strong) NSTextField *placeholderLabel;

@property (nonatomic, strong) DeskAvatarView *avatar;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *subtitleLabel;
@property (nonatomic, strong) DeskPillView *planPill;
@property (nonatomic, strong) DeskPillView *expiryPill;
@property (nonatomic, strong) DeskPillView *statusPill;
@property (nonatomic, strong) NSTextField *duplicateLabel;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSStackView *> *sectionBodies;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *sectionHeaders;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *sectionSummaries;
@property (nonatomic, strong) DeskSparklineView *sparkline;
@property (nonatomic, strong) NSTextField *trendCaption;
@property (nonatomic, strong) NSTextField *predictionLabel;
@property (nonatomic, strong) NSButton *billingButton;
@property (nonatomic, strong) NSProgressIndicator *billingSpinner;
@property (nonatomic, strong) NSTextField *proxyField;
@property (nonatomic, strong) NSTextField *proxyResult;
@property (nonatomic, strong) NSButton *proxyTestButton;

@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSTextField *emailField;
@property (nonatomic, strong) NSComboBox *groupBox;
@property (nonatomic, strong) NSTokenField *tagsField;
@property (nonatomic, strong) DeskQuotaRow *shortRow;
@property (nonatomic, strong) DeskQuotaRow *longRow;
@property (nonatomic, strong) NSTextField *usageLabel;
@property (nonatomic, strong) NSButton *refreshButton;
@property (nonatomic, strong) NSProgressIndicator *refreshSpinner;
@property (nonatomic, strong) NSButton *autoRenewToggle;
@property (nonatomic, strong) NSTextField *priceField;
@property (nonatomic, strong) NSComboBox *currencyBox;
@property (nonatomic, strong) NSPopUpButton *planPicker;
@property (nonatomic, strong) NSButton *dateToggle;
@property (nonatomic, strong) NSDatePicker *datePicker;
@property (nonatomic, strong) NSPopUpButton *extendButton;
@property (nonatomic, strong) NSTextField *sourceLabel;
@property (nonatomic, strong) NSTextField *authField;
@property (nonatomic, strong) NSTextView *notesView;
@property (nonatomic, strong) NSTextField *recordLabel;
@end

@implementation AccountInspectorController

- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _coordinator = coordinator;
        _sectionBodies = [NSMutableDictionary dictionary];
        _sectionHeaders = [NSMutableDictionary dictionary];
        _sectionSummaries = [NSMutableDictionary dictionary];
    }
    return self;
}

- (Account *)account { return [self.coordinator.store accountWithID:self.accountID]; }

#pragma mark - Layout

- (NSStackView *)fieldWithCaption:(NSString *)caption control:(NSView *)control {
    NSStackView *field = [NSStackView stackViewWithViews:@[DeskCaption(caption), control]];
    field.orientation = NSUserInterfaceLayoutOrientationVertical;
    field.alignment = NSLayoutAttributeLeading;
    field.spacing = 5;
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [control.widthAnchor constraintEqualToAnchor:field.widthAnchor].active = YES;
    return field;
}

/// A collapsible section: a separator, a clickable header with a one-line summary, and its fields.
- (NSView *)sectionWithID:(NSString *)identifier title:(NSString *)title views:(NSArray<NSView *> *)views {
    NSButton *header = [NSButton buttonWithTitle:title target:self action:@selector(toggleSection:)];
    header.bordered = NO;
    header.imagePosition = NSImageLeading;
    header.alignment = NSTextAlignmentLeft;
    header.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    header.identifier = identifier;
    header.imageHugsTitle = YES;
    [header setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField *summary = DeskLabel(@"", 11, NSFontWeightRegular);
    summary.textColor = NSColor.tertiaryLabelColor;
    summary.alignment = NSTextAlignmentRight;
    [summary setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *headerRow = [NSStackView stackViewWithViews:@[header, summary]];
    headerRow.spacing = 8;
    headerRow.distribution = NSStackViewDistributionFill;

    NSStackView *body = [NSStackView new];
    body.orientation = NSUserInterfaceLayoutOrientationVertical;
    body.alignment = NSLayoutAttributeLeading;
    body.spacing = 10;
    for (NSView *view in views) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [body addArrangedSubview:view];
        [view.widthAnchor constraintEqualToAnchor:body.widthAnchor].active = YES;
    }
    NSBox *separator = DeskSeparator();
    NSStackView *section = [NSStackView stackViewWithViews:@[separator, headerRow, body]];
    section.orientation = NSUserInterfaceLayoutOrientationVertical;
    section.alignment = NSLayoutAttributeLeading;
    section.spacing = 10;
    for (NSView *view in @[separator, headerRow, body]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [view.widthAnchor constraintEqualToAnchor:section.widthAnchor].active = YES;
    }
    self.sectionBodies[identifier] = body;
    self.sectionHeaders[identifier] = header;
    self.sectionSummaries[identifier] = summary;
    return section;
}

- (NSSet<NSString *> *)collapsedSections {
    DeskMode mode = self.coordinator.mode;
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:CollapsedDefaultsKey(mode)];
    return [NSSet setWithArray:saved ?: DefaultCollapsedSections(mode)];
}

- (void)applyMode {
    if (!self.isViewLoaded) return;
    NSSet *collapsed = self.collapsedSections;
    [self.sectionBodies enumerateKeysAndObjectsUsingBlock:^(NSString *identifier, NSStackView *body, BOOL *stop) {
        BOOL hidden = [collapsed containsObject:identifier];
        body.hidden = hidden;
        self.sectionHeaders[identifier].image = [NSImage imageWithSystemSymbolName:hidden ? @"chevron.right" : @"chevron.down"
            accessibilityDescription:hidden ? @"展开" : @"折叠"];
        self.sectionHeaders[identifier].toolTip = hidden ? @"展开" : @"折叠";
        self.sectionSummaries[identifier].hidden = !hidden;
    }];
}

- (void)toggleSection:(NSButton *)sender {
    NSMutableSet *collapsed = [self.collapsedSections mutableCopy];
    if ([collapsed containsObject:sender.identifier]) [collapsed removeObject:sender.identifier];
    else [collapsed addObject:sender.identifier];
    [self commitPendingEdits];
    [NSUserDefaults.standardUserDefaults setObject:collapsed.allObjects forKey:CollapsedDefaultsKey(self.coordinator.mode)];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        context.allowsImplicitAnimation = YES;
        [self applyMode];
        [self.view layoutSubtreeIfNeeded];
    }];
}

- (void)loadView {
    NSView *root = [NSView new];
    self.view = root;

    self.scrollView = [NSScrollView new];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.drawsBackground = NO;
    DeskFlippedView *document = [DeskFlippedView new];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(14, 16, 24, 16);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:stack];
    self.scrollView.documentView = document;

    // Header
    self.avatar = [DeskAvatarView new];
    self.avatar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.avatar.widthAnchor constraintEqualToConstant:46].active = YES;
    [self.avatar.heightAnchor constraintEqualToConstant:46].active = YES;
    self.titleLabel = DeskLabel(@"", 17, NSFontWeightSemibold);
    self.subtitleLabel = DeskLabel(@"", 12, NSFontWeightRegular);
    self.subtitleLabel.textColor = NSColor.secondaryLabelColor;
    self.subtitleLabel.selectable = YES;
    NSStackView *titles = [NSStackView stackViewWithViews:@[self.titleLabel, self.subtitleLabel]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 2;
    [titles setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.titleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.subtitleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *header = [NSStackView stackViewWithViews:@[self.avatar, titles]];
    header.spacing = 12;
    header.alignment = NSLayoutAttributeCenterY;
    self.planPill = [DeskPillView new];
    self.statusPill = [DeskPillView new];
    self.expiryPill = [DeskPillView new];
    NSStackView *pills = [NSStackView stackViewWithViews:@[self.planPill, self.statusPill, self.expiryPill]];
    pills.spacing = 6;
    self.duplicateLabel = [NSTextField wrappingLabelWithString:@""];
    self.duplicateLabel.font = [NSFont systemFontOfSize:11];
    self.duplicateLabel.textColor = NSColor.systemOrangeColor;

    // Profile
    self.nameField = [NSTextField new];
    self.nameField.placeholderString = @"账号名称";
    self.nameField.delegate = self;
    self.emailField = [NSTextField new];
    self.emailField.placeholderString = @"邮箱（登录后自动识别）";
    self.emailField.delegate = self;
    self.groupBox = [NSComboBox new];
    self.groupBox.placeholderString = @"未分组";
    self.groupBox.completes = YES;
    self.groupBox.numberOfVisibleItems = 8;
    self.groupBox.delegate = self;
    self.groupBox.target = self;
    self.groupBox.action = @selector(groupChosen:);
    self.tagsField = [NSTokenField new];
    self.tagsField.placeholderString = @"添加标签，回车或逗号分隔";
    self.tagsField.tokenizingCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@",，"];
    self.tagsField.delegate = self;

    // Usage
    self.shortRow = [DeskQuotaRow new];
    self.longRow = [DeskQuotaRow new];
    self.usageLabel = [NSTextField wrappingLabelWithString:@""];
    self.usageLabel.font = [NSFont systemFontOfSize:11];
    self.usageLabel.textColor = NSColor.secondaryLabelColor;
    self.refreshButton = DeskButton(@"刷新用量与订阅", @"arrow.clockwise", self, @selector(refreshUsage:));
    self.refreshButton.toolTip = @"从 ChatGPT 读取此账号的额度、续费日期和是否自动续订";
    self.refreshSpinner = [NSProgressIndicator new];
    self.refreshSpinner.style = NSProgressIndicatorStyleSpinning;
    self.refreshSpinner.controlSize = NSControlSizeSmall;
    self.refreshSpinner.displayedWhenStopped = NO;
    NSStackView *refreshRow = [NSStackView stackViewWithViews:@[self.refreshButton, self.refreshSpinner]];
    refreshRow.spacing = 8;
    self.trendCaption = DeskLabel(@"", 11, NSFontWeightRegular);
    NSMutableAttributedString *legend = [[NSMutableAttributedString alloc] initWithString:@"近 7 天剩余额度　"
        attributes:@{NSForegroundColorAttributeName: NSColor.secondaryLabelColor, NSFontAttributeName: [NSFont systemFontOfSize:11]}];
    [legend appendAttributedString:[[NSAttributedString alloc] initWithString:@"━ 每周　" attributes:@{
        NSForegroundColorAttributeName: NSColor.systemIndigoColor, NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium]}]];
    [legend appendAttributedString:[[NSAttributedString alloc] initWithString:@"━ 5 小时" attributes:@{
        NSForegroundColorAttributeName: NSColor.systemTealColor, NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium]}]];
    self.trendCaption.attributedStringValue = legend;
    self.sparkline = [DeskSparklineView new];
    [self.sparkline.heightAnchor constraintEqualToConstant:44].active = YES;
    self.predictionLabel = [NSTextField wrappingLabelWithString:@""];
    self.predictionLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];

    // Subscription
    self.planPicker = [NSPopUpButton new];
    [self.planPicker addItemWithTitle:UnknownPlanTitle];
    [self.planPicker.menu addItem:[NSMenuItem separatorItem]];
    [self.planPicker addItemsWithTitles:AccountPlans()];
    self.planPicker.target = self;
    self.planPicker.action = @selector(planChanged:);
    self.dateToggle = [NSButton checkboxWithTitle:@"设置续费 / 到期日期" target:self action:@selector(dateToggled:)];
    self.datePicker = [NSDatePicker new];
    self.datePicker.datePickerStyle = NSDatePickerStyleTextField;
    self.datePicker.datePickerElements = NSDatePickerElementFlagYearMonthDay;
    self.datePicker.presentsCalendarOverlay = YES;
    self.datePicker.target = self;
    self.datePicker.action = @selector(dateChanged:);
    self.extendButton = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [self.extendButton addItemWithTitle:@"续期"];
    for (NSArray *option in @[@[@"顺延 1 个月", @1], @[@"顺延 3 个月", @3], @[@"顺延 1 年", @12]]) {
        [self.extendButton addItemWithTitle:option[0]];
        self.extendButton.lastItem.tag = [option[1] integerValue];
    }
    self.extendButton.toolTip = @"从当前到期日（已过期则从今天）开始顺延";
    self.extendButton.target = self;
    self.extendButton.action = @selector(extendExpiry:);
    NSStackView *dateRow = [NSStackView stackViewWithViews:@[self.datePicker, self.extendButton]];
    dateRow.spacing = 8;
    [self.datePicker setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.sourceLabel = DeskLabel(@"", 11, NSFontWeightRegular);
    self.sourceLabel.textColor = NSColor.secondaryLabelColor;
    self.autoRenewToggle = [NSButton checkboxWithTitle:@"到期自动续费" target:self action:@selector(autoRenewToggled:)];
    self.autoRenewToggle.toolTip = @"自动续费的账号在日期到来时续订，不算作即将到期";
    self.priceField = [NSTextField new];
    self.priceField.placeholderString = @"月费";
    self.priceField.delegate = self;
    NSNumberFormatter *priceFormatter = [NSNumberFormatter new];
    priceFormatter.numberStyle = NSNumberFormatterDecimalStyle;
    priceFormatter.minimum = @0;
    priceFormatter.maximumFractionDigits = 2;
    priceFormatter.lenient = YES;
    self.priceField.formatter = priceFormatter;
    self.currencyBox = [NSComboBox new];
    [self.currencyBox addItemsWithObjectValues:@[@"PHP", @"USD", @"CNY", @"HKD", @"TWD", @"EUR", @"GBP", @"JPY", @"SGD", @"KRW"]];
    self.currencyBox.placeholderString = @"币种";
    self.currencyBox.delegate = self;
    self.currencyBox.target = self;
    self.currencyBox.action = @selector(currencyChosen:);
    NSStackView *priceRow = [NSStackView stackViewWithViews:@[self.priceField, self.currencyBox]];
    priceRow.spacing = 8;
    [self.priceField setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.currencyBox.widthAnchor constraintEqualToConstant:84].active = YES;
    self.billingButton = DeskButton(@"读取账单（档位与月费）", @"creditcard", self, @selector(readBilling:));
    self.billingButton.toolTip = @"在后台打开此账号 ChatGPT 的“设置 → 账单”，读取 Pro 档位、续订日期和最近一次扣款金额";
    self.billingSpinner = [NSProgressIndicator new];
    self.billingSpinner.style = NSProgressIndicatorStyleSpinning;
    self.billingSpinner.controlSize = NSControlSizeSmall;
    self.billingSpinner.displayedWhenStopped = NO;
    NSButton *billingPage = [NSButton buttonWithTitle:@"打开账单页" target:self action:@selector(openBillingPage:)];
    billingPage.bordered = NO;
    billingPage.font = [NSFont systemFontOfSize:11];
    billingPage.contentTintColor = NSColor.linkColor;
    billingPage.toolTip = @"在浏览模式中打开此账号的账单设置";
    NSStackView *syncButton = [NSStackView stackViewWithViews:@[self.billingButton, self.billingSpinner, billingPage]];
    syncButton.spacing = 8;

    // Network
    self.proxyField = [NSTextField new];
    self.proxyField.delegate = self;
    self.proxyField.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    self.proxyTestButton = DeskButton(@"测试连接", @"network", self, @selector(testProxy:));
    self.proxyTestButton.toolTip = @"通过此代理访问 chatgpt.com，显示出口 IP 和地区";
    self.proxyResult = [NSTextField wrappingLabelWithString:@""];
    self.proxyResult.font = [NSFont systemFontOfSize:11];
    self.proxyResult.textColor = NSColor.secondaryLabelColor;
    NSTextField *proxyHint = [NSTextField wrappingLabelWithString:
        @"填写 http://主机:端口 或 socks5://主机:端口，只作用于此账号的页面、用量读取和授权窗口。留空使用设置中的默认代理。"];
    proxyHint.font = [NSFont systemFontOfSize:11];
    proxyHint.textColor = NSColor.secondaryLabelColor;

    // Client authorization
    self.authField = [NSTextField new];
    self.authField.delegate = self;
    self.authField.usesSingleLineMode = YES;
    self.authField.cell.scrollable = YES;
    self.authField.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSButton *authButton = DeskButton(@"打开授权链接…", @"person.badge.key", self, @selector(openAuthorization:));
    authButton.toolTip = @"在此账号的会话中打开客户端提供的授权链接（⇧⌘L）";
    NSTextField *authHint = [NSTextField wrappingLabelWithString:
        @"用此账号登录 Codex 等支持“使用 ChatGPT 登录”的客户端：粘贴客户端给出的授权链接，授权后客户端会自动完成登录。"];
    authHint.font = [NSFont systemFontOfSize:11];
    authHint.textColor = NSColor.secondaryLabelColor;

    // Notes
    NSScrollView *notesScroll = [NSTextView scrollableTextView];
    notesScroll.borderType = NSBezelBorder;
    notesScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [notesScroll.heightAnchor constraintEqualToConstant:84].active = YES;
    self.notesView = notesScroll.documentView;
    self.notesView.font = [NSFont systemFontOfSize:12];
    self.notesView.richText = NO;
    self.notesView.allowsUndo = YES;
    self.notesView.textContainerInset = NSMakeSize(4, 6);
    self.notesView.delegate = self;

    // Record
    self.recordLabel = [NSTextField wrappingLabelWithString:@""];
    self.recordLabel.font = [NSFont systemFontOfSize:11];
    self.recordLabel.textColor = NSColor.secondaryLabelColor;
    self.recordLabel.selectable = NO;

    NSButton *sessionButton = DeskButton(@"查看当前会话", @"key.horizontal", self.coordinator, @selector(showCurrentSession:));
    sessionButton.toolTip = @"读取当前账号的 chatgpt.com/api/auth/session 响应";
    NSButton *clearButton = DeskButton(@"清除登录数据…", @"rectangle.portrait.and.arrow.right", self, @selector(clearLoginData:));
    clearButton.toolTip = @"退出此账号在本机的登录，保留账号资料";
    NSButton *deleteButton = DeskButton(@"删除账号…", @"trash", self, @selector(deleteAccount:));
    deleteButton.contentTintColor = NSColor.systemRedColor;

    NSArray<NSView *> *fullWidth = @[
        self.duplicateLabel,
        [self sectionWithID:@"usage" title:@"用量" views:@[self.shortRow, self.longRow, self.trendCaption, self.sparkline,
            self.predictionLabel, self.usageLabel, refreshRow]],
        [self sectionWithID:@"profile" title:@"资料" views:@[
            [self fieldWithCaption:@"名称" control:self.nameField],
            [self fieldWithCaption:@"邮箱" control:self.emailField],
            [self fieldWithCaption:@"分组" control:self.groupBox],
            [self fieldWithCaption:@"标签" control:self.tagsField]]],
        [self sectionWithID:@"subscription" title:@"订阅" views:@[
            [self fieldWithCaption:@"级别" control:self.planPicker],
            self.dateToggle, dateRow, self.autoRenewToggle,
            [self fieldWithCaption:@"月费" control:priceRow],
            self.sourceLabel, syncButton]],
        [self sectionWithID:@"network" title:@"网络" views:@[
            [self fieldWithCaption:@"代理" control:self.proxyField], self.proxyTestButton, self.proxyResult, proxyHint]],
        [self sectionWithID:@"auth" title:@"客户端授权" views:@[
            [self fieldWithCaption:@"授权链接" control:self.authField], authButton, authHint]],
        [self sectionWithID:@"notes" title:@"备注" views:@[notesScroll]],
        [self sectionWithID:@"record" title:@"记录" views:@[self.recordLabel]],
        DeskSeparator(),
        sessionButton, clearButton, deleteButton
    ];
    [stack addArrangedSubview:header];
    [stack addArrangedSubview:pills];
    for (NSView *view in fullWidth) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [stack addArrangedSubview:view];
        [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-32].active = YES;
    }
    [header.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor constant:-32].active = YES;
    [stack setCustomSpacing:10 afterView:header];
    [stack setCustomSpacing:6 afterView:sessionButton];
    [stack setCustomSpacing:6 afterView:clearButton];
    NSStackView *usageBody = self.sectionBodies[@"usage"];
    [usageBody setCustomSpacing:8 afterView:self.shortRow];
    [usageBody setCustomSpacing:4 afterView:self.trendCaption];
    [self.sectionBodies[@"subscription"] setCustomSpacing:4 afterView:self.dateToggle];
    [self.sectionBodies[@"subscription"] setCustomSpacing:6 afterView:self.sourceLabel];
    [self.sectionBodies[@"auth"] setCustomSpacing:6 afterView:authButton];
    [self.sectionBodies[@"network"] setCustomSpacing:4 afterView:self.proxyTestButton];

    // Placeholder for no / multiple selection
    NSImageView *placeholderIcon = [NSImageView imageViewWithImage:
        [NSImage imageWithSystemSymbolName:@"person.crop.circle" accessibilityDescription:nil]];
    placeholderIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:34 weight:NSFontWeightLight];
    placeholderIcon.contentTintColor = NSColor.tertiaryLabelColor;
    self.placeholderLabel = DeskLabel(@"未选择账号", 13, NSFontWeightMedium);
    self.placeholderLabel.textColor = NSColor.secondaryLabelColor;
    self.placeholder = [NSStackView stackViewWithViews:@[placeholderIcon, self.placeholderLabel]];
    self.placeholder.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.placeholder.spacing = 10;

    for (NSView *view in @[self.scrollView, self.placeholder]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    NSClipView *clip = self.scrollView.contentView;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [document.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [document.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor],
        [self.placeholder.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [self.placeholder.centerYAnchor constraintEqualToAnchor:root.centerYAnchor]
    ]];
    [self applyMode];
    [self reloadAccount];
}

#pragma mark - Display

- (void)showAccountID:(NSString *)identifier selectionCount:(NSUInteger)count {
    BOOL sameAccount = identifier == self.accountID || [identifier isEqualToString:self.accountID];
    if (!sameAccount) {
        [self commitPendingEdits];
        self.proxyResult.stringValue = @"";
    }
    self.accountID = identifier;
    self.selectionCount = count;
    [self reloadAccount];
}

- (BOOL)isEditing:(NSView *)view {
    NSResponder *responder = self.view.window.firstResponder;
    if (responder == view) return YES;
    return [view isKindOfClass:NSControl.class] && [(NSControl *)view currentEditor] != nil;
}

- (void)reloadAccount {
    if (!self.isViewLoaded) return;
    Account *account = [self account];
    BOOL showsAccount = account && self.selectionCount <= 1;
    self.scrollView.hidden = !showsAccount;
    self.placeholder.hidden = showsAccount;
    if (!showsAccount) {
        self.placeholderLabel.stringValue = self.selectionCount > 1
            ? [NSString stringWithFormat:@"已选择 %lu 个账号", (unsigned long)self.selectionCount]
            : (self.coordinator.store.accounts.count ? @"未选择账号" : @"还没有账号");
        return;
    }

    NSDate *now = NSDate.date;
    self.avatar.name = account.name;
    self.avatar.seed = account.identifier;
    AccountStatus *status = [AccountStatus statusForAccount:account
        recommended:[self.coordinator.recommendedAccountID isEqualToString:account.identifier] now:now];
    BOOL attention = status.tone == AccountStatusToneCritical || status.tone == AccountStatusToneWarning;
    self.avatar.statusColor = attention ? DeskColorForTone(status.tone) : (account.signedIn.boolValue ? NSColor.systemGreenColor : nil);
    [self.statusPill showStatus:status showsNormal:NO];
    if (status.kind == AccountStatusRefreshFailed) self.statusPill.toolTip = account.refreshError;
    self.titleLabel.stringValue = account.name;
    self.subtitleLabel.stringValue = account.email.length ? account.email : @"未填写邮箱";
    self.planPill.text = account.plan ?: @"未获取订阅";
    self.planPill.tintColor = DeskColorForPlan(account.plan);
    AccountExpiryState state = [account expiryStateFromDate:now];
    self.expiryPill.text = state == AccountExpiryStateUnknown || status.kind == AccountStatusExpired ||
        status.kind == AccountStatusExpiringSoon ? @"" : [account expiryDescriptionFromDate:now];
    self.expiryPill.tintColor = DeskColorForExpiry(state);
    NSArray<Account *> *twins = AccountDuplicateEmails(self.coordinator.store.accounts)[account.email.lowercaseString];
    NSMutableArray *twinNames = [NSMutableArray array];
    for (Account *twin in twins) if (twin != account) [twinNames addObject:[NSString stringWithFormat:@"“%@”", twin.name]];
    self.duplicateLabel.hidden = twinNames.count == 0;
    self.duplicateLabel.stringValue = twinNames.count
        ? [NSString stringWithFormat:@"⚠︎ 此邮箱也用于 %@，可能是重复添加的账号", [twinNames componentsJoinedByString:@"、"]] : @"";

    if (![self isEditing:self.nameField]) self.nameField.stringValue = account.name;
    if (![self isEditing:self.emailField]) self.emailField.stringValue = account.email;
    if (![self isEditing:self.groupBox]) {
        [self.groupBox removeAllItems];
        [self.groupBox addItemsWithObjectValues:self.coordinator.store.groups];
        self.groupBox.stringValue = account.group;
    }
    [self.planPicker selectItemWithTitle:account.plan ?: UnknownPlanTitle];
    BOOL hasDate = account.expiresAt != nil;
    self.dateToggle.state = hasDate ? NSControlStateValueOn : NSControlStateValueOff;
    self.datePicker.enabled = hasDate;
    if (![self isEditing:self.datePicker]) self.datePicker.dateValue = AccountDateFromDayString(account.expiresAt) ?: now;
    self.sourceLabel.stringValue = [NSString stringWithFormat:@"订阅：%@ · 到期：%@",
        SourceName(account.planSource, account.plan), SourceName(account.expirySource, account.expiresAt)];
    if (![self isEditing:self.authField]) self.authField.stringValue = account.authURL;
    BOOL hasDefault = [NSUserDefaults.standardUserDefaults stringForKey:DefaultAuthorizationURLDefaultsKey].length > 0;
    self.authField.placeholderString = hasDefault ? @"未设置，使用默认授权链接" : @"未设置，打开时粘贴链接";
    if (![self isEditing:self.notesView]) self.notesView.string = account.notes;
    if (![self isEditing:self.tagsField]) self.tagsField.objectValue = account.tags;
    self.autoRenewToggle.state = account.autoRenew.boolValue ? NSControlStateValueOn : NSControlStateValueOff;
    self.autoRenewToggle.enabled = hasDate;
    if (![self isEditing:self.priceField]) self.priceField.objectValue = account.monthlyPrice;
    if (![self isEditing:self.currencyBox]) self.currencyBox.stringValue = account.currency;

    AccountUsage *usage = account.usage;
    BOOL hasUsage = usage.windows.count > 0;
    self.shortRow.hidden = !hasUsage;
    self.longRow.hidden = !hasUsage;
    if (hasUsage) {
        [self.shortRow showWindow:usage.shortWindow ?: usage.windows.firstObject title:@"5 小时"];
        [self.longRow showWindow:usage.longWindow title:@"每周"];
    }
    NSMutableArray *usageParts = [NSMutableArray array];
    if (account.refreshError.length) [usageParts addObject:account.refreshError];
    else if (!hasUsage) [usageParts addObject:@"尚未读取用量"];
    if (usage.unlimitedCredits) [usageParts addObject:@"额度不限"];
    else if (usage.creditBalance) [usageParts addObject:[@"额度余额 " stringByAppendingString:AccountFormatMoney(usage.creditBalance, nil)]];
    if (usage) [usageParts addObject:[@"更新于" stringByAppendingString:DeskRelativeTime(usage.fetchedAt)]];
    self.usageLabel.stringValue = [usageParts componentsJoinedByString:@" · "];
    self.usageLabel.textColor = account.refreshError.length ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    BOOL refreshing = [self.coordinator isRefreshingAccountID:account.identifier];
    self.refreshButton.enabled = !refreshing;
    if (refreshing) [self.refreshSpinner startAnimation:nil]; else [self.refreshSpinner stopAnimation:nil];
    BOOL readingBilling = [self.coordinator isReadingBillingForAccountID:account.identifier];
    self.billingButton.enabled = !readingBilling;
    self.billingButton.title = readingBilling ? @"正在读取账单…" : @"读取账单（档位与月费）";
    if (readingBilling) [self.billingSpinner startAnimation:nil]; else [self.billingSpinner stopAnimation:nil];

    NSArray<NSDictionary *> *points = [self.coordinator usageHistoryForAccountID:account.identifier];
    BOOL hasTrend = points.count >= 2;
    self.sparkline.points = points;
    self.sparkline.hidden = !hasTrend;
    self.trendCaption.hidden = !hasTrend;
    NSTimeInterval span = self.sparkline.span;
    NSString *period = span >= 2 * 86400 ? [NSString stringWithFormat:@"近 %.0f 天", ceil(span / 86400)]
                                         : [NSString stringWithFormat:@"近 %.0f 小时", ceil(span / 3600)];
    NSMutableAttributedString *legend = [self.trendCaption.attributedStringValue mutableCopy];
    NSRange label = [legend.string rangeOfString:@"剩余额度"];
    if (label.location != NSNotFound)
        [legend replaceCharactersInRange:NSMakeRange(0, label.location) withString:period];
    self.trendCaption.attributedStringValue = legend;
    NSString *prediction = nil;
    NSColor *predictionColor = NSColor.secondaryLabelColor;
    for (NSArray *candidate in @[@[@"long", usage.longWindow ?: [NSNull null]], @[@"short", usage.shortWindow ?: [NSNull null]]]) {
        if (![candidate[1] isKindOfClass:AccountUsageWindow.class]) continue;
        AccountUsageWindow *window = candidate[1];
        NSDate *exhaustion = [UsageHistory predictedExhaustionOfWindow:window key:candidate[0] points:points now:now];
        if (!exhaustion) continue;
        prediction = [NSString stringWithFormat:@"按近期速度，%@额度约在 %@ 用完%@", window.title, ShortDateTime(exhaustion),
            window.resetAt ? [NSString stringWithFormat:@"（%@重置）", ShortDateTime(window.resetAt)] : @""];
        predictionColor = NSColor.systemOrangeColor;
        break;
    }
    if (!prediction && hasTrend && hasUsage) prediction = @"按近期速度，额度可以用到重置";
    self.predictionLabel.stringValue = prediction ?: @"";
    self.predictionLabel.textColor = predictionColor;
    self.predictionLabel.hidden = prediction == nil;

    NSMutableArray *quotaSummary = [NSMutableArray array];
    if (usage.longWindow) [quotaSummary addObject:[NSString stringWithFormat:@"周 %.0f%%", usage.longWindow.remainingPercent]];
    if (usage.shortWindow) [quotaSummary addObject:[NSString stringWithFormat:@"5h %.0f%%", usage.shortWindow.remainingPercent]];
    self.sectionSummaries[@"usage"].stringValue = [quotaSummary componentsJoinedByString:@" · "];
    self.sectionSummaries[@"profile"].stringValue = account.group.length ? account.group : (account.email.length ? account.email : @"");
    self.sectionSummaries[@"subscription"].stringValue = account.monthlyPrice
        ? [NSString stringWithFormat:@"%@ · %@", account.planTitle, AccountFormatMoney(account.monthlyPrice, account.currency)] : account.planTitle;
    self.sectionSummaries[@"auth"].stringValue = account.authURL.length ? @"已保存链接" : @"";
    self.sectionSummaries[@"notes"].stringValue = [[account.notes componentsSeparatedByCharactersInSet:
        NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];

    NSString *defaultProxy = [NSUserDefaults.standardUserDefaults stringForKey:DefaultProxyDefaultsKey];
    if (![self isEditing:self.proxyField]) self.proxyField.stringValue = account.proxy;
    self.proxyField.placeholderString = defaultProxy.length ? [NSString stringWithFormat:@"使用默认代理 %@", defaultProxy] : @"跟随系统代理设置";
    self.sectionSummaries[@"network"].stringValue = account.proxy.length ? account.proxy : (defaultProxy.length ? @"默认代理" : @"系统代理");

    NSString *login = account.signedIn ? (account.signedIn.boolValue ? @"已登录" : @"未登录") : @"未检测";
    self.recordLabel.stringValue = [NSString stringWithFormat:@"创建时间　%@\n最近使用　%@\n登录状态　%@",
        DeskDateTimeString(account.createdAt), DeskRelativeTime(account.lastUsedAt), login];
}

- (void)commitPendingEdits {
    if (!self.isViewLoaded) return;
    NSWindow *window = self.view.window;
    NSResponder *responder = window.firstResponder;
    if ([responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:self.view])
        [window makeFirstResponder:nil];
}

#pragma mark - Editing

- (void)save { [self.coordinator.store commit]; }

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    Account *account = [self account];
    if (!account) return;
    id field = notification.object;
    if (field == self.nameField) {
        NSString *name = [self.nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) {
            NSBeep();
            self.nameField.stringValue = account.name;
            return;
        }
        if ([name isEqualToString:account.name]) return;
        account.name = name;
        [self save];
    } else if (field == self.emailField) {
        NSString *before = account.email;
        account.email = self.emailField.stringValue;
        if (![before isEqualToString:account.email]) [self save];
    } else if (field == self.groupBox) {
        [self groupChosen:self.groupBox];
    } else if (field == self.authField) {
        [self authLinkEdited];
    } else if (field == self.proxyField) {
        [self proxyEdited];
    } else if (field == self.tagsField) {
        NSArray *tags = AccountNormalizedTags(self.tagsField.objectValue);
        if ([tags isEqualToArray:account.tags]) return;
        account.tags = tags;
        [self save];
    } else if (field == self.priceField) {
        NSNumber *price = [self.priceField.objectValue isKindOfClass:NSNumber.class] ? self.priceField.objectValue : nil;
        if (price == account.monthlyPrice || [price isEqual:account.monthlyPrice]) return;
        account.monthlyPrice = price;
        [self save];
    } else if (field == self.currencyBox) {
        [self currencyChosen:self.currencyBox];
    }
}

- (void)currencyChosen:(id)sender {
    Account *account = [self account];
    if (!account) return;
    NSString *before = account.currency;
    account.currency = self.currencyBox.stringValue;
    if (![before isEqualToString:account.currency]) [self save];
}

- (void)autoRenewToggled:(id)sender {
    Account *account = [self account];
    if (!account) return;
    account.autoRenew = @(self.autoRenewToggle.state == NSControlStateValueOn);
    [self save];
}

- (void)refreshUsage:(id)sender {
    if (self.accountID) [self.coordinator refreshUsageForAccountIDs:@[self.accountID]];
}

- (void)readBilling:(id)sender {
    [self commitPendingEdits];
    if (self.accountID) [self.coordinator readBillingForAccountID:self.accountID];
}

- (void)openBillingPage:(id)sender {
    [self commitPendingEdits];
    if (self.accountID) [self.coordinator openBillingPageForAccountID:self.accountID];
}

- (void)proxyEdited {
    Account *account = [self account];
    if (!account) return;
    NSString *text = [self.proxyField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length && !AccountProxyComponents(text)) {
        NSBeep();
        self.proxyResult.stringValue = @"无法识别代理地址，未保存。示例：http://127.0.0.1:7890、socks5://127.0.0.1:1080";
        self.proxyResult.textColor = NSColor.systemRedColor;
        self.proxyField.stringValue = account.proxy;
        return;
    }
    self.proxyField.stringValue = text;
    if ([text isEqualToString:account.proxy]) return;
    account.proxy = text;
    self.proxyResult.stringValue = @"已保存，此账号已打开的页面会重新载入。";
    self.proxyResult.textColor = NSColor.secondaryLabelColor;
    [self save];
    [self.coordinator proxyDidChangeForAccountID:account.identifier];
}

- (void)testProxy:(id)sender {
    [self commitPendingEdits];
    Account *account = [self account];
    if (!account) return;
    NSString *identifier = account.identifier;
    NSString *proxy = EffectiveProxyText(account);
    self.proxyTestButton.enabled = NO;
    self.proxyResult.textColor = NSColor.secondaryLabelColor;
    self.proxyResult.stringValue = proxy.length ? [NSString stringWithFormat:@"正在通过 %@ 连接 chatgpt.com…", proxy]
                                                : @"正在按系统代理设置连接 chatgpt.com…";
    __weak typeof(self) weakSelf = self;
    [ProxyCheck checkProxyText:proxy completion:^(NSString *summary, NSString *failure) {
        AccountInspectorController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.proxyTestButton.enabled = YES;
        if (![strongSelf.accountID isEqualToString:identifier]) return;
        strongSelf.proxyResult.stringValue = summary ?: failure;
        strongSelf.proxyResult.textColor = failure ? NSColor.systemRedColor
            : ([summary containsString:@"不支持"] ? NSColor.systemOrangeColor : NSColor.systemGreenColor);
    }];
}

- (NSArray *)tokenField:(NSTokenField *)tokenField completionsForSubstring:(NSString *)substring
    indexOfToken:(NSInteger)tokenIndex indexOfSelectedItem:(NSInteger *)selectedIndex {
    NSMutableArray *matches = [NSMutableArray array];
    for (NSString *tag in self.coordinator.store.tags)
        if (!substring.length || [tag localizedCaseInsensitiveContainsString:substring]) [matches addObject:tag];
    return matches;
}

- (void)authLinkEdited {
    Account *account = [self account];
    NSString *text = [self.authField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURL *url = AuthorizationURLFromText(text);
    if (text.length && !url) {
        NSBeep();
        self.authField.stringValue = account.authURL;
        return;
    }
    NSString *value = url.absoluteString ?: @"";
    self.authField.stringValue = value;
    if ([value isEqualToString:account.authURL]) return;
    account.authURL = value;
    [self save];
}

- (void)openAuthorization:(id)sender {
    [self commitPendingEdits];
    if (self.accountID) [self.coordinator promptAuthorizationForAccountID:self.accountID];
}

- (void)groupChosen:(id)sender {
    Account *account = [self account];
    if (!account) return;
    NSString *before = account.group;
    account.group = self.groupBox.stringValue;
    if (![before isEqualToString:account.group]) [self save];
}

- (void)textDidEndEditing:(NSNotification *)notification {
    Account *account = [self account];
    if (!account || notification.object != self.notesView) return;
    if ([account.notes isEqualToString:self.notesView.string]) return;
    account.notes = self.notesView.string;
    [self save];
}

- (void)planChanged:(id)sender {
    Account *account = [self account];
    if (!account) return;
    NSString *plan = AccountCanonicalPlan(self.planPicker.titleOfSelectedItem);
    account.plan = plan;
    account.planSource = plan ? @"manual" : nil;
    [self save];
}

- (void)setExpiry:(NSDate *)date onAccount:(Account *)account {
    account.expiresAt = date ? AccountDayString(date) : nil;
    account.expirySource = date ? @"manual" : nil;
    if (!date) account.autoRenew = nil;
    [self save];
}

- (void)dateToggled:(id)sender {
    Account *account = [self account];
    if (!account) return;
    BOOL on = self.dateToggle.state == NSControlStateValueOn;
    [self setExpiry:on ? self.datePicker.dateValue : nil onAccount:account];
}

- (void)dateChanged:(id)sender {
    Account *account = [self account];
    if (!account || self.dateToggle.state != NSControlStateValueOn) return;
    NSString *day = AccountDayString(self.datePicker.dateValue);
    if ([day isEqualToString:account.expiresAt] && [account.expirySource isEqualToString:@"manual"]) return;
    [self setExpiry:self.datePicker.dateValue onAccount:account];
}

- (void)extendExpiry:(NSPopUpButton *)sender {
    Account *account = [self account];
    NSInteger months = sender.selectedItem.tag;
    if (!account || months <= 0) return;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *today = [calendar startOfDayForDate:NSDate.date];
    NSDate *base = AccountDateFromDayString(account.expiresAt);
    if (!base || [base compare:today] == NSOrderedAscending) base = today;
    NSDateComponents *step = [NSDateComponents new];
    step.month = months;
    [self setExpiry:[calendar dateByAddingComponents:step toDate:base options:0] onAccount:account];
}

- (void)clearLoginData:(id)sender {
    if (self.accountID) [self.coordinator clearLoginDataForAccountIDs:@[self.accountID]];
}

- (void)deleteAccount:(id)sender {
    if (self.accountID) [self.coordinator deleteAccountIDs:@[self.accountID]];
}
@end
