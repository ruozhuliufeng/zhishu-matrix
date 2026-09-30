#import "ManagementController.h"
#import "Account.h"
#import "DeskUI.h"

typedef NS_ENUM(NSInteger, PlanFilter) {
    PlanFilterAll = 0,
    PlanFilterPaid,
    PlanFilterUnknown,
    PlanFilterSpecific,
};

typedef NS_ENUM(NSInteger, StatusFilter) {
    StatusFilterAll = 0,
    StatusFilterActive,
    StatusFilterExpiringSoon,
    StatusFilterExpired,
    StatusFilterNoExpiry,
    StatusFilterSignedIn,
    StatusFilterSignedOut,
};

typedef NS_ENUM(NSInteger, GroupFilter) {
    GroupFilterAll = 0,
    GroupFilterUngrouped,
    GroupFilterSpecific,
};

static NSArray<NSArray *> *ColumnSpecs(void) {
    // identifier, title, width, minimum width, sort key
    return @[
        @[@"name", @"账号", @150, @100, @"name"],
        @[@"email", @"邮箱", @170, @130, @"email"],
        @[@"group", @"分组", @70, @44, @"group"],
        @[@"plan", @"订阅", @80, @70, @"plan"],
        @[@"expiresAt", @"到期日期", @88, @84, @"expiresAt"],
        @[@"remaining", @"剩余", @84, @72, @"expiresAt"],
        @[@"signedIn", @"登录", @56, @48, @"signedIn"],
        @[@"lastUsedAt", @"最近使用", @84, @60, @"lastUsedAt"],
        @[@"notes", @"备注", @150, @60, @"notes"],
    ];
}

static id SortValue(Account *account, NSString *key) {
    if ([key isEqualToString:@"name"]) return account.name;
    if ([key isEqualToString:@"email"]) return account.email.length ? account.email : nil;
    if ([key isEqualToString:@"group"]) return account.group.length ? account.group : nil;
    if ([key isEqualToString:@"plan"]) return account.planRank ? @(account.planRank) : nil;
    if ([key isEqualToString:@"expiresAt"]) return account.expiresAt;
    if ([key isEqualToString:@"signedIn"]) return account.signedIn;
    if ([key isEqualToString:@"lastUsedAt"]) return account.lastUsedAt;
    if ([key isEqualToString:@"notes"]) return account.notes.length ? account.notes : nil;
    return nil;
}

#pragma mark - Stat card

@interface DeskStatCard : NSView
@property (nonatomic, strong) NSTextField *valueLabel;
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
        icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightSemibold];
        icon.contentTintColor = tint;
        NSTextField *titleLabel = DeskLabel(title, 12, NSFontWeightMedium);
        titleLabel.textColor = NSColor.secondaryLabelColor;
        _valueLabel = DeskLabel(@"0", 26, NSFontWeightSemibold);
        _valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:26 weight:NSFontWeightSemibold];
        for (NSView *view in @[icon, titleLabel, _valueLabel]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:78],
            [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [icon.topAnchor constraintEqualToAnchor:self.topAnchor constant:13],
            [titleLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
            [titleLabel.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
            [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-10],
            [_valueLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [_valueLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10]
        ]];
        self.toolTip = [NSString stringWithFormat:@"筛选：%@", title];
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

#pragma mark - Cells

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

#pragma mark - Controller

@interface ManagementController () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
@property (nonatomic, weak) id<AccountCoordinator> coordinator;
@property (nonatomic, strong) NSTextField *subtitleLabel;
@property (nonatomic, strong) DeskStatCard *totalCard;
@property (nonatomic, strong) DeskStatCard *paidCard;
@property (nonatomic, strong) DeskStatCard *soonCard;
@property (nonatomic, strong) DeskStatCard *expiredCard;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSPopUpButton *planFilter;
@property (nonatomic, strong) NSPopUpButton *statusFilter;
@property (nonatomic, strong) NSPopUpButton *groupFilter;
@property (nonatomic, strong) DeskTableView *tableView;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSTextField *footerLabel;
@property (nonatomic, strong) NSArray<NSButton *> *batchButtons;
@property (nonatomic, copy) NSArray<Account *> *rows;
@property (nonatomic) BOOL applyingSelection;
@property (nonatomic) BOOL fittedColumns;
@end

@implementation ManagementController

- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _coordinator = coordinator;
        _rows = @[];
    }
    return self;
}

#pragma mark - Layout

- (NSPopUpButton *)popUpWithItems:(NSArray<NSArray *> *)items {
    NSPopUpButton *popUp = [NSPopUpButton new];
    for (NSArray *item in items) {
        if (!item.count) { [popUp.menu addItem:[NSMenuItem separatorItem]]; continue; }
        [popUp addItemWithTitle:item[0]];
        popUp.lastItem.tag = [item[1] integerValue];
        if (item.count > 2) popUp.lastItem.representedObject = item[2];
    }
    popUp.target = self;
    popUp.action = @selector(filtersChanged:);
    popUp.translatesAutoresizingMaskIntoConstraints = NO;
    return popUp;
}

- (NSView *)buildHeader {
    NSTextField *title = DeskLabel(@"账号管理", 22, NSFontWeightBold);
    self.subtitleLabel = DeskLabel(@"", 12, NSFontWeightRegular);
    self.subtitleLabel.textColor = NSColor.secondaryLabelColor;
    NSStackView *titles = [NSStackView stackViewWithViews:@[title, self.subtitleLabel]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 3;
    [self.subtitleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSButton *import = DeskButton(@"导入…", @"square.and.arrow.down", self.coordinator, @selector(importAccounts:));
    NSButton *export = DeskButton(@"导出全部…", @"square.and.arrow.up", self.coordinator, @selector(exportAccounts:));
    NSButton *add = DeskButton(@"添加账号", @"plus", self.coordinator, @selector(addAccount:));
    add.bezelColor = NSColor.controlAccentColor;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[import, export, add]];
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
    self.paidCard = [[DeskStatCard alloc] initWithTitle:@"付费订阅" symbol:@"star.fill" tint:NSColor.systemPurpleColor];
    self.soonCard = [[DeskStatCard alloc] initWithTitle:@"7 天内到期" symbol:@"clock.fill" tint:NSColor.systemOrangeColor];
    self.expiredCard = [[DeskStatCard alloc] initWithTitle:@"已过期" symbol:@"exclamationmark.circle.fill" tint:NSColor.systemRedColor];
    NSArray *cards = @[self.totalCard, self.paidCard, self.soonCard, self.expiredCard];
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
    self.searchField.placeholderString = @"搜索名称、邮箱、分组或备注";
    self.searchField.sendsSearchStringImmediately = YES;
    self.searchField.target = self;
    self.searchField.action = @selector(filtersChanged:);
    [self.searchField.widthAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;
    [self.searchField setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSMutableArray *planItems = [@[@[@"全部订阅", @(PlanFilterAll)], @[@"付费订阅", @(PlanFilterPaid)], @[],
                                   @[@"未获取订阅", @(PlanFilterUnknown)]] mutableCopy];
    for (NSString *plan in AccountPlans()) [planItems addObject:@[plan, @(PlanFilterSpecific), plan]];
    self.planFilter = [self popUpWithItems:planItems];
    self.statusFilter = [self popUpWithItems:@[
        @[@"全部状态", @(StatusFilterAll)], @[],
        @[@"正常", @(StatusFilterActive)], @[@"7 天内到期", @(StatusFilterExpiringSoon)],
        @[@"已过期", @(StatusFilterExpired)], @[@"未设置到期", @(StatusFilterNoExpiry)], @[],
        @[@"已登录", @(StatusFilterSignedIn)], @[@"未登录", @(StatusFilterSignedOut)]
    ]];
    self.groupFilter = [self popUpWithItems:@[@[@"全部分组", @(GroupFilterAll)]]];

    NSStackView *row = [NSStackView stackViewWithViews:@[self.searchField, self.planFilter, self.statusFilter, self.groupFilter]];
    row.spacing = 8;
    row.distribution = NSStackViewDistributionFill;
    return row;
}

- (NSTableView *)buildTable {
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
        [self.tableView addTableColumn:column];
        if ([spec[0] isEqualToString:@"name"]) continue;
        NSMenuItem *toggle = [[NSMenuItem alloc] initWithTitle:spec[1] action:@selector(toggleColumn:) keyEquivalent:@""];
        toggle.target = self;
        toggle.representedObject = column;
        [headerMenu addItem:toggle];
    }
    headerMenu.delegate = self;
    self.tableView.headerView.menu = headerMenu;
    self.tableView.autosaveName = @"AccountManagementTable";
    self.tableView.autosaveTableColumns = YES;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.target = self;
    self.tableView.doubleAction = @selector(openClickedRow:);
    self.tableView.menu = [NSMenu new];
    self.tableView.menu.delegate = self;
    __weak typeof(self) weakSelf = self;
    self.tableView.deleteHandler = ^{
        NSArray *identifiers = weakSelf.selectedAccountIDs;
        if (identifiers.count) [weakSelf.coordinator deleteAccountIDs:identifiers];
    };
    self.tableView.returnHandler = ^{
        NSArray *identifiers = weakSelf.selectedAccountIDs;
        if (identifiers.count == 1) [weakSelf.coordinator openAccountID:identifiers.firstObject];
    };
    return self.tableView;
}

- (NSView *)buildFooter {
    self.footerLabel = DeskLabel(@"", 12, NSFontWeightRegular);
    self.footerLabel.textColor = NSColor.secondaryLabelColor;
    [self.footerLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *group = DeskButton(@"分组…", @"folder", self, @selector(batchGroup:));
    group.toolTip = @"把所选账号移动到分组";
    NSButton *clear = DeskButton(@"清除登录…", @"rectangle.portrait.and.arrow.right", self, @selector(batchClear:));
    clear.toolTip = @"清除所选账号在本机的登录数据，保留账号资料";
    NSButton *export = DeskButton(@"导出…", @"square.and.arrow.up", self, @selector(batchExport:));
    export.toolTip = @"导出所选账号的资料";
    NSButton *remove = DeskButton(@"删除…", @"trash", self, @selector(batchDelete:));
    remove.contentTintColor = NSColor.systemRedColor;
    self.batchButtons = @[group, clear, export, remove];
    for (NSButton *button in self.batchButtons) button.controlSize = NSControlSizeSmall;
    NSStackView *buttons = [NSStackView stackViewWithViews:self.batchButtons];
    buttons.spacing = 6;
    [buttons setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *footer = [NSStackView new];
    footer.spacing = 12;
    footer.alignment = NSLayoutAttributeCenterY;
    footer.edgeInsets = NSEdgeInsetsMake(0, 24, 0, 24);
    [footer setViews:@[self.footerLabel] inGravity:NSStackViewGravityLeading];
    [footer setViews:@[buttons] inGravity:NSStackViewGravityTrailing];
    return footer;
}

- (void)loadView {
    NSView *root = [NSView new];
    self.view = root;
    NSView *header = [self buildHeader];
    NSView *cards = [self buildCards];
    NSView *filters = [self buildFilters];
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = [self buildTable];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers = YES;
    NSBox *topLine = DeskSeparator();
    NSBox *bottomLine = DeskSeparator();
    NSView *footer = [self buildFooter];
    self.emptyLabel = DeskLabel(@"", 13, NSFontWeightRegular);
    self.emptyLabel.textColor = NSColor.secondaryLabelColor;

    for (NSView *view in @[header, cards, filters, topLine, scroll, self.emptyLabel, bottomLine, footer]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:18],
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [cards.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:18],
        [cards.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [cards.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [filters.topAnchor constraintEqualToAnchor:cards.bottomAnchor constant:18],
        [filters.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [filters.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [topLine.topAnchor constraintEqualToAnchor:filters.bottomAnchor constant:12],
        [topLine.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [topLine.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:topLine.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:bottomLine.topAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:scroll.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:scroll.centerYAnchor],
        [bottomLine.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [bottomLine.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [bottomLine.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:42]
    ]];
    [self reloadAccounts];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    // Scale the (possibly autosaved) column widths to the visible width once per launch.
    if (!self.fittedColumns && self.tableView.enclosingScrollView.contentSize.width > 0) {
        self.fittedColumns = YES;
        [self.tableView sizeToFit];
    }
}

#pragma mark - Data

- (void)rebuildGroupFilter {
    NSMenuItem *selected = self.groupFilter.selectedItem;
    NSInteger selectedTag = selected.tag;
    NSString *selectedGroup = selected.representedObject;
    [self.groupFilter removeAllItems];
    [self.groupFilter addItemWithTitle:@"全部分组"];
    self.groupFilter.lastItem.tag = GroupFilterAll;
    [self.groupFilter addItemWithTitle:@"未分组"];
    self.groupFilter.lastItem.tag = GroupFilterUngrouped;
    NSArray<NSString *> *groups = self.coordinator.store.groups;
    if (groups.count) [self.groupFilter.menu addItem:[NSMenuItem separatorItem]];
    for (NSString *group in groups) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:group action:nil keyEquivalent:@""];
        item.tag = GroupFilterSpecific;
        item.representedObject = group;
        [self.groupFilter.menu addItem:item];
    }
    if (selectedTag == GroupFilterSpecific && [groups containsObject:selectedGroup])
        [self.groupFilter selectItemAtIndex:[self.groupFilter indexOfItemWithRepresentedObject:selectedGroup]];
    else if (selectedTag == GroupFilterUngrouped)
        [self.groupFilter selectItemWithTag:GroupFilterUngrouped];
    else
        [self.groupFilter selectItemWithTag:GroupFilterAll];
}

- (BOOL)accountPassesFilters:(Account *)account now:(NSDate *)now {
    if (![account matchesSearch:self.searchField.stringValue]) return NO;
    NSMenuItem *plan = self.planFilter.selectedItem;
    switch ((PlanFilter)plan.tag) {
        case PlanFilterAll: break;
        case PlanFilterPaid: if (!account.isPaid) return NO; break;
        case PlanFilterUnknown: if (account.plan) return NO; break;
        case PlanFilterSpecific: if (![account.plan isEqualToString:plan.representedObject]) return NO; break;
    }
    AccountExpiryState state = [account expiryStateFromDate:now];
    switch ((StatusFilter)self.statusFilter.selectedTag) {
        case StatusFilterAll: break;
        case StatusFilterActive: if (state != AccountExpiryStateActive) return NO; break;
        case StatusFilterExpiringSoon: if (state != AccountExpiryStateExpiringSoon) return NO; break;
        case StatusFilterExpired: if (state != AccountExpiryStateExpired) return NO; break;
        case StatusFilterNoExpiry: if (state != AccountExpiryStateUnknown) return NO; break;
        case StatusFilterSignedIn: if (!account.signedIn.boolValue) return NO; break;
        case StatusFilterSignedOut: if (!account.signedIn || account.signedIn.boolValue) return NO; break;
    }
    NSMenuItem *group = self.groupFilter.selectedItem;
    switch ((GroupFilter)group.tag) {
        case GroupFilterAll: break;
        case GroupFilterUngrouped: if (account.group.length) return NO; break;
        case GroupFilterSpecific: if (![account.group isEqualToString:group.representedObject]) return NO; break;
    }
    return YES;
}

- (NSArray<Account *> *)sortedAccounts:(NSArray<Account *> *)accounts {
    NSSortDescriptor *sort = self.tableView.sortDescriptors.firstObject;
    if (!sort.key) return accounts;
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

- (void)reloadAccounts {
    if (!self.isViewLoaded) return;
    NSArray<NSString *> *previousSelection = self.selectedAccountIDs;
    [self rebuildGroupFilter];

    NSDate *now = NSDate.date;
    NSArray<Account *> *accounts = self.coordinator.store.accounts;
    NSUInteger paid = 0, soon = 0, expired = 0;
    NSMutableArray<Account *> *visible = [NSMutableArray array];
    for (Account *account in accounts) {
        if (account.isPaid) paid++;
        AccountExpiryState state = [account expiryStateFromDate:now];
        if (state == AccountExpiryStateExpiringSoon) soon++;
        if (state == AccountExpiryStateExpired) expired++;
        if ([self accountPassesFilters:account now:now]) [visible addObject:account];
    }
    self.totalCard.valueLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)accounts.count];
    self.paidCard.valueLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)paid];
    self.soonCard.valueLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)soon];
    self.expiredCard.valueLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)expired];
    [self updateCardHighlights];
    self.subtitleLabel.stringValue = @"账号资料仅保存在本机，不含密码和访问令牌";

    self.rows = [self sortedAccounts:visible];
    self.applyingSelection = YES;
    [self.tableView reloadData];
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    [self.rows enumerateObjectsUsingBlock:^(Account *account, NSUInteger index, BOOL *stop) {
        if ([previousSelection containsObject:account.identifier]) [rows addIndex:index];
    }];
    [self.tableView selectRowIndexes:rows byExtendingSelection:NO];
    self.applyingSelection = NO;

    self.emptyLabel.hidden = self.rows.count > 0;
    self.emptyLabel.stringValue = accounts.count ? @"没有符合筛选条件的账号" : @"还没有账号，点击右上角“添加账号”开始";
    if (!previousSelection.count) [self reflectSelection];
    [self updateFooter];
}

- (void)updateCardHighlights {
    BOOL searchEmpty = self.searchField.stringValue.length == 0;
    BOOL groupAll = self.groupFilter.selectedTag == GroupFilterAll;
    NSInteger plan = self.planFilter.selectedItem.tag;
    NSInteger status = self.statusFilter.selectedTag;
    BOOL onlyPlan = searchEmpty && groupAll && status == StatusFilterAll;
    BOOL onlyStatus = searchEmpty && groupAll && plan == PlanFilterAll;
    self.totalCard.active = onlyPlan && plan == PlanFilterAll;
    self.paidCard.active = onlyPlan && plan == PlanFilterPaid;
    self.soonCard.active = onlyStatus && status == StatusFilterExpiringSoon;
    self.expiredCard.active = onlyStatus && status == StatusFilterExpired;
}

- (void)updateFooter {
    NSUInteger total = self.coordinator.store.accounts.count;
    NSUInteger selected = self.tableView.selectedRowIndexes.count;
    NSMutableArray *parts = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"共 %lu 个账号", (unsigned long)total]];
    if (self.rows.count != total) [parts addObject:[NSString stringWithFormat:@"显示 %lu 个", (unsigned long)self.rows.count]];
    if (selected) [parts addObject:[NSString stringWithFormat:@"已选择 %lu 个", (unsigned long)selected]];
    self.footerLabel.stringValue = [parts componentsJoinedByString:@" · "];
    for (NSButton *button in self.batchButtons) button.enabled = selected > 0;
}

- (NSArray<NSString *> *)selectedAccountIDs {
    if (!self.isViewLoaded) return @[];
    NSMutableArray *identifiers = [NSMutableArray array];
    [self.tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        if (index < self.rows.count) [identifiers addObject:self.rows[index].identifier];
    }];
    return identifiers;
}

- (void)reflectSelection {
    if (!self.isViewLoaded) return;
    NSString *selected = self.coordinator.selectedAccountID;
    NSArray *current = self.selectedAccountIDs;
    if (current.count > 1 && [current containsObject:selected]) return;
    NSUInteger row = [self.rows indexOfObjectPassingTest:^BOOL(Account *account, NSUInteger index, BOOL *stop) {
        return [account.identifier isEqualToString:selected];
    }];
    self.applyingSelection = YES;
    if (row != NSNotFound) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [self.tableView scrollRowToVisible:(NSInteger)row];
    } else {
        [self.tableView deselectAll:nil];
    }
    self.applyingSelection = NO;
    [self updateFooter];
}

- (void)focusSearch { [self.view.window makeFirstResponder:self.searchField]; }
- (void)focusTable { [self.view.window makeFirstResponder:self.tableView]; }

#pragma mark - Actions

- (void)filtersChanged:(id)sender { [self reloadAccounts]; }

- (void)cardClicked:(DeskStatCard *)card {
    self.searchField.stringValue = @"";
    [self.groupFilter selectItemWithTag:GroupFilterAll];
    [self.planFilter selectItemWithTag:card == self.paidCard ? PlanFilterPaid : PlanFilterAll];
    StatusFilter status = card == self.soonCard ? StatusFilterExpiringSoon
        : (card == self.expiredCard ? StatusFilterExpired : StatusFilterAll);
    [self.statusFilter selectItemWithTag:status];
    [self reloadAccounts];
}

- (void)openClickedRow:(id)sender {
    NSInteger row = self.tableView.clickedRow;
    if (row >= 0 && row < (NSInteger)self.rows.count) [self.coordinator openAccountID:self.rows[row].identifier];
}

- (void)toggleColumn:(NSMenuItem *)sender {
    NSTableColumn *column = sender.representedObject;
    column.hidden = !column.hidden;
}

- (void)batchGroup:(id)sender { [self.coordinator promptGroupForAccountIDs:self.selectedAccountIDs]; }
- (void)batchClear:(id)sender { [self.coordinator clearLoginDataForAccountIDs:self.selectedAccountIDs]; }
- (void)batchExport:(id)sender { [self.coordinator exportAccountIDs:self.selectedAccountIDs]; }
- (void)batchDelete:(id)sender { [self.coordinator deleteAccountIDs:self.selectedAccountIDs]; }

#pragma mark - Menus

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == self.tableView.headerView.menu) {
        for (NSMenuItem *item in menu.itemArray)
            item.state = [item.representedObject isHidden] ? NSControlStateValueOff : NSControlStateValueOn;
        return;
    }
    NSInteger clicked = self.tableView.clickedRow;
    NSArray<NSString *> *identifiers = @[];
    if (clicked >= 0 && clicked < (NSInteger)self.rows.count) {
        identifiers = [self.tableView.selectedRowIndexes containsIndex:clicked]
            ? self.selectedAccountIDs : @[self.rows[clicked].identifier];
    }
    [self.coordinator populateMenu:menu forAccountIDs:identifiers];
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
    return cell;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    Account *account = self.rows[row];
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
        cell.pill.tintColor = DeskColorForPlan(account.plan);
        return cell;
    }

    NSTableCellView *cell = [self textCellInTable:tableView];
    NSTextField *label = cell.textField;
    NSString *value = @"";
    if ([column isEqualToString:@"email"]) {
        value = account.email.length ? account.email : @"—";
        if (!account.email.length) label.textColor = NSColor.tertiaryLabelColor;
    } else if ([column isEqualToString:@"group"]) {
        value = account.group.length ? account.group : @"—";
        if (!account.group.length) label.textColor = NSColor.tertiaryLabelColor;
    } else if ([column isEqualToString:@"expiresAt"]) {
        value = account.expiresAt ?: @"—";
        label.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
        if (!account.expiresAt) label.textColor = NSColor.tertiaryLabelColor;
    } else if ([column isEqualToString:@"remaining"]) {
        AccountExpiryState state = [account expiryStateFromDate:now];
        value = state == AccountExpiryStateUnknown ? @"—" : [account expiryDescriptionFromDate:now];
        label.textColor = state == AccountExpiryStateUnknown ? NSColor.tertiaryLabelColor
            : (state == AccountExpiryStateActive ? NSColor.secondaryLabelColor : DeskColorForExpiry(state));
        if (state == AccountExpiryStateExpired || state == AccountExpiryStateExpiringSoon)
            label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    } else if ([column isEqualToString:@"signedIn"]) {
        value = account.signedIn ? (account.signedIn.boolValue ? @"已登录" : @"未登录") : @"—";
        label.textColor = account.signedIn.boolValue ? NSColor.systemGreenColor
            : (account.signedIn ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor);
    } else if ([column isEqualToString:@"lastUsedAt"]) {
        value = DeskRelativeTime(account.lastUsedAt);
        label.textColor = account.lastUsedAt ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor;
    } else if ([column isEqualToString:@"notes"]) {
        value = [[account.notes componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsJoinedByString:@" "];
        if (!value.length) { value = @"—"; label.textColor = NSColor.tertiaryLabelColor; }
    }
    label.stringValue = value;
    cell.toolTip = [column isEqualToString:@"notes"] && account.notes.length ? account.notes : nil;
    return cell;
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    [self reloadAccounts];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateFooter];
    if (self.applyingSelection) return;
    [self.coordinator managementSelectionDidChange:self.selectedAccountIDs];
}
@end
