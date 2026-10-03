#import "AccountSidebarController.h"
#import "Account.h"
#import "AccountInsights.h"
#import "DeskUI.h"

static NSPasteboardType const AccountRowPasteboardType = @"local.zhishu.chatgpt-account-desk.account-row";
static NSUserInterfaceItemIdentifier const AccountCellIdentifier = @"AccountCell";
static NSUserInterfaceItemIdentifier const GroupCellIdentifier = @"GroupCell";

@interface AccountSidebarCell : NSTableCellView
@property (nonatomic, strong) DeskAvatarView *avatar;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *detailLabel;
@property (nonatomic, strong) DeskPillView *pill;
@property (nonatomic, strong) DeskQuotaBar *quotaBar;
@property (nonatomic, strong) NSColor *detailColor;
- (void)configureWithAccount:(Account *)account status:(AccountStatus *)status now:(NSDate *)now;
@end

@implementation AccountSidebarCell
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _avatar = [DeskAvatarView new];
        _nameLabel = DeskLabel(@"", 13, NSFontWeightMedium);
        _detailLabel = DeskLabel(@"", 11, NSFontWeightRegular);
        _detailColor = NSColor.secondaryLabelColor;
        _pill = [DeskPillView new];
        _quotaBar = [DeskQuotaBar new];
        for (NSView *view in @[_avatar, _nameLabel, _detailLabel, _pill, _quotaBar]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:view];
        }
        self.textField = _nameLabel;
        [_nameLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_detailLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [_avatar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [_avatar.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_avatar.widthAnchor constraintEqualToConstant:30],
            [_avatar.heightAnchor constraintEqualToConstant:30],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:_avatar.trailingAnchor constant:9],
            [_nameLabel.bottomAnchor constraintEqualToAnchor:self.centerYAnchor constant:1],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_pill.leadingAnchor constant:-6],
            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.topAnchor constraintEqualToAnchor:self.centerYAnchor constant:2],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-6],
            [_pill.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
            [_pill.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],
            [_quotaBar.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_quotaBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
            [_quotaBar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-3],
            [_quotaBar.heightAnchor constraintEqualToConstant:3]
        ]];
    }
    return self;
}

- (void)configureWithAccount:(Account *)account status:(AccountStatus *)status now:(NSDate *)now {
    self.avatar.name = account.name;
    self.avatar.seed = account.identifier;
    BOOL attention = status.tone == AccountStatusToneCritical || status.tone == AccountStatusToneWarning;
    self.avatar.statusColor = attention ? DeskColorForTone(status.tone) : (account.signedIn.boolValue ? NSColor.systemGreenColor : nil);
    self.nameLabel.stringValue = account.name;
    self.pill.text = account.plan ?: @"";
    self.pill.tintColor = DeskColorForPlan(account.plan);
    AccountUsageWindow *weekly = account.usage.longWindow ?: account.usage.shortWindow;
    self.quotaBar.hidden = weekly == nil;
    self.quotaBar.remainingPercent = weekly ? @(weekly.remainingPercent) : nil;

    AccountExpiryState state = [account expiryStateFromDate:now];
    NSString *detail = nil;
    NSColor *color = NSColor.secondaryLabelColor;
    NSMutableArray *quota = [NSMutableArray array];
    if (account.usage.longWindow) [quota addObject:[NSString stringWithFormat:@"周剩 %.0f%%", account.usage.longWindow.remainingPercent]];
    if (account.usage.shortWindow) [quota addObject:[NSString stringWithFormat:@"5 小时剩 %.0f%%", account.usage.shortWindow.remainingPercent]];
    if (status.kind == AccountStatusQuotaLow && quota.count) {
        detail = [quota componentsJoinedByString:@" · "];
        color = DeskColorForTone(status.tone);
    } else if (attention) {
        detail = status.kind == AccountStatusExpiringSoon || status.kind == AccountStatusExpired
            ? [account expiryDescriptionFromDate:now] : status.title;
        color = DeskColorForTone(status.tone);
    } else if (quota.count) {
        detail = [quota componentsJoinedByString:@" · "];
    } else if (account.email.length) {
        detail = account.email;
    } else if (state == AccountExpiryStateActive || state == AccountExpiryStateRenewing) {
        detail = [account expiryDescriptionFromDate:now];
    } else {
        detail = account.plan ? @"未设置到期日期" : @"未获取订阅信息";
    }
    self.detailLabel.stringValue = detail;
    self.detailColor = color;
    [self applyDetailColor];
    NSMutableArray *tip = [NSMutableArray arrayWithObject:account.name];
    if (account.email.length) [tip addObject:account.email];
    [tip addObject:[NSString stringWithFormat:@"%@ · %@", account.planTitle, [account expiryDescriptionFromDate:now]]];
    if (account.tags.count) [tip addObject:[@"标签：" stringByAppendingString:[account.tags componentsJoinedByString:@"、"]]];
    self.toolTip = [tip componentsJoinedByString:@"\n"];
}

- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    [super setBackgroundStyle:backgroundStyle];
    self.pill.backgroundStyle = backgroundStyle;
    [self applyDetailColor];
}

- (void)applyDetailColor {
    BOOL emphasized = self.backgroundStyle == NSBackgroundStyleEmphasized;
    self.nameLabel.textColor = emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor;
    self.detailLabel.textColor = emphasized
        ? [NSColor.alternateSelectedControlTextColor colorWithAlphaComponent:0.85] : self.detailColor;
}
@end

@interface AccountSidebarController () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
@property (nonatomic, weak) id<AccountCoordinator> coordinator;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) DeskTableView *tableView;
@property (nonatomic, strong) NSTextField *countLabel;
@property (nonatomic, strong) NSTextField *emptyLabel;
/// Mixed rows: NSString for a group header (empty string = ungrouped), Account for an account.
@property (nonatomic, copy) NSArray *rows;
@property (nonatomic) BOOL applyingSelection;
@end

@implementation AccountSidebarController

- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _coordinator = coordinator;
        _rows = @[];
    }
    return self;
}

- (void)loadView {
    NSView *root = [NSView new];
    self.view = root;

    self.searchField = [NSSearchField new];
    self.searchField.placeholderString = @"搜索账号";
    self.searchField.toolTip = @"按名称、邮箱、分组、订阅或备注搜索";
    self.searchField.sendsSearchStringImmediately = YES;
    self.searchField.target = self;
    self.searchField.action = @selector(searchChanged:);

    self.tableView = [DeskTableView new];
    self.tableView.style = NSTableViewStyleSourceList;
    self.tableView.headerView = nil;
    self.tableView.rowSizeStyle = NSTableViewRowSizeStyleCustom;
    self.tableView.floatsGroupRows = NO;
    self.tableView.allowsEmptySelection = YES;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"account"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:column];
    self.tableView.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.target = self;
    self.tableView.doubleAction = @selector(openClickedRow:);
    self.tableView.menu = [NSMenu new];
    self.tableView.menu.delegate = self;
    [self.tableView registerForDraggedTypes:@[AccountRowPasteboardType]];
    [self.tableView setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    __weak typeof(self) weakSelf = self;
    self.tableView.deleteHandler = ^{
        Account *account = [weakSelf accountAtRow:weakSelf.tableView.selectedRow];
        if (account) [weakSelf.coordinator deleteAccountIDs:@[account.identifier]];
    };
    self.tableView.returnHandler = ^{
        Account *account = [weakSelf accountAtRow:weakSelf.tableView.selectedRow];
        if (account) [weakSelf.coordinator openAccountID:account.identifier];
    };

    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = self.tableView;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;

    self.emptyLabel = [NSTextField wrappingLabelWithString:@""];
    self.emptyLabel.alignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = NSColor.secondaryLabelColor;
    self.emptyLabel.font = [NSFont systemFontOfSize:12];

    NSBox *separator = DeskSeparator();
    NSButton *add = DeskIconButton(@"plus", @"添加账号", self.coordinator, @selector(addAccount:));
    NSButton *manage = DeskIconButton(@"tablecells", @"账号管理", self.coordinator, @selector(showManagement:));
    self.countLabel = DeskLabel(@"", 11, NSFontWeightRegular);
    self.countLabel.textColor = NSColor.secondaryLabelColor;

    for (NSView *view in @[self.searchField, scroll, self.emptyLabel, separator, add, manage, self.countLabel]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.searchField.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:8],
        [self.searchField.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:10],
        [self.searchField.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-10],
        [scroll.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor constant:8],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:separator.topAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:scroll.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:scroll.centerYAnchor constant:-24],
        [self.emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:scroll.widthAnchor constant:-40],
        [separator.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-36],
        [add.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:8],
        [add.centerYAnchor constraintEqualToAnchor:root.bottomAnchor constant:-18],
        [manage.leadingAnchor constraintEqualToAnchor:add.trailingAnchor constant:2],
        [manage.centerYAnchor constraintEqualToAnchor:add.centerYAnchor],
        [self.countLabel.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-12],
        [self.countLabel.centerYAnchor constraintEqualToAnchor:add.centerYAnchor],
        [self.countLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:manage.trailingAnchor constant:8]
    ]];
    [self reloadAccounts];
}

#pragma mark - Data

- (Account *)accountAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.rows.count) return nil;
    id item = self.rows[row];
    return [item isKindOfClass:Account.class] ? item : nil;
}

- (BOOL)isFiltering { return self.searchField.stringValue.length > 0; }

- (void)reloadAccounts {
    if (!self.isViewLoaded) return;
    AccountStore *store = self.coordinator.store;
    NSArray<Account *> *accounts = store.visibleAccounts;
    NSMutableArray<Account *> *visible = [NSMutableArray array];
    for (Account *account in accounts)
        if ([account matchesSearch:self.searchField.stringValue]) [visible addObject:account];

    NSArray<NSString *> *groups = store.groups;
    NSMutableArray *rows = [NSMutableArray array];
    if (!groups.count) {
        [rows addObjectsFromArray:visible];
    } else {
        for (NSString *group in [groups arrayByAddingObject:@""]) {
            NSMutableArray *members = [NSMutableArray array];
            for (Account *account in visible) if ([account.group isEqualToString:group]) [members addObject:account];
            if (!members.count) continue;
            [rows addObject:group];
            [rows addObjectsFromArray:members];
        }
    }
    self.rows = rows;
    self.applyingSelection = YES;
    [self.tableView reloadData];
    self.applyingSelection = NO;

    self.countLabel.stringValue = [NSString stringWithFormat:@"%lu 个账号", (unsigned long)accounts.count];
    self.emptyLabel.hidden = visible.count > 0;
    self.emptyLabel.stringValue = accounts.count ? @"没有匹配的账号" : @"还没有账号\n点击下方 + 添加";
    [self reflectSelection];
}

- (void)reflectSelection {
    if (!self.isViewLoaded) return;
    NSString *selected = self.coordinator.selectedAccountID;
    NSInteger row = -1;
    for (NSInteger index = 0; index < (NSInteger)self.rows.count; index++)
        if ([[self accountAtRow:index].identifier isEqualToString:selected]) { row = index; break; }
    self.applyingSelection = YES;
    if (row >= 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [self.tableView scrollRowToVisible:row];
    } else {
        [self.tableView deselectAll:nil];
    }
    self.applyingSelection = NO;
}

- (NSArray<NSString *> *)visibleAccountIDs {
    NSMutableArray *identifiers = [NSMutableArray array];
    for (id item in self.rows) if ([item isKindOfClass:Account.class]) [identifiers addObject:((Account *)item).identifier];
    return identifiers;
}

- (void)focusSearch { [self.view.window makeFirstResponder:self.searchField]; }

- (void)searchChanged:(id)sender { [self reloadAccounts]; }

- (void)openClickedRow:(id)sender {
    Account *account = [self accountAtRow:self.tableView.clickedRow];
    if (account) [self.coordinator openAccountID:account.identifier];
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)self.rows.count; }

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
    return [self.rows[row] isKindOfClass:NSString.class];
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return [self tableView:tableView isGroupRow:row] ? 26 : 46;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return ![self tableView:tableView isGroupRow:row];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    id item = self.rows[row];
    if ([item isKindOfClass:NSString.class]) {
        NSTableCellView *header = [tableView makeViewWithIdentifier:GroupCellIdentifier owner:self];
        if (!header) {
            header = [NSTableCellView new];
            header.identifier = GroupCellIdentifier;
            NSTextField *label = DeskLabel(@"", 11, NSFontWeightSemibold);
            label.textColor = NSColor.secondaryLabelColor;
            [header addSubview:label];
            header.textField = label;
            [NSLayoutConstraint activateConstraints:@[
                [label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:4],
                [label.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor constant:-4],
                [label.centerYAnchor constraintEqualToAnchor:header.centerYAnchor]
            ]];
        }
        NSString *group = item;
        header.textField.stringValue = group.length ? group : @"未分组";
        return header;
    }
    AccountSidebarCell *cell = [tableView makeViewWithIdentifier:AccountCellIdentifier owner:self];
    if (!cell) {
        cell = [[AccountSidebarCell alloc] initWithFrame:NSZeroRect];
        cell.identifier = AccountCellIdentifier;
    }
    Account *account = item;
    AccountStatus *status = [AccountStatus statusForAccount:account now:NSDate.date];
    [cell configureWithAccount:account status:status now:NSDate.date];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (self.applyingSelection) return;
    Account *account = [self accountAtRow:self.tableView.selectedRow];
    if (account) [self.coordinator selectAccountID:account.identifier];
    else [self reflectSelection];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    Account *account = [self accountAtRow:self.tableView.clickedRow];
    [self.coordinator populateMenu:menu forAccountIDs:account ? @[account.identifier] : @[]];
}

#pragma mark - Drag to reorder / regroup

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row {
    Account *account = [self accountAtRow:row];
    if (!account || self.isFiltering) return nil;
    NSPasteboardItem *item = [NSPasteboardItem new];
    [item setString:account.identifier forType:AccountRowPasteboardType];
    return item;
}

- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info
    proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)dropOperation {
    if (info.draggingSource != tableView) return NSDragOperationNone;
    if (row == 0 && self.rows.count && [self.rows[0] isKindOfClass:NSString.class]) row = 1;
    [tableView setDropRow:row dropOperation:NSTableViewDropAbove];
    return NSDragOperationMove;
}

- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)dropOperation {
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (NSPasteboardItem *item in info.draggingPasteboard.pasteboardItems) {
        NSString *identifier = [item stringForType:AccountRowPasteboardType];
        if (identifier) [identifiers addObject:identifier];
    }
    if (!identifiers.count) return NO;

    // The section the drop lands in decides the group; the neighbouring account decides the position.
    NSInteger previous = MAX(row - 1, 0);
    id sectionItem = previous < (NSInteger)self.rows.count ? self.rows[previous] : nil;
    NSString *group = [sectionItem isKindOfClass:NSString.class] ? sectionItem : (((Account *)sectionItem).group ?: @"");
    Account *before = [self accountAtRow:row];
    if (![before.group isEqualToString:group]) before = nil;
    Account *after = before ? nil : [self accountAtRow:row - 1];

    AccountStore *store = self.coordinator.store;
    NSArray<Account *> *accounts = store.accounts;
    NSUInteger index = before ? [accounts indexOfObject:before] : (after ? [accounts indexOfObject:after] + 1 : accounts.count);
    for (Account *account in [store accountsWithIDs:identifiers]) account.group = group;
    [store moveAccountsWithIDs:identifiers toIndex:index];
    [store commit];
    return YES;
}
@end
