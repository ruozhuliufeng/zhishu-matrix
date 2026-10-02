#import "ManagementController.h"
#import "Account.h"
#import "AccountCardItem.h"
#import "AccountInsights.h"
#import "DeskUI.h"
#import "ManagementScope.h"
#import "RenewalCalendarView.h"

typedef NS_ENUM(NSInteger, PlanFilter) {
    PlanFilterAll = 0,
    PlanFilterPaid,
    PlanFilterUnknown,
    PlanFilterSpecific,
    PlanFilterFamily,
};

typedef NS_ENUM(NSInteger, ManagementView) {
    ManagementViewCards = 0,
    ManagementViewList,
    ManagementViewCalendar,
};

static NSString *const ViewModeDefaultsKey = @"managementViewMode";

static NSArray<NSArray *> *ColumnSpecs(void) {
    // identifier, title, width, minimum width, sort key, hidden by default
    return @[
        @[@"name", @"账号", @150, @110, @"name", @NO],
        @[@"status", @"状态", @96, @76, @"status", @NO],
        @[@"plan", @"订阅", @80, @66, @"plan", @NO],
        @[@"tags", @"标签", @110, @84, @"tags", @NO],
        @[@"short", @"5 小时", @104, @84, @"short", @YES],
        @[@"long", @"每周", @104, @84, @"long", @NO],
        @[@"renewal", @"续费 / 到期", @130, @112, @"expiresAt", @NO],
        @[@"cny", @"月费（¥）", @96, @84, @"cny", @NO],
        @[@"supplier", @"供应商", @96, @70, @"supplier", @NO],
        @[@"card", @"卡尾号", @64, @56, @"card", @NO],
        @[@"paymentMethod", @"付款方式", @80, @60, @"paymentMethod", @YES],
        @[@"lastPayment", @"上次付款", @92, @80, @"lastPayment", @YES],
        @[@"price", @"月费（原币）", @112, @104, @"price", @YES],
        @[@"email", @"邮箱", @170, @110, @"email", @YES],
        @[@"group", @"分组", @80, @48, @"group", @YES],
        @[@"signedIn", @"登录", @56, @48, @"signedIn", @YES],
        @[@"lastUsedAt", @"最近使用", @84, @60, @"lastUsedAt", @YES],
        @[@"notes", @"备注", @150, @60, @"notes", @YES],
    ];
}

static id SortValue(Account *account, NSString *key, NSDate *now) {
    if ([key isEqualToString:@"name"]) return account.name;
    if ([key isEqualToString:@"status"]) return @([AccountStatus statusForAccount:account now:now].kind);
    if ([key isEqualToString:@"plan"]) return account.planRank ? @(account.planRank) : nil;
    if ([key isEqualToString:@"tags"]) return account.tags.firstObject;
    if ([key isEqualToString:@"short"]) return account.usage.shortWindow ? @(account.usage.shortWindow.remainingPercent) : nil;
    if ([key isEqualToString:@"long"]) return account.usage.longWindow ? @(account.usage.longWindow.remainingPercent) : nil;
    if ([key isEqualToString:@"expiresAt"]) return account.expiresAt;
    if ([key isEqualToString:@"price"]) return account.monthlyPrice;
    if ([key isEqualToString:@"cny"]) return AccountAmountInCNY(account.monthlyPrice, account.currency, AccountExchangeRates());
    if ([key isEqualToString:@"supplier"]) return account.supplier.length ? account.supplier : nil;
    if ([key isEqualToString:@"card"]) return account.cardLast4.length ? account.cardLast4 : nil;
    if ([key isEqualToString:@"paymentMethod"]) return account.paymentMethod.length ? account.paymentMethod : nil;
    if ([key isEqualToString:@"lastPayment"]) return account.lastPayment.date;
    if ([key isEqualToString:@"email"]) return account.email.length ? account.email : nil;
    if ([key isEqualToString:@"group"]) return account.group.length ? account.group : nil;
    if ([key isEqualToString:@"signedIn"]) return account.signedIn;
    if ([key isEqualToString:@"lastUsedAt"]) return account.lastUsedAt;
    if ([key isEqualToString:@"notes"]) return account.notes.length ? account.notes : nil;
    return nil;
}

/// Sort choices offered above the cards; they map onto the table's sort descriptors.
static NSArray<NSArray *> *SortChoices(void) {
    return @[@[@"默认顺序", @"", @YES], @[@"需处理优先", @"status", @NO], @[@"每周额度（多→少）", @"long", @NO],
             @[@"5 小时额度（多→少）", @"short", @NO],
             @[@"续费 / 到期日期", @"expiresAt", @YES], @[@"月费（高→低，按人民币）", @"cny", @NO], @[@"上次付款（近→远）", @"lastPayment", @NO], @[@"名称", @"name", @YES]];
}

#pragma mark - Summary chip

/// Small tinted capsule in the summary strip; clicking it jumps to the matching list or view.
@interface ManagementChip : NSView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, strong) NSColor *tint;
@property (nonatomic) BOOL active;
@property (nonatomic, weak) id target;
@property (nonatomic) SEL action;
@end

@implementation ManagementChip {
    BOOL _pressed;
}
- (instancetype)initWithSymbol:(NSString *)symbol tint:(NSColor *)tint {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _symbol = [symbol copy];
        _tint = tint;
        _text = @"";
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self setAccessibilityElement:YES];
        [self setAccessibilityRole:NSAccessibilityButtonRole];
    }
    return self;
}
- (NSFont *)font { return [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]; }
- (void)setText:(NSString *)text {
    _text = [text copy];
    [self setAccessibilityLabel:text];
    [self invalidateIntrinsicContentSize];
    [self setNeedsDisplay:YES];
}
- (void)setActive:(BOOL)active { _active = active; [self setNeedsDisplay:YES]; }
- (NSSize)intrinsicContentSize {
    NSSize size = [self.text sizeWithAttributes:@{NSFontAttributeName: self.font}];
    return NSMakeSize(ceil(size.width) + 36, 24);
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect frame = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:frame xRadius:NSHeight(frame) / 2 yRadius:NSHeight(frame) / 2];
    [[self.tint colorWithAlphaComponent:_pressed ? 0.26 : (self.active ? 0.2 : 0.11)] setFill];
    [path fill];
    if (self.active) {
        [self.tint setStroke];
        [path stroke];
    }
    NSImageSymbolConfiguration *configuration = [[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightSemibold]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:self.tint]];
    NSImage *image = [[NSImage imageWithSystemSymbolName:self.symbol accessibilityDescription:nil] imageWithSymbolConfiguration:configuration];
    [image drawInRect:NSMakeRect(10, round((NSHeight(self.bounds) - image.size.height) / 2), image.size.width, image.size.height)];
    NSDictionary *attributes = @{NSFontAttributeName: self.font, NSForegroundColorAttributeName: self.tint};
    NSSize size = [self.text sizeWithAttributes:attributes];
    [self.text drawAtPoint:NSMakePoint(28, round((NSHeight(self.bounds) - size.height) / 2)) withAttributes:attributes];
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (void)mouseDown:(NSEvent *)event { _pressed = YES; [self setNeedsDisplay:YES]; }
- (void)mouseUp:(NSEvent *)event {
    _pressed = NO;
    [self setNeedsDisplay:YES];
    if (NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds))
        [NSApp sendAction:self.action to:self.target from:self];
}
- (BOOL)accessibilityPerformPress { [NSApp sendAction:self.action to:self.target from:self]; return YES; }
@end

#pragma mark - Table cells

@interface ManagementNameCell : NSTableCellView
@property (nonatomic, strong) DeskAvatarView *avatar;
@end

@implementation ManagementNameCell
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _avatar = [DeskAvatarView new];
        NSTextField *label = DeskLabel(@"", 13, NSFontWeightMedium);
        for (NSView *view in @[_avatar, label]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:view];
        }
        self.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [_avatar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [_avatar.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_avatar.widthAnchor constraintEqualToConstant:22],
            [_avatar.heightAnchor constraintEqualToConstant:22],
            [label.leadingAnchor constraintEqualToAnchor:_avatar.trailingAnchor constant:8],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-2],
            [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
    }
    return self;
}
@end

@interface ManagementPillCell : NSTableCellView
@property (nonatomic, strong) DeskPillView *pill;
@end

@implementation ManagementPillCell
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _pill = [DeskPillView new];
        [self addSubview:_pill];
        [NSLayoutConstraint activateConstraints:@[
            [_pill.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [_pill.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
    }
    return self;
}
- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    [super setBackgroundStyle:backgroundStyle];
    self.pill.backgroundStyle = backgroundStyle;
}
@end

@interface ManagementTagsCell : NSTableCellView
@property (nonatomic, strong) DeskTagsView *tagsView;
@end

@implementation ManagementTagsCell
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _tagsView = [DeskTagsView new];
        [self addSubview:_tagsView];
        [NSLayoutConstraint activateConstraints:@[
            [_tagsView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [_tagsView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-2],
            [_tagsView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_tagsView.heightAnchor constraintEqualToConstant:17]
        ]];
    }
    return self;
}
- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    [super setBackgroundStyle:backgroundStyle];
    self.tagsView.backgroundStyle = backgroundStyle;
}
@end

@interface ManagementQuotaCell : NSTableCellView
@property (nonatomic, strong) DeskQuotaBar *bar;
@end

@implementation ManagementQuotaCell
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _bar = [DeskQuotaBar new];
        NSTextField *label = DeskLabel(@"", 12, NSFontWeightSemibold);
        label.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
        label.alignment = NSTextAlignmentRight;
        [self addSubview:_bar];
        [self addSubview:label];
        self.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [_bar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [_bar.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_bar.heightAnchor constraintEqualToConstant:6],
            [label.leadingAnchor constraintEqualToAnchor:_bar.trailingAnchor constant:6],
            [label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-2],
            [label.widthAnchor constraintEqualToConstant:36],
            [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
    }
    return self;
}
@end

#pragma mark - Controller

@interface ManagementController () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout>
@property (nonatomic, weak) id<AccountCoordinator> coordinator;
@property (nonatomic, strong) NSTextField *scopeLabel;
@property (nonatomic, strong) NSTextField *summaryLabel;
@property (nonatomic, strong) ManagementChip *quotaChip;
@property (nonatomic, strong) ManagementChip *expiryChip;
@property (nonatomic, strong) ManagementChip *spendChip;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSPopUpButton *planFilter;
@property (nonatomic, strong) NSPopUpButton *sortPopUp;
@property (nonatomic, strong) NSSegmentedControl *viewSwitch;
@property (nonatomic, strong) NSScrollView *cardsScroll;
@property (nonatomic, strong) NSCollectionView *collectionView;
@property (nonatomic, strong) NSScrollView *tableScroll;
@property (nonatomic, strong) DeskTableView *tableView;
@property (nonatomic, strong) RenewalCalendarView *calendarView;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSTextField *footerLabel;
@property (nonatomic, strong) NSArray<NSButton *> *batchButtons;
@property (nonatomic, copy) NSArray<Account *> *rows;
@property (nonatomic, copy) NSArray<NSString *> *selection;
@property (nonatomic) ManagementView viewMode;
@property (nonatomic) BOOL applyingSelection;
@property (nonatomic) CGFloat laidOutWidth;
@property (nonatomic) BOOL fittedColumns;
@end

@implementation ManagementController

- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _coordinator = coordinator;
        _rows = @[];
        _selection = @[];
        _scope = ManagementScope.all;
        NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:ViewModeDefaultsKey];
        _viewMode = saved >= ManagementViewCards && saved <= ManagementViewCalendar ? saved : ManagementViewCards;
    }
    return self;
}

#pragma mark - Layout

- (NSPopUpButton *)popUpWithAction:(SEL)action {
    NSPopUpButton *popUp = [NSPopUpButton new];
    popUp.target = self;
    popUp.action = action;
    popUp.translatesAutoresizingMaskIntoConstraints = NO;
    return popUp;
}

- (void)addItem:(NSString *)title tag:(NSInteger)tag object:(id)object to:(NSPopUpButton *)popUp {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.tag = tag;
    item.representedObject = object;
    [popUp.menu addItem:item];
}

- (NSView *)buildSummary {
    self.scopeLabel = DeskLabel(@"全部账号", 17, NSFontWeightBold);
    [self.scopeLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.summaryLabel = DeskLabel(@"", 12, NSFontWeightRegular);
    self.summaryLabel.textColor = NSColor.secondaryLabelColor;
    [self.summaryLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *titles = [NSStackView stackViewWithViews:@[self.scopeLabel, self.summaryLabel]];
    titles.alignment = NSLayoutAttributeFirstBaseline;
    titles.spacing = 10;
    [titles setClippingResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.quotaChip = [[ManagementChip alloc] initWithSymbol:@"gauge.with.dots.needle.0percent" tint:NSColor.systemRedColor];
    self.quotaChip.toolTip = [NSString stringWithFormat:@"5 小时或每周额度剩余不足 %.0f%% 的账号", AccountLowQuotaPercent];
    self.expiryChip = [[ManagementChip alloc] initWithSymbol:@"clock.badge.exclamationmark" tint:NSColor.systemOrangeColor];
    self.expiryChip.toolTip = @"7 天内到期或已过期、且不会自动续费的账号";
    self.spendChip = [[ManagementChip alloc] initWithSymbol:@"creditcard" tint:NSColor.systemPurpleColor];
    for (ManagementChip *chip in @[self.quotaChip, self.expiryChip, self.spendChip]) {
        chip.target = self;
        chip.action = @selector(chipClicked:);
    }
    NSStackView *chips = [NSStackView stackViewWithViews:@[self.quotaChip, self.expiryChip, self.spendChip]];
    chips.spacing = 6;
    [chips setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *row = [NSStackView new];
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 12;
    [row setViews:@[titles] inGravity:NSStackViewGravityLeading];
    [row setViews:@[chips] inGravity:NSStackViewGravityTrailing];
    [row setClippingResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return row;
}

- (NSPopUpButton *)moreMenuButton {
    NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    button.toolTip = @"导入、导出与备份";
    NSMenuItem *title = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    title.image = [NSImage imageWithSystemSymbolName:@"ellipsis.circle" accessibilityDescription:@"更多"];
    [button.menu addItem:title];
    NSArray *specs = @[
        @[@"导入账号资料…", @"square.and.arrow.down", NSStringFromSelector(@selector(importAccounts:))],
        @[@"导出全部账号资料…", @"square.and.arrow.up", NSStringFromSelector(@selector(exportAccounts:))],
        @[@"导出续费日历（.ics）…", @"calendar.badge.plus", NSStringFromSelector(@selector(exportRenewalCalendar:))],
        @[@"导出付款记录（CSV）…", @"tablecells", NSStringFromSelector(@selector(exportPaymentsCSV:))],
        @[],
        @[@"刷新全部用量", @"arrow.triangle.2.circlepath", NSStringFromSelector(@selector(refreshAllUsage:))],
        @[@"后台读取全部账号账单", @"creditcard", NSStringFromSelector(@selector(readAllBilling:))],
        @[],
        @[@"立即备份", @"externaldrive.badge.timemachine", @"backupNow:"],
        @[@"备份与恢复设置…", @"gearshape", @"showBackupSettings:"]];
    for (NSArray *spec in specs) {
        if (!spec.count) { [button.menu addItem:[NSMenuItem separatorItem]]; continue; }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:spec[0] action:NSSelectorFromString(spec[2]) keyEquivalent:@""];
        item.image = [NSImage imageWithSystemSymbolName:spec[1] accessibilityDescription:nil];
        // Account actions go to the coordinator; backup actions travel up the responder chain to the app delegate.
        if ([(id)self.coordinator respondsToSelector:item.action]) item.target = self.coordinator;
        [button.menu addItem:item];
    }
    return button;
}

- (NSView *)buildControls {
    self.searchField = [NSSearchField new];
    self.searchField.placeholderString = @"搜索名称、邮箱、标签或备注";
    self.searchField.sendsSearchStringImmediately = YES;
    self.searchField.target = self;
    self.searchField.action = @selector(filtersChanged:);
    [self.searchField.widthAnchor constraintGreaterThanOrEqualToConstant:120].active = YES;
    NSLayoutConstraint *preferred = [self.searchField.widthAnchor constraintEqualToConstant:260];
    preferred.priority = NSLayoutPriorityDefaultLow;
    preferred.active = YES;
    [self.searchField setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.searchField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.planFilter = [self popUpWithAction:@selector(filtersChanged:)];
    [self addItem:@"全部订阅" tag:PlanFilterAll object:nil to:self.planFilter];
    [self addItem:@"付费订阅" tag:PlanFilterPaid object:nil to:self.planFilter];
    [self addItem:@"未获取订阅" tag:PlanFilterUnknown object:nil to:self.planFilter];
    [self.planFilter.menu addItem:[NSMenuItem separatorItem]];
    for (NSString *plan in AccountPlans()) {
        if ([plan isEqualToString:@"Pro"]) [self addItem:@"Pro（全部档位）" tag:PlanFilterFamily object:@"Pro" to:self.planFilter];
        else [self addItem:plan tag:PlanFilterSpecific object:plan to:self.planFilter];
    }
    self.sortPopUp = [self popUpWithAction:@selector(sortChosen:)];
    for (NSArray *choice in SortChoices()) [self addItem:choice[0] tag:0 object:choice to:self.sortPopUp];
    self.sortPopUp.toolTip = @"排序";

    self.viewSwitch = [NSSegmentedControl segmentedControlWithImages:@[
            [NSImage imageWithSystemSymbolName:@"square.grid.2x2" accessibilityDescription:@"卡片"],
            [NSImage imageWithSystemSymbolName:@"list.bullet" accessibilityDescription:@"列表"],
            [NSImage imageWithSystemSymbolName:@"calendar" accessibilityDescription:@"日历"]]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(viewSwitched:)];
    [self.viewSwitch setToolTip:@"卡片" forSegment:0];
    [self.viewSwitch setToolTip:@"列表" forSegment:1];
    [self.viewSwitch setToolTip:@"续费日历" forSegment:2];
    self.viewSwitch.selectedSegment = self.viewMode;
    NSPopUpButton *more = [self moreMenuButton];
    NSButton *add = DeskButton(@"添加账号", @"plus", self.coordinator, @selector(addAccount:));
    add.bezelColor = NSColor.controlAccentColor;

    NSStackView *row = [NSStackView new];
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8;
    [row setViews:@[self.searchField, self.planFilter, self.sortPopUp] inGravity:NSStackViewGravityLeading];
    [row setViews:@[self.viewSwitch, more, add] inGravity:NSStackViewGravityTrailing];
    [row setClippingResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return row;
}

- (void)buildCollection {
    NSCollectionViewFlowLayout *layout = [NSCollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 14;
    layout.minimumLineSpacing = 14;
    layout.sectionInset = NSEdgeInsetsMake(14, 24, 20, 24);
    self.collectionView = [NSCollectionView new];
    self.collectionView.collectionViewLayout = layout;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.selectable = YES;
    self.collectionView.allowsMultipleSelection = YES;
    self.collectionView.backgroundColors = @[NSColor.clearColor];
    [self.collectionView registerClass:AccountCardItem.class forItemWithIdentifier:@"AccountCard"];
    self.cardsScroll = [NSScrollView new];
    self.cardsScroll.documentView = self.collectionView;
    self.cardsScroll.hasVerticalScroller = YES;
    self.cardsScroll.autohidesScrollers = YES;
    self.cardsScroll.drawsBackground = NO;
}

- (void)buildTable {
    self.tableView = [DeskTableView new];
    self.tableView.style = NSTableViewStyleFullWidth;
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    self.tableView.allowsMultipleSelection = YES;
    self.tableView.allowsColumnReordering = YES;
    self.tableView.rowHeight = 34;
    self.tableView.intercellSpacing = NSMakeSize(10, 0);
    self.tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    NSMenu *headerMenu = [NSMenu new];
    for (NSArray *spec in ColumnSpecs()) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        column.title = spec[1];
        column.width = [spec[2] doubleValue];
        column.minWidth = [spec[3] doubleValue];
        column.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:spec[4] ascending:YES];
        column.hidden = [spec[5] boolValue];
        [self.tableView addTableColumn:column];
        if ([spec[0] isEqualToString:@"name"]) continue;
        NSMenuItem *toggle = [[NSMenuItem alloc] initWithTitle:spec[1] action:@selector(toggleColumn:) keyEquivalent:@""];
        toggle.target = self;
        toggle.representedObject = column;
        [headerMenu addItem:toggle];
    }
    headerMenu.delegate = self;
    self.tableView.headerView.menu = headerMenu;
    self.tableView.autosaveName = @"AccountManagementTable.v4";
    self.tableView.autosaveTableColumns = YES;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.target = self;
    self.tableView.doubleAction = @selector(openClickedRow:);
    self.tableView.menu = [NSMenu new];
    self.tableView.menu.delegate = self;
    __weak typeof(self) weakSelf = self;
    self.tableView.deleteHandler = ^{
        if (weakSelf.selection.count) [weakSelf.coordinator deleteAccountIDs:weakSelf.selection];
    };
    self.tableView.returnHandler = ^{
        if (weakSelf.selection.count == 1) [weakSelf.coordinator openAccountID:weakSelf.selection.firstObject];
    };
    self.tableScroll = [NSScrollView new];
    self.tableScroll.documentView = self.tableView;
    self.tableScroll.hasVerticalScroller = YES;
    self.tableScroll.hasHorizontalScroller = YES;
    self.tableScroll.autohidesScrollers = YES;
}

- (void)buildCalendar {
    self.calendarView = [RenewalCalendarView new];
    __weak typeof(self) weakSelf = self;
    self.calendarView.selectAccount = ^(NSString *identifier, BOOL extend) {
        ManagementController *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSMutableArray *selection = extend ? [strongSelf.selection mutableCopy] : [NSMutableArray array];
        if ([selection containsObject:identifier]) [selection removeObject:identifier]; else [selection addObject:identifier];
        [strongSelf userChangedSelection:selection];
    };
    self.calendarView.openAccount = ^(NSString *identifier) { [weakSelf.coordinator openAccountID:identifier]; };
    self.calendarView.menuForAccount = ^NSMenu *(NSString *identifier) {
        ManagementController *strongSelf = weakSelf;
        NSMenu *menu = [NSMenu new];
        [strongSelf.coordinator populateMenu:menu forAccountIDs:[strongSelf menuIDsForAccountID:identifier]];
        return menu;
    };
}

- (NSView *)buildFooter {
    self.footerLabel = DeskLabel(@"", 12, NSFontWeightRegular);
    self.footerLabel.textColor = NSColor.secondaryLabelColor;
    [self.footerLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSArray<NSArray *> *specs = @[
        @[@"标签…", @"tag", NSStringFromSelector(@selector(batchTags:)), @"为所选账号添加标签"],
        @[@"分组…", @"folder", NSStringFromSelector(@selector(batchGroup:)), @"把所选账号移动到分组"],
        @[@"刷新", @"arrow.clockwise", NSStringFromSelector(@selector(batchRefresh:)), @"刷新所选账号的用量与订阅"],
        @[@"读账单", @"creditcard", NSStringFromSelector(@selector(batchBilling:)), @"在后台读取所选账号账单页的档位、续费日期与月费"],
        @[@"清除登录…", @"rectangle.portrait.and.arrow.right", NSStringFromSelector(@selector(batchClear:)), @"清除所选账号在本机的登录数据，保留账号资料"],
        @[@"导出…", @"square.and.arrow.up", NSStringFromSelector(@selector(batchExport:)), @"导出所选账号的资料"],
        @[@"删除…", @"trash", NSStringFromSelector(@selector(batchDelete:)), @"删除所选账号"]];
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    for (NSArray *spec in specs) {
        NSButton *button = DeskButton(spec[0], spec[1], self, NSSelectorFromString(spec[2]));
        button.toolTip = spec[3];
        button.controlSize = NSControlSizeSmall;
        [buttons addObject:button];
    }
    buttons.lastObject.contentTintColor = NSColor.systemRedColor;
    self.batchButtons = buttons;
    NSStackView *buttonRow = [NSStackView stackViewWithViews:buttons];
    buttonRow.spacing = 6;
    [buttonRow setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *footer = [NSStackView new];
    footer.spacing = 12;
    footer.alignment = NSLayoutAttributeCenterY;
    footer.edgeInsets = NSEdgeInsetsMake(0, 24, 0, 24);
    [footer setViews:@[self.footerLabel] inGravity:NSStackViewGravityLeading];
    [footer setViews:@[buttonRow] inGravity:NSStackViewGravityTrailing];
    [footer setClippingResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return footer;
}

- (void)loadView {
    NSView *root = [NSView new];
    self.view = root;
    NSView *summary = [self buildSummary];
    NSView *controls = [self buildControls];
    [self buildCollection];
    [self buildTable];
    [self buildCalendar];
    NSBox *topLine = DeskSeparator();
    NSBox *bottomLine = DeskSeparator();
    NSView *footer = [self buildFooter];
    self.emptyLabel = DeskLabel(@"", 13, NSFontWeightRegular);
    self.emptyLabel.textColor = NSColor.secondaryLabelColor;

    NSArray *contents = @[self.cardsScroll, self.tableScroll, self.calendarView];
    for (NSView *view in [@[summary, controls, topLine, bottomLine, footer] arrayByAddingObjectsFromArray:contents]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    [root addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [summary.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:12],
        [summary.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [summary.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [controls.topAnchor constraintEqualToAnchor:summary.bottomAnchor constant:12],
        [controls.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [controls.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [topLine.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:12],
        [topLine.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [topLine.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [bottomLine.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [bottomLine.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [bottomLine.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:42],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.cardsScroll.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.cardsScroll.centerYAnchor]
    ]];
    for (NSView *content in contents) {
        [NSLayoutConstraint activateConstraints:@[
            [content.topAnchor constraintEqualToAnchor:topLine.bottomAnchor],
            [content.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [content.bottomAnchor constraintEqualToAnchor:bottomLine.topAnchor]
        ]];
    }
    [self applyViewMode];
    [self reloadAccounts];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    CGFloat width = NSWidth(self.cardsScroll.contentView.bounds);
    if (fabs(width - self.laidOutWidth) > 0.5) {
        self.laidOutWidth = width;
        [self.collectionView.collectionViewLayout invalidateLayout];
    }
    // Scale the (possibly autosaved) column widths to the visible width once per launch.
    if (!self.fittedColumns && self.viewMode == ManagementViewList && self.tableScroll.contentSize.width > 0) {
        self.fittedColumns = YES;
        [self.tableView sizeToFit];
    }
}

#pragma mark - Filtering

- (BOOL)account:(Account *)account passesFiltersAt:(NSDate *)now duplicateIDs:(NSSet *)duplicateIDs {
    if (![self.scope includesAccount:account now:now duplicateIDs:duplicateIDs]) return NO;
    if (![account matchesSearch:self.searchField.stringValue]) return NO;
    NSMenuItem *plan = self.planFilter.selectedItem;
    switch ((PlanFilter)plan.tag) {
        case PlanFilterAll: break;
        case PlanFilterPaid: if (!account.isPaid) return NO; break;
        case PlanFilterUnknown: if (account.plan) return NO; break;
        case PlanFilterSpecific: if (![account.plan isEqualToString:plan.representedObject]) return NO; break;
        case PlanFilterFamily: if (![account.planFamily isEqualToString:plan.representedObject]) return NO; break;
    }
    return YES;
}

- (NSArray<Account *> *)sortedAccounts:(NSArray<Account *> *)accounts {
    NSSortDescriptor *sort = self.tableView.sortDescriptors.firstObject;
    if (!sort.key.length) return accounts;
    NSString *key = sort.key;
    BOOL ascending = sort.ascending;
    NSDate *now = NSDate.date;
    return [accounts sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(Account *a, Account *b) {
        id left = SortValue(a, key, now), right = SortValue(b, key, now);
        // Missing values stay at the bottom in both directions.
        if (!left && !right) return NSOrderedSame;
        if (!left) return NSOrderedDescending;
        if (!right) return NSOrderedAscending;
        NSComparisonResult result = [left isKindOfClass:NSString.class]
            ? [left localizedStandardCompare:right] : [left compare:right];
        return ascending ? result : (NSComparisonResult)-result;
    }];
}

#pragma mark - Reload

- (void)setScope:(ManagementScope *)scope {
    _scope = scope ?: ManagementScope.all;
    [self reloadAccounts];
}

- (void)reloadAccounts {
    if (!self.isViewLoaded) return;
    AccountStore *store = self.coordinator.store;
    if (!self.scope) _scope = ManagementScope.all;
    NSDate *now = NSDate.date;
    NSArray<Account *> *accounts = store.accounts;
    NSSet *duplicates = AccountDuplicateIDs(accounts);
    ManagementScope *quotaScope = [ManagementScope scopeWithKind:ManagementScopeQuotaLow value:nil];
    ManagementScope *expiringScope = [ManagementScope scopeWithKind:ManagementScopeExpiring value:nil];
    NSUInteger paid = 0, signedIn = 0, low = 0, expiring = 0;
    NSDate *latest = nil;
    NSMutableArray<Account *> *visible = [NSMutableArray array];
    for (Account *account in accounts) {
        if (account.isPaid) paid++;
        if (account.signedIn.boolValue) signedIn++;
        if ([quotaScope includesAccount:account now:now duplicateIDs:duplicates]) low++;
        if ([expiringScope includesAccount:account now:now duplicateIDs:duplicates]) expiring++;
        if (account.usage && (!latest || [account.usage.fetchedAt compare:latest] == NSOrderedDescending)) latest = account.usage.fetchedAt;
        if ([self account:account passesFiltersAt:now duplicateIDs:duplicates]) [visible addObject:account];
    }

    self.scopeLabel.stringValue = self.scope.title;
    NSMutableArray *summary = [NSMutableArray array];
    BOOL filtered = visible.count != accounts.count;
    [summary addObject:filtered
        ? [NSString stringWithFormat:@"%lu / %lu 个账号", (unsigned long)visible.count, (unsigned long)accounts.count]
        : [NSString stringWithFormat:@"%lu 个账号", (unsigned long)accounts.count]];
    [summary addObject:[NSString stringWithFormat:@"付费 %lu · 已登录 %lu", (unsigned long)paid, (unsigned long)signedIn]];
    if (self.coordinator.isRefreshingUsage) [summary addObject:@"正在刷新用量…"];
    else if (latest) [summary addObject:[@"用量更新于" stringByAppendingString:DeskRelativeTime(latest)]];
    else if (accounts.count) [summary addObject:@"尚未读取用量"];
    self.summaryLabel.stringValue = [summary componentsJoinedByString:@" · "];

    self.quotaChip.text = [NSString stringWithFormat:@"额度告急 %lu", (unsigned long)low];
    self.quotaChip.hidden = low == 0 && self.scope.kind != ManagementScopeQuotaLow;
    self.expiryChip.text = [NSString stringWithFormat:@"即将到期 %lu", (unsigned long)expiring];
    self.expiryChip.hidden = expiring == 0 && self.scope.kind != ManagementScopeExpiring;
    NSDictionary<NSString *, NSNumber *> *spend = store.monthlySpendByCurrency;
    NSMutableArray<NSString *> *amounts = [NSMutableArray array];
    for (NSString *currency in [spend.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [amounts addObject:AccountFormatMoney(spend[currency], currency)];
    NSArray<NSString *> *missing = nil;
    double monthly = [store monthlySpendInCNYWithRates:AccountExchangeRates() missingCurrencies:&missing];
    self.spendChip.text = !amounts.count ? @"续费日历"
        : [NSString stringWithFormat:@"%@/月%@", AccountFormatCNY(@(monthly)), missing.count ? @" + 未换算" : @""];
    self.spendChip.toolTip = amounts.count
        ? [NSString stringWithFormat:@"每月支出（折合人民币）：%@\n原币：%@%@\n点击查看续费日历", AccountFormatCNY(@(monthly)),
            [amounts componentsJoinedByString:@" + "],
            missing.count ? [NSString stringWithFormat:@"\n%@ 未设汇率，未计入；可在“设置 → 费用”中填写", [missing componentsJoinedByString:@"、"]] : @""]
        : @"查看续费日历";
    [self updateChipHighlights];

    self.rows = [self sortedAccounts:visible];
    // Batch actions only ever apply to accounts that are on screen.
    NSSet *shown = [NSSet setWithArray:[visible valueForKey:@"identifier"]];
    NSMutableArray *selection = [NSMutableArray array];
    for (NSString *identifier in self.selection) if ([shown containsObject:identifier]) [selection addObject:identifier];
    _selection = selection;

    self.applyingSelection = YES;
    [self.tableView reloadData];
    [self.collectionView reloadData];
    self.calendarView.accounts = self.rows;
    self.applyingSelection = NO;
    [self applySelectionToViews];

    BOOL plainFilters = !self.searchField.stringValue.length && self.planFilter.selectedItem.tag == PlanFilterAll;
    self.emptyLabel.hidden = self.rows.count > 0 || self.viewMode == ManagementViewCalendar;
    self.emptyLabel.stringValue = !accounts.count ? @"还没有账号，点击右上角“添加账号”开始"
        : (plainFilters ? [NSString stringWithFormat:@"“%@”中没有账号", self.scope.title] : @"没有符合筛选条件的账号");
    [self updateFooter];
}

- (void)updateChipHighlights {
    self.quotaChip.active = self.scope.kind == ManagementScopeQuotaLow;
    self.expiryChip.active = self.scope.kind == ManagementScopeExpiring;
    self.spendChip.active = self.viewMode == ManagementViewCalendar;
}

- (void)updateFooter {
    NSUInteger selected = self.selection.count;
    self.footerLabel.stringValue = selected ? [NSString stringWithFormat:@"已选择 %lu 个账号", (unsigned long)selected]
        : @"选择账号后可批量操作，按住 ⌘ 可多选";
    for (NSButton *button in self.batchButtons) button.enabled = selected > 0;
}

#pragma mark - Selection

- (NSArray<NSString *> *)selectedAccountIDs { return self.selection; }

- (NSArray<NSString *> *)menuIDsForAccountID:(NSString *)identifier {
    return [self.selection containsObject:identifier] ? self.selection : @[identifier];
}

- (void)applySelectionToViews {
    self.applyingSelection = YES;
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    NSMutableSet<NSIndexPath *> *paths = [NSMutableSet set];
    [self.rows enumerateObjectsUsingBlock:^(Account *account, NSUInteger index, BOOL *stop) {
        if (![self.selection containsObject:account.identifier]) return;
        [rows addIndex:index];
        [paths addObject:[NSIndexPath indexPathForItem:(NSInteger)index inSection:0]];
    }];
    [self.tableView selectRowIndexes:rows byExtendingSelection:NO];
    self.collectionView.selectionIndexPaths = paths;
    self.calendarView.selectedIDs = self.selection;
    self.applyingSelection = NO;
    [self updateFooter];
}

- (void)userChangedSelection:(NSArray<NSString *> *)identifiers {
    self.selection = identifiers;
    [self applySelectionToViews];
    [self.coordinator managementSelectionDidChange:identifiers];
}

- (void)reflectSelection {
    if (!self.isViewLoaded) return;
    NSString *selected = self.coordinator.selectedAccountID;
    if (self.selection.count > 1 && [self.selection containsObject:selected]) return;
    NSUInteger row = [self.rows indexOfObjectPassingTest:^BOOL(Account *account, NSUInteger index, BOOL *stop) {
        return [account.identifier isEqualToString:selected];
    }];
    self.selection = row != NSNotFound ? @[selected] : @[];
    [self applySelectionToViews];
    if (row == NSNotFound) return;
    if (self.viewMode == ManagementViewList) [self.tableView scrollRowToVisible:(NSInteger)row];
    if (self.viewMode == ManagementViewCards)
        [self.collectionView scrollToItemsAtIndexPaths:[NSSet setWithObject:[NSIndexPath indexPathForItem:(NSInteger)row inSection:0]]
            scrollPosition:NSCollectionViewScrollPositionNearestHorizontalEdge];
}

- (void)focusSearch { [self.view.window makeFirstResponder:self.searchField]; }

- (void)focusTable {
    NSView *target = self.viewMode == ManagementViewList ? self.tableView : (NSView *)self.collectionView;
    [self.view.window makeFirstResponder:target];
}

#pragma mark - Actions

- (void)filtersChanged:(id)sender { [self reloadAccounts]; }

- (void)chipClicked:(ManagementChip *)chip {
    if (chip == self.spendChip) {
        [self switchToView:self.viewMode == ManagementViewCalendar ? ManagementViewCards : ManagementViewCalendar];
        return;
    }
    ManagementScopeKind kind = chip == self.quotaChip ? ManagementScopeQuotaLow : ManagementScopeExpiring;
    ManagementScope *scope = self.scope.kind == kind ? ManagementScope.all : [ManagementScope scopeWithKind:kind value:nil];
    if (self.viewMode == ManagementViewCalendar) [self switchToView:ManagementViewCards];
    self.scope = scope;
    if (self.scopeChosen) self.scopeChosen(scope);
}

- (void)sortChosen:(NSPopUpButton *)sender {
    NSArray *choice = sender.selectedItem.representedObject;
    NSString *key = choice[1];
    self.tableView.sortDescriptors = key.length ? @[[NSSortDescriptor sortDescriptorWithKey:key ascending:[choice[2] boolValue]]] : @[];
    [self reloadAccounts];
}

- (void)syncSortPopUp {
    NSSortDescriptor *sort = self.tableView.sortDescriptors.firstObject;
    for (NSMenuItem *item in self.sortPopUp.itemArray) {
        NSArray *choice = item.representedObject;
        BOOL matches = sort ? ([choice[1] isEqualToString:sort.key] && [choice[2] boolValue] == sort.ascending) : ![choice[1] length];
        if (matches) { [self.sortPopUp selectItem:item]; return; }
    }
    [self.sortPopUp selectItemAtIndex:0];
}

- (void)viewSwitched:(NSSegmentedControl *)sender { [self switchToView:sender.selectedSegment]; }

- (void)switchToView:(ManagementView)mode {
    self.viewMode = mode;
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:ViewModeDefaultsKey];
    [self applyViewMode];
    [self reloadAccounts];
}

- (void)applyViewMode {
    self.viewSwitch.selectedSegment = self.viewMode;
    self.cardsScroll.hidden = self.viewMode != ManagementViewCards;
    self.tableScroll.hidden = self.viewMode != ManagementViewList;
    self.calendarView.hidden = self.viewMode != ManagementViewCalendar;
    self.sortPopUp.enabled = self.viewMode != ManagementViewCalendar;
    [self syncSortPopUp];
    [self updateChipHighlights];
    if (self.viewMode == ManagementViewList && !self.fittedColumns) [self.view setNeedsLayout:YES];
}

- (void)openClickedRow:(id)sender {
    NSInteger row = self.tableView.clickedRow;
    if (row >= 0 && row < (NSInteger)self.rows.count) [self.coordinator openAccountID:self.rows[(NSUInteger)row].identifier];
}

- (void)toggleColumn:(NSMenuItem *)sender {
    NSTableColumn *column = sender.representedObject;
    column.hidden = !column.hidden;
}

- (void)batchTags:(id)sender { [self.coordinator promptTagsForAccountIDs:self.selection]; }
- (void)batchGroup:(id)sender { [self.coordinator promptGroupForAccountIDs:self.selection]; }
- (void)batchRefresh:(id)sender { [self.coordinator refreshUsageForAccountIDs:self.selection]; }
- (void)batchBilling:(id)sender { [self.coordinator readBillingForAccountIDs:self.selection]; }
- (void)batchClear:(id)sender { [self.coordinator clearLoginDataForAccountIDs:self.selection]; }
- (void)batchExport:(id)sender { [self.coordinator exportAccountIDs:self.selection]; }
- (void)batchDelete:(id)sender { [self.coordinator deleteAccountIDs:self.selection]; }

#pragma mark - Menus

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == self.tableView.headerView.menu) {
        for (NSMenuItem *item in menu.itemArray)
            item.state = [item.representedObject isHidden] ? NSControlStateValueOff : NSControlStateValueOn;
        return;
    }
    NSInteger clicked = self.tableView.clickedRow;
    NSArray<NSString *> *identifiers = clicked >= 0 && clicked < (NSInteger)self.rows.count
        ? [self menuIDsForAccountID:self.rows[(NSUInteger)clicked].identifier] : @[];
    [self.coordinator populateMenu:menu forAccountIDs:identifiers];
}

#pragma mark - Cards

- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.rows.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
    AccountCardItem *item = [collectionView makeItemWithIdentifier:@"AccountCard" forIndexPath:indexPath];
    Account *account = self.rows[(NSUInteger)indexPath.item];
    item.coordinator = self.coordinator;
    __weak typeof(self) weakSelf = self;
    item.menuAccountIDs = ^NSArray<NSString *> *(NSString *identifier) { return [weakSelf menuIDsForAccountID:identifier]; };
    BOOL busy = [self.coordinator isRefreshingAccountID:account.identifier] || [self.coordinator isReadingBillingForAccountID:account.identifier];
    [item configureWithAccount:account status:[AccountStatus statusForAccount:account now:NSDate.date] busy:busy now:NSDate.date];
    return item;
}

- (NSSize)collectionView:(NSCollectionView *)collectionView layout:(NSCollectionViewLayout *)collectionViewLayout
    sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    NSCollectionViewFlowLayout *layout = (NSCollectionViewFlowLayout *)collectionViewLayout;
    CGFloat available = NSWidth(self.cardsScroll.contentView.bounds) - layout.sectionInset.left - layout.sectionInset.right;
    CGFloat spacing = layout.minimumInteritemSpacing, minimum = 300;
    NSInteger columns = MAX(1, (NSInteger)floor((available + spacing) / (minimum + spacing)));
    CGFloat width = floor((available - (columns - 1) * spacing) / columns);
    return NSMakeSize(MAX(minimum, width), 212);
}

- (void)collectionViewSelectionChanged {
    if (self.applyingSelection) return;
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    NSArray *paths = [self.collectionView.selectionIndexPaths.allObjects sortedArrayUsingSelector:@selector(compare:)];
    for (NSIndexPath *path in paths)
        if ((NSUInteger)path.item < self.rows.count) [identifiers addObject:self.rows[(NSUInteger)path.item].identifier];
    self.selection = identifiers;
    self.calendarView.selectedIDs = identifiers;
    [self updateFooter];
    [self.coordinator managementSelectionDidChange:identifiers];
}

- (void)collectionView:(NSCollectionView *)collectionView didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
    [self collectionViewSelectionChanged];
}

- (void)collectionView:(NSCollectionView *)collectionView didDeselectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
    [self collectionViewSelectionChanged];
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)self.rows.count; }

- (NSTableCellView *)textCellInTable:(NSTableView *)tableView {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"TextCell" owner:self];
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"TextCell";
        NSTextField *label = DeskLabel(@"", 13, NSFontWeightRegular);
        [cell addSubview:label];
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
        ]];
    }
    cell.textField.textColor = NSColor.labelColor;
    cell.textField.font = [NSFont systemFontOfSize:13];
    cell.toolTip = nil;
    return cell;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    Account *account = self.rows[(NSUInteger)row];
    NSString *column = tableColumn.identifier;
    NSDate *now = NSDate.date;

    if ([column isEqualToString:@"name"]) {
        ManagementNameCell *cell = [tableView makeViewWithIdentifier:@"NameCell" owner:self];
        if (!cell) {
            cell = [[ManagementNameCell alloc] initWithFrame:NSZeroRect];
            cell.identifier = @"NameCell";
        }
        cell.avatar.name = account.name;
        cell.avatar.seed = account.identifier;
        cell.avatar.statusColor = account.signedIn.boolValue ? NSColor.systemGreenColor : nil;
        cell.textField.stringValue = account.name;
        return cell;
    }
    if ([column isEqualToString:@"status"]) {
        ManagementPillCell *cell = [tableView makeViewWithIdentifier:@"StatusCell" owner:self];
        if (!cell) {
            cell = [[ManagementPillCell alloc] initWithFrame:NSZeroRect];
            cell.identifier = @"StatusCell";
        }
        AccountStatus *status = [AccountStatus statusForAccount:account now:now];
        [cell.pill showStatus:status showsNormal:NO];
        cell.toolTip = account.refreshError.length ? account.refreshError : status.title;
        return cell;
    }
    if ([column isEqualToString:@"plan"]) {
        ManagementPillCell *cell = [tableView makeViewWithIdentifier:@"PillCell" owner:self];
        if (!cell) {
            cell = [[ManagementPillCell alloc] initWithFrame:NSZeroRect];
            cell.identifier = @"PillCell";
        }
        cell.pill.text = account.plan ?: @"未获取";
        cell.pill.tintColor = DeskColorForPlan(account.planFamily);
        return cell;
    }
    if ([column isEqualToString:@"tags"]) {
        ManagementTagsCell *cell = [tableView makeViewWithIdentifier:@"TagsCell" owner:self];
        if (!cell) {
            cell = [[ManagementTagsCell alloc] initWithFrame:NSZeroRect];
            cell.identifier = @"TagsCell";
        }
        cell.tagsView.tags = account.tags;
        return cell;
    }
    if ([column isEqualToString:@"short"] || [column isEqualToString:@"long"]) {
        ManagementQuotaCell *cell = [tableView makeViewWithIdentifier:@"QuotaCell" owner:self];
        if (!cell) {
            cell = [[ManagementQuotaCell alloc] initWithFrame:NSZeroRect];
            cell.identifier = @"QuotaCell";
        }
        AccountUsageWindow *window = [column isEqualToString:@"short"] ? account.usage.shortWindow : account.usage.longWindow;
        cell.bar.remainingPercent = window ? @(window.remainingPercent) : nil;
        cell.textField.stringValue = window ? [NSString stringWithFormat:@"%.0f%%", window.remainingPercent] : @"—";
        cell.textField.textColor = window ? DeskColorForQuota(window.remainingPercent) : NSColor.tertiaryLabelColor;
        cell.toolTip = window ? DeskResetDescription(window.resetAt) : account.refreshError;
        return cell;
    }

    NSTableCellView *cell = [self textCellInTable:tableView];
    NSTextField *label = cell.textField;
    NSString *value = @"—";
    if ([column isEqualToString:@"renewal"]) {
        AccountExpiryState state = [account expiryStateFromDate:now];
        if (state != AccountExpiryStateUnknown) {
            value = [account compactRenewalDescriptionFromDate:now];
            cell.toolTip = [NSString stringWithFormat:@"%@ · %@", account.renewalDescription, [account expiryDescriptionFromDate:now]];
            label.textColor = state == AccountExpiryStateActive || state == AccountExpiryStateRenewing
                ? NSColor.labelColor : DeskColorForExpiry(state);
        }
    } else if ([column isEqualToString:@"price"]) {
        if (account.monthlyPrice) value = AccountFormatMoney(account.monthlyPrice, account.currency);
        label.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    } else if ([column isEqualToString:@"cny"]) {
        NSNumber *cny = AccountAmountInCNY(account.monthlyPrice, account.currency, AccountExchangeRates());
        if (cny) value = AccountFormatCNY(cny);
        else if (account.monthlyPrice) {
            value = @"未设汇率";
            label.textColor = NSColor.systemOrangeColor;
        }
        if (account.monthlyPrice) cell.toolTip = AccountFormatMoney(account.monthlyPrice, account.currency);
        label.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    } else if ([column isEqualToString:@"supplier"]) {
        if (account.supplier.length) value = account.supplier;
    } else if ([column isEqualToString:@"card"]) {
        if (account.cardLast4.length) value = account.cardLast4;
        label.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    } else if ([column isEqualToString:@"paymentMethod"]) {
        if (account.paymentMethod.length) value = account.paymentMethod;
    } else if ([column isEqualToString:@"lastPayment"]) {
        AccountPayment *last = account.lastPayment;
        if (last) {
            value = last.date;
            cell.toolTip = AccountFormatMoney(last.amount, last.currency);
        }
    } else if ([column isEqualToString:@"email"]) {
        if (account.email.length) value = account.email;
    } else if ([column isEqualToString:@"group"]) {
        if (account.group.length) value = account.group;
    } else if ([column isEqualToString:@"signedIn"]) {
        if (account.signedIn) value = account.signedIn.boolValue ? @"已登录" : @"未登录";
        label.textColor = account.signedIn.boolValue ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
    } else if ([column isEqualToString:@"lastUsedAt"]) {
        if (account.lastUsedAt) value = DeskRelativeTime(account.lastUsedAt);
        label.textColor = NSColor.secondaryLabelColor;
    } else if ([column isEqualToString:@"notes"]) {
        if (account.notes.length) {
            value = [[account.notes componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
            cell.toolTip = account.notes;
        }
    }
    if ([value isEqualToString:@"—"]) label.textColor = NSColor.tertiaryLabelColor;
    label.stringValue = value;
    return cell;
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    [self syncSortPopUp];
    [self reloadAccounts];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (self.applyingSelection) return;
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    [self.tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        if (index < self.rows.count) [identifiers addObject:self.rows[index].identifier];
    }];
    self.selection = identifiers;
    [self applySelectionToViews];
    [self.coordinator managementSelectionDidChange:identifiers];
}
@end
