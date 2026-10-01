#import "ManagementController.h"
#import "Account.h"
#import "AccountCardItem.h"
#import "DeskUI.h"
#import "RenewalCalendarView.h"

typedef NS_ENUM(NSInteger, PlanFilter) {
    PlanFilterAll = 0,
    PlanFilterPaid,
    PlanFilterUnknown,
    PlanFilterSpecific,
    PlanFilterFamily,
};

typedef NS_ENUM(NSInteger, StatusFilter) {
    StatusFilterAll = 0,
    StatusFilterQuotaOK,
    StatusFilterQuotaLow,
    StatusFilterNoUsage,
    StatusFilterRenewing,
    StatusFilterExpiringSoon,
    StatusFilterExpired,
    StatusFilterNoExpiry,
    StatusFilterSignedIn,
    StatusFilterSignedOut,
};

typedef NS_ENUM(NSInteger, ListFilter) {
    ListFilterAll = 0,
    ListFilterNone,
    ListFilterSpecific,
};

typedef NS_ENUM(NSInteger, ManagementView) {
    ManagementViewCards = 0,
    ManagementViewList,
    ManagementViewCalendar,
};

static NSString *const ViewModeDefaultsKey = @"managementViewMode";
static double const LowQuotaPercent = 20;

static NSArray<NSArray *> *ColumnSpecs(void) {
    // identifier, title, width, minimum width, sort key, hidden by default
    return @[
        @[@"name", @"账号", @150, @110, @"name", @NO],
        @[@"plan", @"订阅", @80, @66, @"plan", @NO],
        @[@"tags", @"标签", @110, @84, @"tags", @NO],
        @[@"short", @"5 小时", @104, @84, @"short", @NO],
        @[@"long", @"每周", @104, @84, @"long", @NO],
        @[@"renewal", @"续费 / 到期", @130, @112, @"expiresAt", @NO],
        @[@"price", @"月费", @112, @104, @"price", @NO],
        @[@"email", @"邮箱", @170, @110, @"email", @NO],
        @[@"group", @"分组", @80, @48, @"group", @YES],
        @[@"signedIn", @"登录", @56, @48, @"signedIn", @YES],
        @[@"lastUsedAt", @"最近使用", @84, @60, @"lastUsedAt", @YES],
        @[@"notes", @"备注", @150, @60, @"notes", @YES],
    ];
}

static id SortValue(Account *account, NSString *key) {
    if ([key isEqualToString:@"name"]) return account.name;
    if ([key isEqualToString:@"plan"]) return account.planRank ? @(account.planRank) : nil;
    if ([key isEqualToString:@"tags"]) return account.tags.firstObject;
    if ([key isEqualToString:@"short"]) return account.usage.shortWindow ? @(account.usage.shortWindow.remainingPercent) : nil;
    if ([key isEqualToString:@"long"]) return account.usage.longWindow ? @(account.usage.longWindow.remainingPercent) : nil;
    if ([key isEqualToString:@"expiresAt"]) return account.expiresAt;
    if ([key isEqualToString:@"price"]) return account.monthlyPrice;
    if ([key isEqualToString:@"email"]) return account.email.length ? account.email : nil;
    if ([key isEqualToString:@"group"]) return account.group.length ? account.group : nil;
    if ([key isEqualToString:@"signedIn"]) return account.signedIn;
    if ([key isEqualToString:@"lastUsedAt"]) return account.lastUsedAt;
    if ([key isEqualToString:@"notes"]) return account.notes.length ? account.notes : nil;
    return nil;
}

/// Sort choices offered above the cards; they map onto the table's sort descriptors.
static NSArray<NSArray *> *SortChoices(void) {
    return @[@[@"默认顺序", @"", @YES], @[@"每周额度（多→少）", @"long", @NO], @[@"5 小时额度（多→少）", @"short", @NO],
             @[@"续费 / 到期日期", @"expiresAt", @YES], @[@"月费（高→低）", @"price", @NO], @[@"名称", @"name", @YES]];
}

#pragma mark - Stat card

@interface DeskStatCard : NSView
@property (nonatomic, strong) NSTextField *valueLabel;
@property (nonatomic, strong) NSTextField *detailLabel;
@property (nonatomic, strong) NSColor *tint;
@property (nonatomic) BOOL active;
@property (nonatomic, weak) id target;
@property (nonatomic) SEL action;
@end

@implementation DeskStatCard {
    BOOL _pressed;
}
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol tint:(NSColor *)tint {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _tint = tint;
        NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]];
        icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
        icon.contentTintColor = tint;
        NSTextField *titleLabel = DeskLabel(title, 12, NSFontWeightMedium);
        titleLabel.textColor = NSColor.secondaryLabelColor;
        _valueLabel = DeskLabel(@"0", 24, NSFontWeightSemibold);
        _valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:24 weight:NSFontWeightSemibold];
        [_valueLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        _detailLabel = DeskLabel(@"", 11, NSFontWeightRegular);
        _detailLabel.textColor = NSColor.tertiaryLabelColor;
        [_detailLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        for (NSView *view in @[icon, titleLabel, _valueLabel, _detailLabel]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:88],
            [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [icon.topAnchor constraintEqualToAnchor:self.topAnchor constant:13],
            [titleLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
            [titleLabel.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
            [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-10],
            [_valueLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [_valueLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-10],
            [_valueLabel.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:6],
            [_detailLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-10],
            [_detailLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-11]
        ]];
        self.toolTip = title;
        [self setAccessibilityElement:YES];
        [self setAccessibilityRole:NSAccessibilityButtonRole];
        [self setAccessibilityLabel:title];
    }
    return self;
}
- (void)setActive:(BOOL)active { _active = active; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirtyRect {
    NSRect frame = NSInsetRect(self.bounds, 0.75, 0.75);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:frame xRadius:10 yRadius:10];
    [(_pressed ? NSColor.unemphasizedSelectedContentBackgroundColor : NSColor.controlBackgroundColor) setFill];
    [path fill];
    if (self.active) {
        [[self.tint colorWithAlphaComponent:0.08] setFill];
        [path fill];
    }
    path.lineWidth = self.active ? 1.5 : 1;
    [(self.active ? self.tint : NSColor.separatorColor) setStroke];
    [path stroke];
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
@property (nonatomic, strong) NSTextField *subtitleLabel;
@property (nonatomic, strong) NSButton *refreshAllButton;
@property (nonatomic, strong) DeskStatCard *totalCard;
@property (nonatomic, strong) DeskStatCard *quotaCard;
@property (nonatomic, strong) DeskStatCard *expiryCard;
@property (nonatomic, strong) DeskStatCard *spendCard;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSPopUpButton *planFilter;
@property (nonatomic, strong) NSPopUpButton *statusFilter;
@property (nonatomic, strong) NSPopUpButton *groupFilter;
@property (nonatomic, strong) NSPopUpButton *tagFilter;
@property (nonatomic, strong) NSTextField *countLabel;
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

- (NSView *)buildHeader {
    NSTextField *title = DeskLabel(@"账号管理", 22, NSFontWeightBold);
    self.subtitleLabel = DeskLabel(@"", 12, NSFontWeightRegular);
    self.subtitleLabel.textColor = NSColor.secondaryLabelColor;
    [self.subtitleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *titles = [NSStackView stackViewWithViews:@[title, self.subtitleLabel]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 3;

    self.refreshAllButton = DeskButton(@"刷新用量", @"arrow.triangle.2.circlepath", self.coordinator, @selector(refreshAllUsage:));
    self.refreshAllButton.toolTip = @"读取所有账号的用量额度与订阅续费信息（⇧⌘R）";
    NSButton *import = DeskButton(@"导入…", @"square.and.arrow.down", self.coordinator, @selector(importAccounts:));
    NSButton *export = DeskButton(@"导出…", @"square.and.arrow.up", self.coordinator, @selector(exportAccounts:));
    NSButton *add = DeskButton(@"添加账号", @"plus", self.coordinator, @selector(addAccount:));
    add.bezelColor = NSColor.controlAccentColor;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.refreshAllButton, import, export, add]];
    buttons.spacing = 8;
    [buttons setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *header = [NSStackView new];
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 16;
    [header setViews:@[titles] inGravity:NSStackViewGravityLeading];
    [header setViews:@[buttons] inGravity:NSStackViewGravityTrailing];
    [header setClippingResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return header;
}

- (NSView *)buildCards {
    self.totalCard = [[DeskStatCard alloc] initWithTitle:@"全部账号" symbol:@"person.2.fill" tint:NSColor.systemBlueColor];
    self.quotaCard = [[DeskStatCard alloc] initWithTitle:@"额度告急" symbol:@"gauge.with.dots.needle.bottom.0percent" tint:NSColor.systemRedColor];
    self.quotaCard.toolTip = [NSString stringWithFormat:@"5 小时或每周额度剩余不足 %.0f%% 的账号", LowQuotaPercent];
    self.expiryCard = [[DeskStatCard alloc] initWithTitle:@"即将到期" symbol:@"clock.fill" tint:NSColor.systemOrangeColor];
    self.expiryCard.toolTip = @"7 天内到期且不会自动续费的账号";
    self.spendCard = [[DeskStatCard alloc] initWithTitle:@"每月支出" symbol:@"creditcard.fill" tint:NSColor.systemPurpleColor];
    self.spendCard.toolTip = @"已填写月费的付费账号合计；点击查看续费日历";
    NSArray *cards = @[self.totalCard, self.quotaCard, self.expiryCard, self.spendCard];
    for (DeskStatCard *card in cards) {
        card.target = self;
        card.action = @selector(cardClicked:);
    }
    NSStackView *row = [NSStackView stackViewWithViews:cards];
    row.distribution = NSStackViewDistributionFillEqually;
    row.spacing = 12;
    return row;
}

- (NSView *)buildFilters {
    self.searchField = [NSSearchField new];
    self.searchField.placeholderString = @"搜索名称、邮箱、标签或备注";
    self.searchField.sendsSearchStringImmediately = YES;
    self.searchField.target = self;
    self.searchField.action = @selector(filtersChanged:);
    [self.searchField.widthAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;
    [self.searchField setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.planFilter = [self popUpWithAction:@selector(filtersChanged:)];
    [self addItem:@"全部订阅" tag:PlanFilterAll object:nil to:self.planFilter];
    [self addItem:@"付费订阅" tag:PlanFilterPaid object:nil to:self.planFilter];
    [self addItem:@"未获取订阅" tag:PlanFilterUnknown object:nil to:self.planFilter];
    [self.planFilter.menu addItem:[NSMenuItem separatorItem]];
    for (NSString *plan in AccountPlans()) {
        if ([plan isEqualToString:@"Pro"]) [self addItem:@"Pro（全部档位）" tag:PlanFilterFamily object:@"Pro" to:self.planFilter];
        else [self addItem:plan tag:PlanFilterSpecific object:plan to:self.planFilter];
    }

    self.statusFilter = [self popUpWithAction:@selector(filtersChanged:)];
    NSArray *statuses = @[@[@"全部状态", @(StatusFilterAll)], @[],
        @[@"额度充足", @(StatusFilterQuotaOK)], @[@"额度告急", @(StatusFilterQuotaLow)], @[@"未读取用量", @(StatusFilterNoUsage)], @[],
        @[@"自动续费", @(StatusFilterRenewing)], @[@"7 天内到期", @(StatusFilterExpiringSoon)], @[@"已过期", @(StatusFilterExpired)],
        @[@"未设置到期", @(StatusFilterNoExpiry)], @[],
        @[@"已登录", @(StatusFilterSignedIn)], @[@"未登录", @(StatusFilterSignedOut)]];
    for (NSArray *status in statuses) {
        if (!status.count) [self.statusFilter.menu addItem:[NSMenuItem separatorItem]];
        else [self addItem:status[0] tag:[status[1] integerValue] object:nil to:self.statusFilter];
    }
    self.groupFilter = [self popUpWithAction:@selector(filtersChanged:)];
    self.tagFilter = [self popUpWithAction:@selector(filtersChanged:)];

    NSStackView *row = [NSStackView stackViewWithViews:@[self.searchField, self.planFilter, self.statusFilter, self.groupFilter, self.tagFilter]];
    row.spacing = 8;
    return row;
}

- (NSView *)buildContentBar {
    self.countLabel = DeskLabel(@"", 12, NSFontWeightMedium);
    self.countLabel.textColor = NSColor.secondaryLabelColor;
    self.sortPopUp = [self popUpWithAction:@selector(sortChosen:)];
    for (NSArray *choice in SortChoices()) [self addItem:choice[0] tag:0 object:choice to:self.sortPopUp];
    self.sortPopUp.controlSize = NSControlSizeSmall;
    self.sortPopUp.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    self.viewSwitch = [NSSegmentedControl segmentedControlWithImages:@[
            [NSImage imageWithSystemSymbolName:@"square.grid.2x2" accessibilityDescription:@"卡片"],
            [NSImage imageWithSystemSymbolName:@"list.bullet" accessibilityDescription:@"列表"],
            [NSImage imageWithSystemSymbolName:@"calendar" accessibilityDescription:@"日历"]]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(viewSwitched:)];
    [self.viewSwitch setToolTip:@"卡片" forSegment:0];
    [self.viewSwitch setToolTip:@"列表" forSegment:1];
    [self.viewSwitch setToolTip:@"续费日历" forSegment:2];
    self.viewSwitch.controlSize = NSControlSizeSmall;
    self.viewSwitch.selectedSegment = self.viewMode;
    NSStackView *bar = [NSStackView new];
    bar.alignment = NSLayoutAttributeCenterY;
    bar.spacing = 10;
    [bar setViews:@[self.countLabel] inGravity:NSStackViewGravityLeading];
    [bar setViews:@[self.sortPopUp, self.viewSwitch] inGravity:NSStackViewGravityTrailing];
    return bar;
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
    self.tableView.autosaveName = @"AccountManagementTable.v2";
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
    NSView *header = [self buildHeader];
    NSView *cards = [self buildCards];
    NSView *filters = [self buildFilters];
    NSView *contentBar = [self buildContentBar];
    [self buildCollection];
    [self buildTable];
    [self buildCalendar];
    NSBox *topLine = DeskSeparator();
    NSBox *bottomLine = DeskSeparator();
    NSView *footer = [self buildFooter];
    self.emptyLabel = DeskLabel(@"", 13, NSFontWeightRegular);
    self.emptyLabel.textColor = NSColor.secondaryLabelColor;

    NSArray *contents = @[self.cardsScroll, self.tableScroll, self.calendarView];
    for (NSView *view in [@[header, cards, filters, contentBar, topLine, bottomLine, footer] arrayByAddingObjectsFromArray:contents]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    [root addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:16],
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [cards.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:16],
        [cards.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [cards.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [filters.topAnchor constraintEqualToAnchor:cards.bottomAnchor constant:16],
        [filters.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [filters.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [contentBar.topAnchor constraintEqualToAnchor:filters.bottomAnchor constant:12],
        [contentBar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [contentBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [topLine.topAnchor constraintEqualToAnchor:contentBar.bottomAnchor constant:8],
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

- (void)rebuildPopUp:(NSPopUpButton *)popUp allTitle:(NSString *)allTitle noneTitle:(NSString *)noneTitle values:(NSArray<NSString *> *)values {
    NSMenuItem *selected = popUp.selectedItem;
    NSInteger selectedTag = selected.tag;
    NSString *selectedValue = selected.representedObject;
    [popUp removeAllItems];
    [self addItem:allTitle tag:ListFilterAll object:nil to:popUp];
    [self addItem:noneTitle tag:ListFilterNone object:nil to:popUp];
    if (values.count) [popUp.menu addItem:[NSMenuItem separatorItem]];
    for (NSString *value in values) [self addItem:value tag:ListFilterSpecific object:value to:popUp];
    if (selectedTag == ListFilterSpecific && [values containsObject:selectedValue])
        [popUp selectItemAtIndex:[popUp indexOfItemWithRepresentedObject:selectedValue]];
    else
        [popUp selectItemWithTag:selectedTag == ListFilterNone ? ListFilterNone : ListFilterAll];
}

- (BOOL)account:(Account *)account passesFiltersAt:(NSDate *)now {
    if (![account matchesSearch:self.searchField.stringValue]) return NO;
    NSMenuItem *plan = self.planFilter.selectedItem;
    switch ((PlanFilter)plan.tag) {
        case PlanFilterAll: break;
        case PlanFilterPaid: if (!account.isPaid) return NO; break;
        case PlanFilterUnknown: if (account.plan) return NO; break;
        case PlanFilterSpecific: if (![account.plan isEqualToString:plan.representedObject]) return NO; break;
        case PlanFilterFamily: if (![account.planFamily isEqualToString:plan.representedObject]) return NO; break;
    }
    AccountExpiryState state = [account expiryStateFromDate:now];
    NSNumber *lowest = account.usage.lowestRemainingPercent;
    switch ((StatusFilter)self.statusFilter.selectedTag) {
        case StatusFilterAll: break;
        case StatusFilterQuotaOK: if (!lowest || lowest.doubleValue < LowQuotaPercent) return NO; break;
        case StatusFilterQuotaLow: if (!lowest || lowest.doubleValue >= LowQuotaPercent) return NO; break;
        case StatusFilterNoUsage: if (lowest) return NO; break;
        case StatusFilterRenewing: if (state != AccountExpiryStateRenewing) return NO; break;
        case StatusFilterExpiringSoon: if (state != AccountExpiryStateExpiringSoon) return NO; break;
        case StatusFilterExpired: if (state != AccountExpiryStateExpired) return NO; break;
        case StatusFilterNoExpiry: if (state != AccountExpiryStateUnknown) return NO; break;
        case StatusFilterSignedIn: if (!account.signedIn.boolValue) return NO; break;
        case StatusFilterSignedOut: if (!account.signedIn || account.signedIn.boolValue) return NO; break;
    }
    NSMenuItem *group = self.groupFilter.selectedItem;
    if (group.tag == ListFilterNone && account.group.length) return NO;
    if (group.tag == ListFilterSpecific && ![account.group isEqualToString:group.representedObject]) return NO;
    NSMenuItem *tag = self.tagFilter.selectedItem;
    if (tag.tag == ListFilterNone && account.tags.count) return NO;
    if (tag.tag == ListFilterSpecific && ![account.tags containsObject:tag.representedObject]) return NO;
    return YES;
}

- (NSArray<Account *> *)sortedAccounts:(NSArray<Account *> *)accounts {
    NSSortDescriptor *sort = self.tableView.sortDescriptors.firstObject;
    if (!sort.key.length) return accounts;
    NSString *key = sort.key;
    BOOL ascending = sort.ascending;
    return [accounts sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(Account *a, Account *b) {
        id left = SortValue(a, key), right = SortValue(b, key);
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

- (void)reloadAccounts {
    if (!self.isViewLoaded) return;
    AccountStore *store = self.coordinator.store;
    [self rebuildPopUp:self.groupFilter allTitle:@"全部分组" noneTitle:@"未分组" values:store.groups];
    [self rebuildPopUp:self.tagFilter allTitle:@"全部标签" noneTitle:@"无标签" values:store.tags];

    NSDate *now = NSDate.date;
    NSArray<Account *> *accounts = store.accounts;
    NSUInteger paid = 0, signedIn = 0, low = 0, healthy = 0, unread = 0, soon = 0, expired = 0, renewingSoon = 0, priced = 0;
    NSDate *latest = nil;
    NSMutableArray<Account *> *visible = [NSMutableArray array];
    for (Account *account in accounts) {
        if (account.isPaid) paid++;
        if (account.signedIn.boolValue) signedIn++;
        NSNumber *lowest = account.usage.lowestRemainingPercent;
        if (!lowest) unread++;
        else if (lowest.doubleValue < LowQuotaPercent) low++;
        else healthy++;
        AccountExpiryState state = [account expiryStateFromDate:now];
        if (state == AccountExpiryStateExpiringSoon) soon++;
        if (state == AccountExpiryStateExpired) expired++;
        NSNumber *days = [account daysRemainingFromDate:now];
        if (state == AccountExpiryStateRenewing && days.integerValue >= 0 && days.integerValue <= AccountExpiringSoonDays) renewingSoon++;
        if (account.isPaid && account.monthlyPrice) priced++;
        if (account.usage && (!latest || [account.usage.fetchedAt compare:latest] == NSOrderedDescending)) latest = account.usage.fetchedAt;
        if ([self account:account passesFiltersAt:now]) [visible addObject:account];
    }

    self.totalCard.valueLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)accounts.count];
    self.totalCard.detailLabel.stringValue = [NSString stringWithFormat:@"付费 %lu · 已登录 %lu", (unsigned long)paid, (unsigned long)signedIn];
    self.quotaCard.valueLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)low];
    self.quotaCard.detailLabel.stringValue = [NSString stringWithFormat:@"充足 %lu · 未读取 %lu", (unsigned long)healthy, (unsigned long)unread];
    self.expiryCard.valueLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)soon];
    self.expiryCard.detailLabel.stringValue = [NSString stringWithFormat:@"已过期 %lu · 7 天内续费 %lu", (unsigned long)expired, (unsigned long)renewingSoon];
    NSDictionary<NSString *, NSNumber *> *spend = store.monthlySpendByCurrency;
    NSArray<NSString *> *currencies = [spend.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [spend[b] compare:spend[a]];
    }];
    NSMutableArray<NSString *> *amounts = [NSMutableArray array];
    for (NSString *currency in currencies) [amounts addObject:AccountFormatMoney(spend[currency], currency)];
    self.spendCard.valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:amounts.count ? 19 : 24 weight:NSFontWeightSemibold];
    self.spendCard.valueLabel.stringValue = amounts.firstObject ?: @"—";
    self.spendCard.valueLabel.toolTip = [amounts componentsJoinedByString:@"\n"];
    self.spendCard.detailLabel.stringValue = amounts.count > 1
        ? [[amounts subarrayWithRange:NSMakeRange(1, amounts.count - 1)] componentsJoinedByString:@" · "]
        : [NSString stringWithFormat:@"%lu 个付费账号已填写月费", (unsigned long)priced];
    [self updateCardHighlights];

    BOOL refreshing = self.coordinator.isRefreshingUsage;
    self.refreshAllButton.enabled = !refreshing && accounts.count > 0;
    self.refreshAllButton.title = refreshing ? @"正在刷新…" : @"刷新用量";
    self.subtitleLabel.stringValue = latest
        ? [NSString stringWithFormat:@"共 %lu 个账号 · 用量更新于%@", (unsigned long)accounts.count, DeskRelativeTime(latest)]
        : [NSString stringWithFormat:@"共 %lu 个账号 · 点击“刷新用量”读取各账号的额度与续费信息", (unsigned long)accounts.count];

    self.rows = [self sortedAccounts:visible];
    NSMutableArray *selection = [NSMutableArray array];
    for (NSString *identifier in self.selection) if ([store accountWithID:identifier]) [selection addObject:identifier];
    _selection = selection;

    self.applyingSelection = YES;
    [self.tableView reloadData];
    [self.collectionView reloadData];
    self.calendarView.accounts = self.rows;
    self.applyingSelection = NO;
    [self applySelectionToViews];

    self.countLabel.stringValue = self.rows.count == accounts.count
        ? [NSString stringWithFormat:@"%lu 个账号", (unsigned long)accounts.count]
        : [NSString stringWithFormat:@"显示 %lu / %lu 个账号", (unsigned long)self.rows.count, (unsigned long)accounts.count];
    self.emptyLabel.hidden = self.rows.count > 0 || self.viewMode == ManagementViewCalendar;
    self.emptyLabel.stringValue = accounts.count ? @"没有符合筛选条件的账号" : @"还没有账号，点击右上角“添加账号”开始";
    [self updateFooter];
}

- (void)updateCardHighlights {
    BOOL plain = self.searchField.stringValue.length == 0 && self.planFilter.selectedItem.tag == PlanFilterAll &&
        self.groupFilter.selectedItem.tag == ListFilterAll && self.tagFilter.selectedItem.tag == ListFilterAll;
    NSInteger status = self.statusFilter.selectedTag;
    self.totalCard.active = plain && status == StatusFilterAll && self.viewMode != ManagementViewCalendar;
    self.quotaCard.active = plain && status == StatusFilterQuotaLow;
    self.expiryCard.active = plain && status == StatusFilterExpiringSoon;
    self.spendCard.active = self.viewMode == ManagementViewCalendar;
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
    self.selection = selected ? @[selected] : @[];
    [self applySelectionToViews];
    NSUInteger row = [self.rows indexOfObjectPassingTest:^BOOL(Account *account, NSUInteger index, BOOL *stop) {
        return [account.identifier isEqualToString:selected];
    }];
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

- (void)cardClicked:(DeskStatCard *)card {
    if (card == self.spendCard) {
        [self switchToView:ManagementViewCalendar];
        return;
    }
    self.searchField.stringValue = @"";
    [self.planFilter selectItemWithTag:PlanFilterAll];
    [self.groupFilter selectItemWithTag:ListFilterAll];
    [self.tagFilter selectItemWithTag:ListFilterAll];
    StatusFilter status = card == self.quotaCard ? StatusFilterQuotaLow : (card == self.expiryCard ? StatusFilterExpiringSoon : StatusFilterAll);
    [self.statusFilter selectItemWithTag:status];
    if (self.viewMode == ManagementViewCalendar) [self switchToView:ManagementViewCards];
    [self reloadAccounts];
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
    [self updateCardHighlights];
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
    [item configureWithAccount:account refreshing:[self.coordinator isRefreshingAccountID:account.identifier] now:NSDate.date];
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
