#import "AccountInspectorController.h"
#import "Account.h"
#import "AccountCardItem.h"
#import "AccountInsights.h"
#import "AuthorizationLink.h"
#import "DeskUI.h"
#import "NetworkDiagnosisWindowController.h"
#import "NetworkProxy.h"

static NSString *const UnknownPlanTitle = @"未获取";

/// Sections collapsed when nothing was saved yet for a mode: management favours the overview, browsing the essentials.
static NSArray<NSString *> *DefaultCollapsedSections(DeskMode mode) {
    return mode == DeskModeManagement ? @[@"network", @"notes", @"record"] : @[@"network", @"record"];
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

@interface AccountInspectorController () <NSTextFieldDelegate, NSComboBoxDelegate, NSTextViewDelegate, NSTokenFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
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
@property (nonatomic, strong) NSTextField *archiveBanner;
@property (nonatomic, strong) NSPopUpButton *lifecyclePopup;
@property (nonatomic, strong) NSTextField *lifecycleHint;
@property (nonatomic, strong) NSButton *archiveButton;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSStackView *> *sectionBodies;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *sectionHeaders;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *sectionSummaries;
@property (nonatomic, strong) DeskSparklineView *sparkline;
@property (nonatomic, strong) NSTextField *trendCaption;
@property (nonatomic, strong) NSTextField *predictionLabel;
@property (nonatomic, strong) NSButton *billingButton;
@property (nonatomic, strong) NSProgressIndicator *billingSpinner;
@property (nonatomic, strong) NSTextField *cnyLabel;
@property (nonatomic, strong) NSButton *completenessButton;
@property (nonatomic, copy) NSArray<NSString *> *missingFields;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSView *> *sectionViews;
@property (nonatomic, strong) NSTableView *authTable;
@property (nonatomic, strong) NSTextField *authSummary;
@property (nonatomic, copy) NSArray<AccountAuthorization *> *authRows;
@property (nonatomic, strong) NSComboBox *supplierBox;
@property (nonatomic, strong) NSComboBox *methodBox;
@property (nonatomic, strong) NSTextField *cardField;
@property (nonatomic, strong) NSTextField *cardHint;
@property (nonatomic, strong) NSTableView *paymentsTable;
@property (nonatomic, strong) NSScrollView *paymentsScroll;
@property (nonatomic, strong) NSTextField *paymentsSummary;
@property (nonatomic, copy) NSArray<AccountPayment *> *paymentRows;
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
        _sectionViews = [NSMutableDictionary dictionary];
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
    self.sectionViews[identifier] = section;
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
    self.archiveBanner = [NSTextField wrappingLabelWithString:@""];
    self.archiveBanner.font = [NSFont systemFontOfSize:11];
    self.archiveBanner.textColor = NSColor.secondaryLabelColor;
    self.duplicateLabel = [NSTextField wrappingLabelWithString:@""];
    self.duplicateLabel.font = [NSFont systemFontOfSize:11];
    self.duplicateLabel.textColor = NSColor.systemOrangeColor;
    self.completenessButton = [NSButton buttonWithTitle:@"" target:self action:@selector(revealMissingFields:)];
    self.completenessButton.bordered = NO;
    self.completenessButton.alignment = NSTextAlignmentLeft;
    self.completenessButton.toolTip = @"展开需要补充的分区";
    ((NSButtonCell *)self.completenessButton.cell).wraps = YES;
    ((NSButtonCell *)self.completenessButton.cell).lineBreakMode = NSLineBreakByWordWrapping;

    // Profile
    self.lifecyclePopup = [NSPopUpButton new];
    for (NSString *lifecycle in AccountLifecycles()) {
        [self.lifecyclePopup addItemWithTitle:AccountLifecycleTitle(lifecycle)];
        self.lifecyclePopup.lastItem.representedObject = lifecycle;
    }
    self.lifecyclePopup.target = self;
    self.lifecyclePopup.action = @selector(lifecycleChosen:);
    self.lifecyclePopup.toolTip = @"已停用、已封禁、已转让的账号不再提醒续费和额度，不计入每月支出和资料完整度";
    self.lifecycleHint = [NSTextField wrappingLabelWithString:@""];
    self.lifecycleHint.font = [NSFont systemFontOfSize:11];
    self.lifecycleHint.textColor = NSColor.secondaryLabelColor;
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

    self.cnyLabel = DeskLabel(@"", 11, NSFontWeightRegular);
    self.cnyLabel.textColor = NSColor.secondaryLabelColor;

    // Payment
    self.supplierBox = [NSComboBox new];
    self.supplierBox.placeholderString = @"选择或输入供应商";
    self.supplierBox.completes = YES;
    self.supplierBox.delegate = self;
    self.supplierBox.target = self;
    self.supplierBox.action = @selector(paymentFieldChosen:);
    self.methodBox = [NSComboBox new];
    self.methodBox.placeholderString = @"例如：信用卡";
    self.methodBox.completes = YES;
    self.methodBox.delegate = self;
    self.methodBox.target = self;
    self.methodBox.action = @selector(paymentFieldChosen:);
    self.cardField = [NSTextField new];
    self.cardField.placeholderString = @"卡号后 4 位";
    self.cardField.delegate = self;
    self.cardHint = DeskLabel(@"", 11, NSFontWeightRegular);
    self.cardHint.textColor = NSColor.secondaryLabelColor;
    self.paymentsTable = [NSTableView new];
    self.paymentsTable.style = NSTableViewStylePlain;
    self.paymentsTable.usesAlternatingRowBackgroundColors = YES;
    self.paymentsTable.rowHeight = 22;
    self.paymentsTable.intercellSpacing = NSMakeSize(6, 2);
    self.paymentsTable.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    for (NSArray *spec in @[@[@"date", @"日期", @86], @[@"amount", @"金额", @84], @[@"cny", @"折合 ¥", @76]]) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        column.title = spec[1];
        column.width = [spec[2] doubleValue];
        column.minWidth = 60;
        [self.paymentsTable addTableColumn:column];
    }
    self.paymentsTable.dataSource = self;
    self.paymentsTable.delegate = self;
    self.paymentsTable.target = self;
    self.paymentsTable.doubleAction = @selector(editClickedPayment:);
    self.paymentsTable.menu = [NSMenu new];
    self.paymentsTable.menu.delegate = self;
    self.paymentsScroll = [NSScrollView new];
    self.paymentsScroll.documentView = self.paymentsTable;
    self.paymentsScroll.hasVerticalScroller = YES;
    self.paymentsScroll.autohidesScrollers = YES;
    self.paymentsScroll.borderType = NSBezelBorder;
    [self.paymentsScroll.heightAnchor constraintEqualToConstant:118].active = YES;
    self.paymentsSummary = [NSTextField wrappingLabelWithString:@""];
    self.paymentsSummary.font = [NSFont systemFontOfSize:11];
    self.paymentsSummary.textColor = NSColor.secondaryLabelColor;
    NSButton *addButton = DeskButton(@"记一笔付款…", @"plus", self, @selector(addPayment:));
    addButton.toolTip = @"记录一次付款的日期和金额；可同时把续费 / 到期日顺延 1 个月";
    NSStackView *addPayment = [NSStackView stackViewWithViews:@[addButton]];

    // Network
    self.proxyField = [NSTextField new];
    self.proxyField.delegate = self;
    self.proxyField.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    self.proxyTestButton = DeskButton(@"测试连接", @"network", self, @selector(testProxy:));
    self.proxyTestButton.toolTip = @"通过此代理访问 chatgpt.com，显示出口 IP 和地区";
    NSButton *diagnoseButton = DeskButton(@"网络诊断…", @"stethoscope", self, @selector(diagnoseNetwork:));
    diagnoseButton.toolTip = @"通过此账号的代理逐个检查 ChatGPT 用到的域名，并给出排查建议";
    NSStackView *proxyButtons = [NSStackView stackViewWithViews:@[self.proxyTestButton, diagnoseButton]];
    proxyButtons.spacing = 8;
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
    authButton.toolTip = @"在此账号的会话中打开第三方提供的授权链接（⇧⌘L）";
    NSTextField *authHint = [NSTextField wrappingLabelWithString:
        @"用此账号授权第三方应用或网站的“使用 ChatGPT 登录”：粘贴对方给出的授权链接，授权后会自动跳回对方完成登录。"];
    authHint.font = [NSFont systemFontOfSize:11];
    authHint.textColor = NSColor.secondaryLabelColor;
    self.authTable = [NSTableView new];
    self.authTable.style = NSTableViewStylePlain;
    self.authTable.usesAlternatingRowBackgroundColors = YES;
    self.authTable.rowHeight = 22;
    self.authTable.intercellSpacing = NSMakeSize(6, 2);
    self.authTable.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    for (NSArray *spec in @[@[@"app", @"应用", @110], @[@"last", @"最近授权", @86], @[@"state", @"状态", @52]]) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        column.title = spec[1];
        column.width = [spec[2] doubleValue];
        column.minWidth = 46;
        [self.authTable addTableColumn:column];
    }
    self.authTable.dataSource = self;
    self.authTable.delegate = self;
    self.authTable.target = self;
    self.authTable.doubleAction = @selector(editClickedAuthorization:);
    self.authTable.menu = [NSMenu new];
    self.authTable.menu.delegate = self;
    NSScrollView *authScroll = [NSScrollView new];
    authScroll.documentView = self.authTable;
    authScroll.hasVerticalScroller = YES;
    authScroll.autohidesScrollers = YES;
    authScroll.borderType = NSBezelBorder;
    [authScroll.heightAnchor constraintEqualToConstant:96].active = YES;
    self.authSummary = [NSTextField wrappingLabelWithString:@""];
    self.authSummary.font = [NSFont systemFontOfSize:11];
    self.authSummary.textColor = NSColor.secondaryLabelColor;
    NSButton *addAuthorization = DeskButton(@"手动添加…", @"plus", self, @selector(addAuthorization:));
    addAuthorization.toolTip = @"补记在本应用之外完成的授权";
    NSStackView *authButtons = [NSStackView stackViewWithViews:@[authButton, addAuthorization]];
    authButtons.spacing = 8;

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
    self.archiveButton = DeskButton(@"归档账号", @"archivebox", self, @selector(toggleArchive:));
    NSButton *deleteButton = DeskButton(@"删除账号…", @"trash", self, @selector(deleteAccount:));
    deleteButton.contentTintColor = NSColor.systemRedColor;

    NSArray<NSView *> *fullWidth = @[
        self.archiveBanner,
        self.duplicateLabel,
        self.completenessButton,
        [self sectionWithID:@"usage" title:@"用量" views:@[self.shortRow, self.longRow, self.trendCaption, self.sparkline,
            self.predictionLabel, self.usageLabel, refreshRow]],
        [self sectionWithID:@"profile" title:@"资料" views:@[
            [self fieldWithCaption:@"名称" control:self.nameField],
            [self fieldWithCaption:@"邮箱" control:self.emailField],
            [self fieldWithCaption:@"分组" control:self.groupBox],
            [self fieldWithCaption:@"状态" control:self.lifecyclePopup], self.lifecycleHint,
            [self fieldWithCaption:@"标签" control:self.tagsField]]],
        [self sectionWithID:@"subscription" title:@"订阅" views:@[
            [self fieldWithCaption:@"级别" control:self.planPicker],
            self.dateToggle, dateRow, self.autoRenewToggle,
            [self fieldWithCaption:@"月费" control:priceRow], self.cnyLabel,
            self.sourceLabel, syncButton]],
        [self sectionWithID:@"payment" title:@"付款" views:@[
            [self fieldWithCaption:@"供应商" control:self.supplierBox],
            [self fieldWithCaption:@"付款方式" control:self.methodBox],
            [self fieldWithCaption:@"付款来源（卡尾号）" control:self.cardField], self.cardHint,
            [self fieldWithCaption:@"付款记录" control:self.paymentsScroll], self.paymentsSummary, addPayment]],
        [self sectionWithID:@"network" title:@"网络" views:@[
            [self fieldWithCaption:@"代理" control:self.proxyField], proxyButtons, self.proxyResult, proxyHint]],
        [self sectionWithID:@"auth" title:@"第三方授权" views:@[
            [self fieldWithCaption:@"已授权的应用" control:authScroll], self.authSummary,
            [self fieldWithCaption:@"授权链接" control:self.authField], authButtons, authHint]],
        [self sectionWithID:@"notes" title:@"备注" views:@[notesScroll]],
        [self sectionWithID:@"record" title:@"记录" views:@[self.recordLabel]],
        DeskSeparator(),
        sessionButton, clearButton, self.archiveButton, deleteButton
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
    [stack setCustomSpacing:6 afterView:self.archiveButton];
    NSStackView *usageBody = self.sectionBodies[@"usage"];
    [usageBody setCustomSpacing:8 afterView:self.shortRow];
    [usageBody setCustomSpacing:4 afterView:self.trendCaption];
    [self.sectionBodies[@"subscription"] setCustomSpacing:4 afterView:self.dateToggle];
    [self.sectionBodies[@"payment"] setCustomSpacing:2 afterView:self.cardHint];
    [self.sectionBodies[@"subscription"] setCustomSpacing:6 afterView:self.sourceLabel];
    [self.sectionBodies[@"auth"] setCustomSpacing:6 afterView:authButtons];
    [self.sectionBodies[@"network"] setCustomSpacing:4 afterView:proxyButtons];

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
    AccountStatus *status = [AccountStatus statusForAccount:account now:now];
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
    self.expiryPill.tintColor = account.tracked ? DeskColorForExpiry(state) : NSColor.systemGrayColor;
    NSArray<Account *> *twins = AccountDuplicateEmails(self.coordinator.store.accounts)[account.email.lowercaseString];
    NSMutableArray *twinNames = [NSMutableArray array];
    for (Account *twin in twins) if (twin != account) [twinNames addObject:[NSString stringWithFormat:@"“%@”", twin.name]];
    self.duplicateLabel.hidden = twinNames.count == 0;
    self.duplicateLabel.stringValue = twinNames.count
        ? [NSString stringWithFormat:@"⚠︎ 此邮箱也用于 %@，可能是重复添加的账号", [twinNames componentsJoinedByString:@"、"]] : @"";

    NSDateFormatter *day = [NSDateFormatter new];
    day.dateFormat = @"yyyy年M月d日";
    self.archiveBanner.hidden = !account.archived;
    self.archiveBanner.stringValue = account.archived ? [NSString stringWithFormat:@"已于 %@归档：不在侧边栏和菜单栏显示，不再提醒，不计入每月支出；"
        "历史付款仍计入费用报表。", [day stringFromDate:account.archivedAt]] : @"";
    self.archiveButton.title = account.archived ? @"取消归档" : @"归档账号";
    self.archiveButton.image = [NSImage imageWithSystemSymbolName:account.archived ? @"tray.and.arrow.up" : @"archivebox"
        accessibilityDescription:nil];
    self.archiveButton.toolTip = account.archived ? @"放回账号列表，恢复提醒与统计"
        : @"不再使用的账号可以归档：从列表中隐藏，保留资料和付款记录";
    [self.lifecyclePopup selectItemAtIndex:MAX(0, (NSInteger)[AccountLifecycles() indexOfObject:account.lifecycle])];
    NSString *since = account.lifecycleChangedAt ? [NSString stringWithFormat:@"自 %@起", [day stringFromDate:account.lifecycleChangedAt]] : @"";
    self.lifecycleHint.stringValue = account.retired
        ? [since stringByAppendingString:@"不再提醒续费和额度，不计入每月支出、资料完整度和自动刷新。"]
        : ([account.lifecycle isEqualToString:@"idle"] ? [since stringByAppendingString:@"闲置；提醒和统计照常。"] : @"");
    self.lifecycleHint.hidden = !self.lifecycleHint.stringValue.length;
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
    NSString *profileSummary = account.group.length ? account.group : (account.email.length ? account.email : @"");
    if (account.lifecycle.length)
        profileSummary = profileSummary.length ? [NSString stringWithFormat:@"%@ · %@", AccountLifecycleTitle(account.lifecycle), profileSummary]
                                               : AccountLifecycleTitle(account.lifecycle);
    self.sectionSummaries[@"profile"].stringValue = profileSummary;
    self.sectionSummaries[@"subscription"].stringValue = account.monthlyPrice
        ? [NSString stringWithFormat:@"%@ · %@", account.planTitle, AccountFormatMoney(account.monthlyPrice, account.currency)] : account.planTitle;
    [self reloadAuthorizationsOfAccount:account];
    NSArray<NSString *> *missing = AccountMissingFields(account, now);
    self.missingFields = missing;
    self.completenessButton.hidden = missing.count == 0;
    if (missing.count) {
        NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                                     NSForegroundColorAttributeName: NSColor.systemBrownColor};
        self.completenessButton.attributedTitle = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:
            @"资料缺 %lu 项：%@ ›", (unsigned long)missing.count, [missing componentsJoinedByString:@"、"]] attributes:attributes];
    }
    self.sectionSummaries[@"notes"].stringValue = [[account.notes componentsSeparatedByCharactersInSet:
        NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];

    NSString *defaultProxy = [NSUserDefaults.standardUserDefaults stringForKey:DefaultProxyDefaultsKey];
    if (![self isEditing:self.proxyField]) self.proxyField.stringValue = account.proxy;
    self.proxyField.placeholderString = defaultProxy.length ? [NSString stringWithFormat:@"使用默认代理 %@", defaultProxy] : @"跟随系统代理设置";
    self.sectionSummaries[@"network"].stringValue = account.proxy.length ? account.proxy : (defaultProxy.length ? @"默认代理" : @"系统代理");
    [self reloadPaymentsOfAccount:account];

    NSString *login = account.signedIn ? (account.signedIn.boolValue ? @"已登录" : @"未登录") : @"未检测";
    self.recordLabel.stringValue = [NSString stringWithFormat:@"创建时间　%@\n最近使用　%@\n登录状态　%@",
        DeskDateTimeString(account.createdAt), DeskRelativeTime(account.lastUsedAt), login];
}

- (void)reloadPaymentsOfAccount:(Account *)account {
    NSDictionary *rates = AccountExchangeRates();
    NSNumber *cny = AccountAmountInCNY(account.monthlyPrice, account.currency, rates);
    BOOL showsCNY = account.monthlyPrice && ![account.currency isEqualToString:@"CNY"];
    self.cnyLabel.hidden = !showsCNY;
    self.cnyLabel.stringValue = cny ? [NSString stringWithFormat:@"≈ %@ / 月", AccountFormatCNY(cny)]
        : (account.currency.length ? [NSString stringWithFormat:@"未设置 %@ 汇率，可在“设置 → 费用”中填写", account.currency]
                                   : @"填写币种后可折合人民币");
    self.cnyLabel.textColor = cny ? NSColor.secondaryLabelColor : NSColor.systemOrangeColor;

    AccountStore *store = self.coordinator.store;
    if (![self isEditing:self.supplierBox]) {
        [self.supplierBox removeAllItems];
        [self.supplierBox addItemsWithObjectValues:store.suppliers];
        self.supplierBox.stringValue = account.supplier;
    }
    if (![self isEditing:self.methodBox]) {
        [self.methodBox removeAllItems];
        [self.methodBox addItemsWithObjectValues:store.paymentMethods];
        self.methodBox.stringValue = account.paymentMethod;
    }
    if (![self isEditing:self.cardField]) self.cardField.stringValue = account.cardLast4;
    if (![self isEditing:self.cardField]) {
        self.cardHint.stringValue = @"只保存卡号后 4 位";
        self.cardHint.textColor = NSColor.tertiaryLabelColor;
    }

    self.paymentRows = account.payments;
    [self.paymentsTable reloadData];
    double total = 0;
    NSMutableOrderedSet *missing = [NSMutableOrderedSet orderedSet];
    for (AccountPayment *payment in account.payments) {
        NSNumber *converted = AccountAmountInCNY(payment.amount, payment.currency, rates);
        if (converted) total += converted.doubleValue;
        else [missing addObject:payment.currency.length ? payment.currency : @"未填币种"];
    }
    AccountPayment *last = account.lastPayment;
    if (!last) {
        self.paymentsSummary.stringValue = @"还没有付款记录。每次付款后记一笔，可同时顺延续费 / 到期日；读取账单时会自动导入直接在 ChatGPT 付款的扣款记录。";
    } else {
        NSMutableString *summary = [NSMutableString stringWithFormat:@"共 %lu 笔，累计 %@", (unsigned long)account.payments.count,
            AccountFormatCNY(@(total))];
        if (missing.count) [summary appendFormat:@"（%@ 未设汇率，未计入）", [missing.array componentsJoinedByString:@"、"]];
        [summary appendFormat:@" · 上次付款 %@", last.date];
        self.paymentsSummary.stringValue = summary;
    }
    NSString *info = account.paymentSummary;
    self.sectionSummaries[@"payment"].stringValue = info.length ? info : (last ? [@"上次付款 " stringByAppendingString:last.date] : @"未填写");
}

- (void)reloadAuthorizationsOfAccount:(Account *)account {
    self.authRows = account.authorizations;
    [self.authTable reloadData];
    NSUInteger active = account.activeAuthorizations.count, revoked = account.authorizations.count - active;
    self.authSummary.stringValue = account.authorizations.count
        ? [NSString stringWithFormat:@"已授权 %lu 个应用%@。双击可改名或加备注，右键可标记为已撤销。", (unsigned long)active,
            revoked ? [NSString stringWithFormat:@"，%lu 个已撤销", (unsigned long)revoked] : @""]
        : @"还没有授权记录。用“打开授权链接…”完成授权后会自动记下；在别处授权过的可以手动添加。";
    self.sectionSummaries[@"auth"].stringValue = active ? [[account.activeAuthorizations valueForKey:@"appName"]
        componentsJoinedByString:@"、"] : (account.authURL.length ? @"已保存链接" : @"");
}

/// Expands the sections holding what is missing and scrolls to the first.
- (void)revealMissingFields:(id)sender {
    NSDictionary *sections = @{@"邮箱": @"profile", @"订阅级别": @"subscription", @"续费 / 到期日期": @"subscription",
        @"月费": @"subscription", @"币种": @"subscription"};
    NSMutableOrderedSet *targets = [NSMutableOrderedSet orderedSet];
    for (NSString *field in self.missingFields) [targets addObject:sections[field] ?: @"payment"];
    NSMutableSet *collapsed = [self.collapsedSections mutableCopy];
    [collapsed minusSet:targets.set];
    [NSUserDefaults.standardUserDefaults setObject:collapsed.allObjects forKey:CollapsedDefaultsKey(self.coordinator.mode)];
    [self applyMode];
    [self.view layoutSubtreeIfNeeded];
    NSView *first = self.sectionViews[targets.firstObject];
    if (first) [first scrollRectToVisible:first.bounds];
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
    } else if (field == self.supplierBox || field == self.methodBox) {
        [self paymentFieldChosen:field];
    } else if (field == self.cardField) {
        [self cardEdited];
    } else if (field == self.tagsField) {
        NSArray *tags = AccountNormalizedTags(self.tagsField.objectValue);
        if ([tags isEqualToArray:account.tags]) return;
        account.tags = tags;
        [self save];
    } else if (field == self.priceField) {
        NSNumber *price = [self.priceField.objectValue isKindOfClass:NSNumber.class] ? self.priceField.objectValue : nil;
        if (price == account.monthlyPrice || [price isEqual:account.monthlyPrice]) return;
        account.monthlyPrice = price;
        account.priceSource = price ? @"manual" : nil;
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
    if ([before isEqualToString:account.currency]) return;
    if (account.monthlyPrice) account.priceSource = @"manual";
    [self save];
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

- (void)paymentFieldChosen:(id)sender {
    Account *account = [self account];
    if (!account) return;
    NSString *supplier = account.supplier, *method = account.paymentMethod;
    if (sender == self.supplierBox) account.supplier = self.supplierBox.stringValue;
    if (sender == self.methodBox) account.paymentMethod = self.methodBox.stringValue;
    if ([supplier isEqualToString:account.supplier] && [method isEqualToString:account.paymentMethod]) return;
    [account applyListedPrice];
    [self save];
}

- (void)cardEdited {
    Account *account = [self account];
    if (!account) return;
    NSString *text = [self.cardField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *last4 = AccountCardLast4(text);
    if (text.length && !last4.length) {
        NSBeep();
        self.cardHint.stringValue = @"请输入卡号后 4 位数字";
        self.cardHint.textColor = NSColor.systemRedColor;
        self.cardField.stringValue = account.cardLast4;
        return;
    }
    NSUInteger digits = 0;
    for (NSUInteger index = 0; index < text.length; index++)
        if ([NSCharacterSet.decimalDigitCharacterSet characterIsMember:[text characterAtIndex:index]]) digits++;
    self.cardField.stringValue = last4;
    self.cardHint.stringValue = digits > 4 ? @"已只保留后 4 位，完整卡号不会保存" : @"只保存卡号后 4 位";
    self.cardHint.textColor = digits > 4 ? NSColor.systemOrangeColor : NSColor.tertiaryLabelColor;
    if ([last4 isEqualToString:account.cardLast4]) return;
    account.cardLast4 = last4;
    [self save];
}

#pragma mark - Payment records

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)(tableView == self.authTable ? self.authRows.count : self.paymentRows.count);
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView == self.authTable) return [self authorizationCellForColumn:tableColumn.identifier row:row];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"PaymentCell" owner:self];
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"PaymentCell";
        NSTextField *label = DeskLabel(@"", 11.5, NSFontWeightRegular);
        label.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
        [cell addSubview:label];
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
        ]];
    }
    AccountPayment *payment = self.paymentRows[(NSUInteger)row];
    NSString *column = tableColumn.identifier;
    cell.textField.textColor = NSColor.labelColor;
    if ([column isEqualToString:@"date"]) {
        cell.textField.stringValue = payment.date;
    } else if ([column isEqualToString:@"amount"]) {
        cell.textField.stringValue = [payment.currency isEqualToString:@"CNY"] ? AccountFormatCNY(payment.amount)
            : AccountFormatMoney(payment.amount, payment.currency);
    } else {
        NSNumber *cny = AccountAmountInCNY(payment.amount, payment.currency, AccountExchangeRates());
        cell.textField.stringValue = [payment.currency isEqualToString:@"CNY"] ? @"—" : (cny ? AccountFormatCNY(cny) : @"未设汇率");
        cell.textField.textColor = cny ? NSColor.secondaryLabelColor : NSColor.systemOrangeColor;
    }
    NSMutableArray *tip = [NSMutableArray array];
    for (NSString *part in @[payment.supplier, payment.paymentMethod,
                             payment.cardLast4.length ? [@"尾号 " stringByAppendingString:payment.cardLast4] : @"", payment.note])
        if (part.length) [tip addObject:part];
    [tip addObject:[payment.source isEqualToString:@"page"] ? @"来自账单页" : @"手动记录"];
    cell.toolTip = [tip componentsJoinedByString:@" · "];
    return cell;
}

- (NSTableCellView *)authorizationCellForColumn:(NSString *)column row:(NSInteger)row {
    NSTableCellView *cell = [self.authTable makeViewWithIdentifier:@"AuthorizationCell" owner:self];
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"AuthorizationCell";
        NSTextField *label = DeskLabel(@"", 11.5, NSFontWeightRegular);
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [cell addSubview:label];
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
        ]];
    }
    AccountAuthorization *item = self.authRows[(NSUInteger)row];
    cell.textField.textColor = item.revoked ? NSColor.tertiaryLabelColor : NSColor.labelColor;
    if ([column isEqualToString:@"app"]) {
        cell.textField.stringValue = item.appName.length ? item.appName : @"未命名应用";
    } else if ([column isEqualToString:@"last"]) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd";
        cell.textField.stringValue = [formatter stringFromDate:item.lastAuthorizedAt];
    } else {
        cell.textField.stringValue = item.revoked ? @"已撤销" : @"已授权";
        cell.textField.textColor = item.revoked ? NSColor.secondaryLabelColor : NSColor.systemGreenColor;
    }
    NSMutableArray *tip = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"首次 %@ · 最近 %@ · 共 %ld 次",
        DeskDateTimeString(item.firstAuthorizedAt), DeskDateTimeString(item.lastAuthorizedAt), (long)item.count]];
    if (item.redirect.length) [tip addObject:[@"回调：" stringByAppendingString:item.redirect]];
    if (item.clientID.length) [tip addObject:[@"client_id：" stringByAppendingString:item.clientID]];
    if (item.scope.length) [tip addObject:[@"权限：" stringByAppendingString:item.scope]];
    if (item.note.length) [tip addObject:[@"备注：" stringByAppendingString:item.note]];
    if (item.revoked) [tip addObject:[@"撤销于 " stringByAppendingString:DeskDateTimeString(item.revokedAt)]];
    cell.toolTip = [tip componentsJoinedByString:@"\n"];
    return cell;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == self.authTable.menu) {
        [self updateAuthorizationMenu:menu];
        return;
    }
    [menu removeAllItems];
    NSInteger row = self.paymentsTable.clickedRow;
    if (row < 0 || row >= (NSInteger)self.paymentRows.count) {
        [menu addItemWithTitle:@"记一笔付款…" action:@selector(addPayment:) keyEquivalent:@""].target = self;
        return;
    }
    NSMenuItem *edit = [menu addItemWithTitle:@"编辑…" action:@selector(editPaymentFromMenu:) keyEquivalent:@""];
    NSMenuItem *remove = [menu addItemWithTitle:@"删除" action:@selector(deletePaymentFromMenu:) keyEquivalent:@""];
    for (NSMenuItem *item in @[edit, remove]) {
        item.target = self;
        item.representedObject = self.paymentRows[(NSUInteger)row];
    }
}

#pragma mark - Authorization records

- (void)updateAuthorizationMenu:(NSMenu *)menu {
    [menu removeAllItems];
    NSInteger row = self.authTable.clickedRow;
    if (row < 0 || row >= (NSInteger)self.authRows.count) {
        [menu addItemWithTitle:@"手动添加…" action:@selector(addAuthorization:) keyEquivalent:@""].target = self;
        return;
    }
    AccountAuthorization *item = self.authRows[(NSUInteger)row];
    NSMenuItem *edit = [menu addItemWithTitle:@"编辑…" action:@selector(editAuthorizationFromMenu:) keyEquivalent:@""];
    NSMenuItem *toggle = [menu addItemWithTitle:item.revoked ? @"恢复为已授权" : @"标记为已撤销" action:@selector(toggleRevokedFromMenu:)
        keyEquivalent:@""];
    NSMenuItem *copy = item.redirect.length
        ? [menu addItemWithTitle:@"复制回调地址" action:@selector(copyRedirectFromMenu:) keyEquivalent:@""] : nil;
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *remove = [menu addItemWithTitle:@"删除记录" action:@selector(deleteAuthorizationFromMenu:) keyEquivalent:@""];
    for (NSMenuItem *menuItem in @[edit, toggle, remove]) {
        menuItem.target = self;
        menuItem.representedObject = item;
    }
    copy.target = self;
    copy.representedObject = item;
}

- (void)editClickedAuthorization:(id)sender {
    NSInteger row = self.authTable.clickedRow;
    if (row >= 0 && row < (NSInteger)self.authRows.count) [self presentEditorForAuthorization:self.authRows[(NSUInteger)row] isNew:NO];
}

- (void)editAuthorizationFromMenu:(NSMenuItem *)sender { [self presentEditorForAuthorization:sender.representedObject isNew:NO]; }

- (void)toggleRevokedFromMenu:(NSMenuItem *)sender {
    AccountAuthorization *item = sender.representedObject;
    item.revokedAt = item.revoked ? nil : NSDate.date;
    [self save];
}

- (void)copyRedirectFromMenu:(NSMenuItem *)sender {
    AccountAuthorization *item = sender.representedObject;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:item.redirect forType:NSPasteboardTypeString];
}

- (void)deleteAuthorizationFromMenu:(NSMenuItem *)sender {
    AccountAuthorization *item = sender.representedObject;
    Account *account = [self account];
    if (!account || !item) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"删除“%@”的授权记录？", item.appName.length ? item.appName : @"未命名应用"];
    alert.informativeText = @"只删除本机的记录，不会撤销第三方应用已获得的授权；需要撤销时请在对方应用或 ChatGPT 设置中操作。";
    [alert addButtonWithTitle:@"删除"].hasDestructiveAction = YES;
    [alert addButtonWithTitle:@"取消"];
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSMutableArray *authorizations = [account.authorizations mutableCopy];
        [authorizations removeObject:item];
        account.authorizations = authorizations;
        [weakSelf save];
    }];
}

- (void)addAuthorization:(id)sender {
    [self commitPendingEdits];
    if (![self account]) return;
    AccountAuthorization *item = [AccountAuthorization new];
    item.appName = AuthorizationDefaultAppName();
    [self presentEditorForAuthorization:item isNew:YES];
}

- (void)presentEditorForAuthorization:(AccountAuthorization *)item isNew:(BOOL)isNew {
    Account *account = [self account];
    if (!account) return;
    NSTextField *name = [NSTextField new];
    name.stringValue = item.appName;
    name.placeholderString = @"应用或网站名称";
    [name.widthAnchor constraintEqualToConstant:240].active = YES;
    NSDatePicker *date = [NSDatePicker new];
    date.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    date.datePickerElements = NSDatePickerElementFlagYearMonthDay;
    date.dateValue = item.lastAuthorizedAt ?: NSDate.date;
    NSTextField *note = [NSTextField new];
    note.stringValue = item.note;
    note.placeholderString = @"可选，例如用途、授权的权限";
    [note.widthAnchor constraintEqualToConstant:240].active = YES;
    NSButton *revoked = [NSButton checkboxWithTitle:@"已撤销" target:nil action:nil];
    revoked.state = item.revoked ? NSControlStateValueOn : NSControlStateValueOff;
    NSMutableArray *rows = [NSMutableArray arrayWithArray:@[
        @[DeskLabel(@"名称", 13, NSFontWeightRegular), name],
        @[DeskLabel(@"授权日期", 13, NSFontWeightRegular), date],
        @[DeskLabel(@"备注", 13, NSFontWeightRegular), note],
        @[[NSGridCell emptyContentView], revoked]]];
    if (item.redirect.length) {
        NSTextField *redirect = DeskLabel(item.redirect, 11, NSFontWeightRegular);
        redirect.textColor = NSColor.secondaryLabelColor;
        redirect.selectable = YES;
        redirect.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [redirect.widthAnchor constraintLessThanOrEqualToConstant:240].active = YES;
        [rows insertObject:@[DeskLabel(@"回调地址", 13, NSFontWeightRegular), redirect] atIndex:1];
    }
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 8;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.frame = NSMakeRect(0, 0, 330, grid.fittingSize.height);
    NSAlert *alert = [NSAlert new];
    alert.messageText = isNew ? [NSString stringWithFormat:@"为“%@”添加授权记录", account.name] : @"编辑授权记录";
    alert.informativeText = isNew ? @"记录在本应用之外用此账号授权过的第三方应用或网站。" : @"只修改本机的记录。";
    alert.accessoryView = grid;
    [alert addButtonWithTitle:isNew ? @"添加" : @"保存"];
    [alert addButtonWithTitle:@"取消"];
    [alert layout];
    alert.window.initialFirstResponder = name;
    NSString *identifier = account.identifier;
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        AccountInspectorController *strongSelf = weakSelf;
        Account *current = [strongSelf.coordinator.store accountWithID:identifier];
        NSString *title = [name.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!current || response != NSAlertFirstButtonReturn) return;
        if (!title.length) { NSBeep(); return; }
        item.appName = title;
        item.note = note.stringValue;
        BOOL wasRevoked = item.revoked;
        if (revoked.state == NSControlStateValueOn && !wasRevoked) item.revokedAt = NSDate.date;
        if (revoked.state == NSControlStateValueOff) item.revokedAt = nil;
        if (isNew) {
            item.source = @"manual";
            item.firstAuthorizedAt = date.dateValue;
            item.lastAuthorizedAt = date.dateValue;
            current.authorizations = [current.authorizations arrayByAddingObject:item];
        } else {
            // A manual record's date is what the user says; recorded ones keep their timestamps unless changed.
            if (![AccountDayString(date.dateValue) isEqualToString:AccountDayString(item.lastAuthorizedAt)]) {
                item.lastAuthorizedAt = date.dateValue;
                if ([item.firstAuthorizedAt compare:date.dateValue] == NSOrderedDescending) item.firstAuthorizedAt = date.dateValue;
            }
            current.authorizations = current.authorizations;
        }
        [strongSelf save];
    }];
}

- (void)addPayment:(id)sender { [self presentAddPaymentWithDate:nil]; }

- (void)presentAddPaymentWithDate:(NSString *)date {
    [self commitPendingEdits];
    Account *account = [self account];
    if (!account) return;
    AccountPayment *payment = [AccountPayment new];
    NSDictionary *charge = account.expectedCharge;
    payment.amount = charge[@"amount"] ?: @0;
    payment.currency = [charge[@"currency"] length] ? charge[@"currency"] : @"CNY";
    if (AccountDateFromDayString(date)) payment.date = date;
    payment.supplier = account.supplier;
    payment.paymentMethod = account.paymentMethod;
    payment.cardLast4 = account.cardLast4;
    [self presentEditorForPayment:payment isNew:YES];
}

- (void)editClickedPayment:(id)sender {
    NSInteger row = self.paymentsTable.clickedRow;
    if (row >= 0 && row < (NSInteger)self.paymentRows.count) [self presentEditorForPayment:self.paymentRows[(NSUInteger)row] isNew:NO];
}

- (void)editPaymentFromMenu:(NSMenuItem *)sender { [self presentEditorForPayment:sender.representedObject isNew:NO]; }

- (void)deletePaymentFromMenu:(NSMenuItem *)sender {
    AccountPayment *payment = sender.representedObject;
    Account *account = [self account];
    if (!account || !payment) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"删除 %@ 的付款记录？", payment.date];
    alert.informativeText = AccountFormatMoney(payment.amount, payment.currency);
    [alert addButtonWithTitle:@"删除"].hasDestructiveAction = YES;
    [alert addButtonWithTitle:@"取消"];
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSMutableArray *payments = [account.payments mutableCopy];
        [payments removeObject:payment];
        account.payments = payments;
        [weakSelf save];
    }];
}

- (NSComboBox *)comboWithValues:(NSArray<NSString *> *)values value:(NSString *)value placeholder:(NSString *)placeholder {
    NSComboBox *combo = [NSComboBox new];
    [combo addItemsWithObjectValues:values];
    combo.stringValue = value ?: @"";
    combo.placeholderString = placeholder;
    combo.completes = YES;
    [combo.widthAnchor constraintEqualToConstant:220].active = YES;
    return combo;
}

- (void)presentEditorForPayment:(AccountPayment *)payment isNew:(BOOL)isNew {
    Account *account = [self account];
    if (!account) return;
    AccountStore *store = self.coordinator.store;
    NSDatePicker *date = [NSDatePicker new];
    date.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    date.datePickerElements = NSDatePickerElementFlagYearMonthDay;
    date.dateValue = AccountDateFromDayString(payment.date) ?: NSDate.date;
    NSTextField *amount = [NSTextField new];
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.minimum = @0;
    formatter.maximumFractionDigits = 2;
    formatter.lenient = YES;
    amount.formatter = formatter;
    amount.objectValue = payment.amount.doubleValue > 0 ? payment.amount : nil;
    amount.placeholderString = @"金额";
    [amount.widthAnchor constraintEqualToConstant:120].active = YES;
    NSComboBox *currency = [self comboWithValues:@[@"CNY", @"USD", @"PHP", @"HKD", @"TWD", @"EUR", @"GBP", @"JPY", @"SGD"]
        value:payment.currency placeholder:@"币种"];
    [currency.widthAnchor constraintEqualToConstant:92].active = YES;
    NSStackView *money = [NSStackView stackViewWithViews:@[amount, currency]];
    money.spacing = 8;
    NSComboBox *supplier = [self comboWithValues:store.suppliers value:payment.supplier placeholder:@"供应商"];
    NSComboBox *method = [self comboWithValues:store.paymentMethods value:payment.paymentMethod placeholder:@"付款方式"];
    NSTextField *card = [NSTextField new];
    card.stringValue = payment.cardLast4;
    card.placeholderString = @"卡号后 4 位";
    [card.widthAnchor constraintEqualToConstant:120].active = YES;
    NSTextField *note = [NSTextField new];
    note.stringValue = payment.note;
    note.placeholderString = @"可选，例如订单号";
    [note.widthAnchor constraintEqualToConstant:220].active = YES;
    NSButton *extend = [NSButton checkboxWithTitle:@"同时把续费 / 到期日顺延 1 个月" target:nil action:nil];
    extend.state = isNew && account.expiresAt && !account.autoRenew.boolValue ? NSControlStateValueOn : NSControlStateValueOff;
    extend.hidden = !isNew;

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[DeskLabel(@"日期", 13, NSFontWeightRegular), date],
        @[DeskLabel(@"金额", 13, NSFontWeightRegular), money],
        @[DeskLabel(@"供应商", 13, NSFontWeightRegular), supplier],
        @[DeskLabel(@"付款方式", 13, NSFontWeightRegular), method],
        @[DeskLabel(@"卡尾号", 13, NSFontWeightRegular), card],
        @[DeskLabel(@"备注", 13, NSFontWeightRegular), note],
        @[[NSGridCell emptyContentView], extend]]];
    grid.rowSpacing = 8;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.frame = NSMakeRect(0, 0, 340, grid.fittingSize.height);

    NSAlert *alert = [NSAlert new];
    alert.messageText = isNew ? [NSString stringWithFormat:@"为“%@”记一笔付款", account.name] : @"编辑付款记录";
    alert.informativeText = @"付款来源只保存卡号后 4 位。";
    alert.accessoryView = grid;
    [alert addButtonWithTitle:isNew ? @"记录" : @"保存"];
    [alert addButtonWithTitle:@"取消"];
    [alert layout];
    alert.window.initialFirstResponder = amount;
    NSString *identifier = account.identifier;
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        AccountInspectorController *strongSelf = weakSelf;
        Account *current = [strongSelf.coordinator.store accountWithID:identifier];
        if (!current || response != NSAlertFirstButtonReturn) return;
        NSNumber *value = [amount.objectValue isKindOfClass:NSNumber.class] ? amount.objectValue : nil;
        if (value.doubleValue <= 0) {
            NSBeep();
            return;
        }
        payment.date = AccountDayString(date.dateValue);
        payment.amount = value;
        payment.currency = currency.stringValue;
        payment.supplier = supplier.stringValue;
        payment.paymentMethod = method.stringValue;
        payment.cardLast4 = card.stringValue;
        payment.note = note.stringValue;
        NSMutableArray *payments = [current.payments mutableCopy];
        if (isNew) [payments addObject:payment];
        current.payments = payments;
        if (isNew && extend.state == NSControlStateValueOn) {
            NSCalendar *calendar = NSCalendar.currentCalendar;
            NSDate *today = [calendar startOfDayForDate:NSDate.date];
            NSDate *base = AccountDateFromDayString(current.expiresAt);
            if (!base || [base compare:today] == NSOrderedAscending) base = today;
            current.expiresAt = AccountDayString([calendar dateByAddingUnit:NSCalendarUnitMonth value:1 toDate:base options:0]);
            current.expirySource = @"manual";
        }
        [strongSelf save];
    }];
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

- (void)diagnoseNetwork:(id)sender {
    [self commitPendingEdits];
    Account *account = [self account];
    if (account) [NetworkDiagnosisWindowController showForAccount:account];
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
    [account applyListedPrice];
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

- (void)lifecycleChosen:(NSPopUpButton *)sender {
    if (self.accountID) [self.coordinator setLifecycle:sender.selectedItem.representedObject ?: @"" forAccountIDs:@[self.accountID]];
}

- (void)toggleArchive:(id)sender {
    [self commitPendingEdits];
    Account *account = [self account];
    if (account) [self.coordinator setArchived:!account.archived forAccountIDs:@[account.identifier]];
}

- (void)deleteAccount:(id)sender {
    if (self.accountID) [self.coordinator deleteAccountIDs:@[self.accountID]];
}
@end
