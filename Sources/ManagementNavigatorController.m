#import "ManagementNavigatorController.h"
#import "Account.h"
#import "DeskUI.h"
#import "ManagementScope.h"

static NSString *const ScopeDefaultsKey = @"managementScope";

static NSColor *ScopeTint(ManagementScope *scope) {
    switch (scope.kind) {
        case ManagementScopeAll: return NSColor.controlAccentColor;
        case ManagementScopeQuotaLow: return NSColor.systemRedColor;
        case ManagementScopeExpiring: return NSColor.systemOrangeColor;
        case ManagementScopeSignedOut: return NSColor.systemGrayColor;
        case ManagementScopeAutoRenew: return NSColor.systemBlueColor;
        case ManagementScopeDuplicates: return NSColor.systemPurpleColor;
        case ManagementScopeGroup: return NSColor.secondaryLabelColor;
        case ManagementScopeTag: return DeskColorForTag(scope.value);
        case ManagementScopeSupplier: return scope.value.length ? NSColor.systemTealColor : NSColor.tertiaryLabelColor;
        case ManagementScopeIncomplete: return NSColor.systemBrownColor;
        case ManagementScopeAuthorizedApp: return NSColor.systemIndigoColor;
    }
    return NSColor.secondaryLabelColor;
}

@interface ManagementScopeCell : NSTableCellView
@property (nonatomic, strong) NSTextField *countLabel;
@end

@implementation ManagementScopeCell
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSImageView *icon = [NSImageView new];
        icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
        NSTextField *title = DeskLabel(@"", 13, NSFontWeightRegular);
        [title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        _countLabel = DeskLabel(@"", 11, NSFontWeightMedium);
        _countLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
        _countLabel.textColor = NSColor.secondaryLabelColor;
        _countLabel.alignment = NSTextAlignmentRight;
        for (NSView *view in @[icon, title, _countLabel]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:view];
        }
        self.imageView = icon;
        self.textField = title;
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
            [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:18],
            [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:7],
            [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [title.trailingAnchor constraintLessThanOrEqualToAnchor:_countLabel.leadingAnchor constant:-6],
            [_countLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [_countLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
    }
    return self;
}
- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    [super setBackgroundStyle:backgroundStyle];
    self.countLabel.textColor = backgroundStyle == NSBackgroundStyleEmphasized
        ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor;
}
@end

@interface ManagementNavigatorController () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
@property (nonatomic, weak) id<AccountCoordinator> coordinator;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextField *countLabel;
/// NSString section titles and ManagementScope entries.
@property (nonatomic, copy) NSArray *rows;
@property (nonatomic, copy) NSDictionary<ManagementScope *, NSNumber *> *counts;
@property (nonatomic) BOOL applyingSelection;
@end

@implementation ManagementNavigatorController

- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _coordinator = coordinator;
        _rows = @[];
        _counts = @{};
        _scope = [ManagementScope scopeFromString:[NSUserDefaults.standardUserDefaults stringForKey:ScopeDefaultsKey]] ?: ManagementScope.all;
    }
    return self;
}

- (void)loadView {
    NSView *root = [NSView new];
    self.view = root;
    self.tableView = [NSTableView new];
    self.tableView.style = NSTableViewStyleSourceList;
    self.tableView.headerView = nil;
    self.tableView.rowSizeStyle = NSTableViewRowSizeStyleCustom;
    self.tableView.floatsGroupRows = NO;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"scope"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:column];
    self.tableView.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.menu = [NSMenu new];
    self.tableView.menu.delegate = self;
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = self.tableView;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;

    NSBox *separator = DeskSeparator();
    NSButton *add = DeskIconButton(@"plus", @"添加账号", self.coordinator, @selector(addAccount:));
    NSButton *browse = DeskIconButton(@"globe", @"浏览 ChatGPT 页面", self.coordinator, @selector(showBrowser:));
    self.countLabel = DeskLabel(@"", 11, NSFontWeightRegular);
    self.countLabel.textColor = NSColor.secondaryLabelColor;
    for (NSView *view in @[scroll, separator, add, browse, self.countLabel]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:4],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:separator.topAnchor],
        [separator.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-36],
        [add.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:8],
        [add.centerYAnchor constraintEqualToAnchor:root.bottomAnchor constant:-18],
        [browse.leadingAnchor constraintEqualToAnchor:add.trailingAnchor constant:2],
        [browse.centerYAnchor constraintEqualToAnchor:add.centerYAnchor],
        [self.countLabel.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-12],
        [self.countLabel.centerYAnchor constraintEqualToAnchor:add.centerYAnchor],
        [self.countLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:browse.trailingAnchor constant:8]
    ]];
    [self reloadAccounts];
}

- (void)setScope:(ManagementScope *)scope {
    _scope = scope ?: ManagementScope.all;
    [NSUserDefaults.standardUserDefaults setObject:_scope.stringValue forKey:ScopeDefaultsKey];
    [self reflectSelection];
}

#pragma mark - Data

- (void)reloadAccounts {
    if (!self.isViewLoaded) return;
    AccountStore *store = self.coordinator.store;
    NSArray<Account *> *accounts = store.accounts;
    NSDate *now = NSDate.date;
    NSSet *duplicates = AccountDuplicateIDs(accounts);
    NSMutableArray *rows = [NSMutableArray arrayWithObject:@"智能列表"];
    for (ManagementScope *scope in ManagementScope.smartScopes)
        if (scope.kind != ManagementScopeDuplicates || duplicates.count) [rows addObject:scope];
    NSArray<NSString *> *groups = store.groups;
    if (groups.count) {
        [rows addObject:@"分组"];
        for (NSString *group in groups) [rows addObject:[ManagementScope scopeWithKind:ManagementScopeGroup value:group]];
        BOOL ungrouped = NO;
        for (Account *account in accounts) if (!account.group.length) ungrouped = YES;
        if (ungrouped) [rows addObject:[ManagementScope scopeWithKind:ManagementScopeGroup value:@""]];
    }
    NSMutableArray<NSString *> *suppliers = [NSMutableArray array];
    BOOL unsupplied = NO;
    for (NSString *supplier in store.suppliers)
        for (Account *account in accounts)
            if ([account.supplier isEqualToString:supplier]) { [suppliers addObject:supplier]; break; }
    for (Account *account in accounts) if (!account.supplier.length) unsupplied = YES;
    if (suppliers.count) {
        [rows addObject:@"供应商"];
        for (NSString *supplier in suppliers) [rows addObject:[ManagementScope scopeWithKind:ManagementScopeSupplier value:supplier]];
        if (unsupplied) [rows addObject:[ManagementScope scopeWithKind:ManagementScopeSupplier value:@""]];
    }
    NSArray<NSString *> *apps = store.authorizedApps;
    if (apps.count) {
        [rows addObject:@"第三方应用"];
        for (NSString *app in apps) [rows addObject:[ManagementScope scopeWithKind:ManagementScopeAuthorizedApp value:app]];
    }
    NSArray<NSString *> *tags = store.tags;
    if (tags.count) {
        [rows addObject:@"标签"];
        for (NSString *tag in tags) [rows addObject:[ManagementScope scopeWithKind:ManagementScopeTag value:tag]];
    }
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    for (id row in rows) {
        if (![row isKindOfClass:ManagementScope.class]) continue;
        NSUInteger count = 0;
        for (Account *account in accounts) if ([row includesAccount:account now:now duplicateIDs:duplicates]) count++;
        counts[row] = @(count);
    }
    self.rows = rows;
    self.counts = counts;
    // A group or tag that no longer exists falls back to every account.
    if (![rows containsObject:self.scope]) {
        self.scope = ManagementScope.all;
        if (self.scopeChosen) self.scopeChosen(self.scope);
    }
    self.applyingSelection = YES;
    [self.tableView reloadData];
    self.applyingSelection = NO;
    [self reflectSelection];
    self.countLabel.stringValue = [NSString stringWithFormat:@"%lu 个账号", (unsigned long)accounts.count];
}

- (void)reflectSelection {
    if (!self.isViewLoaded) return;
    NSUInteger row = [self.rows indexOfObject:self.scope];
    self.applyingSelection = YES;
    if (row != NSNotFound) [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    else [self.tableView deselectAll:nil];
    self.applyingSelection = NO;
}

- (ManagementScope *)scopeAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.rows.count) return nil;
    id item = self.rows[(NSUInteger)row];
    return [item isKindOfClass:ManagementScope.class] ? item : nil;
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)self.rows.count; }
- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row { return [self.rows[(NSUInteger)row] isKindOfClass:NSString.class]; }
- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row { return [self tableView:tableView isGroupRow:row] ? 26 : 28; }
- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row { return [self scopeAtRow:row] != nil; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    id item = self.rows[(NSUInteger)row];
    if ([item isKindOfClass:NSString.class]) {
        NSTableCellView *header = [tableView makeViewWithIdentifier:@"Header" owner:self];
        if (!header) {
            header = [NSTableCellView new];
            header.identifier = @"Header";
            NSTextField *label = DeskLabel(@"", 11, NSFontWeightSemibold);
            label.textColor = NSColor.secondaryLabelColor;
            [header addSubview:label];
            header.textField = label;
            [NSLayoutConstraint activateConstraints:@[
                [label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:4],
                [label.centerYAnchor constraintEqualToAnchor:header.centerYAnchor]
            ]];
        }
        header.textField.stringValue = item;
        return header;
    }
    ManagementScope *scope = item;
    ManagementScopeCell *cell = [tableView makeViewWithIdentifier:@"Scope" owner:self];
    if (!cell) {
        cell = [[ManagementScopeCell alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"Scope";
    }
    // Source lists restyle template images, so the color is baked into the symbol.
    NSImage *symbol = [NSImage imageWithSystemSymbolName:scope.kind == ManagementScopeTag ? @"tag.fill" : scope.symbol
        accessibilityDescription:nil];
    cell.imageView.image = [symbol imageWithSymbolConfiguration:[[NSImageSymbolConfiguration configurationWithPointSize:13
        weight:NSFontWeightRegular] configurationByApplyingConfiguration:[NSImageSymbolConfiguration
        configurationWithPaletteColors:@[ScopeTint(scope)]]]];
    cell.textField.stringValue = scope.title;
    NSUInteger count = self.counts[scope].unsignedIntegerValue;
    cell.countLabel.stringValue = count || scope.kind == ManagementScopeAll ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : @"";
    BOOL alarming = count && (scope.kind == ManagementScopeQuotaLow || scope.kind == ManagementScopeExpiring ||
        scope.kind == ManagementScopeIncomplete);
    cell.textField.font = [NSFont systemFontOfSize:13 weight:alarming ? NSFontWeightSemibold : NSFontWeightRegular];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (self.applyingSelection) return;
    ManagementScope *scope = [self scopeAtRow:self.tableView.selectedRow];
    if (!scope) { [self reflectSelection]; return; }
    self.scope = scope;
    if (self.scopeChosen) self.scopeChosen(scope);
}

#pragma mark - Renaming groups and tags

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    ManagementScope *scope = [self scopeAtRow:self.tableView.clickedRow];
    if (!scope.value.length) return;
    NSString *noun = scope.kind == ManagementScopeTag ? @"标签" : (scope.kind == ManagementScopeSupplier ? @"供应商"
        : (scope.kind == ManagementScopeAuthorizedApp ? @"应用" : @"分组"));
    NSMenuItem *rename = [menu addItemWithTitle:[NSString stringWithFormat:@"重命名%@…", noun] action:@selector(renameScope:)
        keyEquivalent:@""];
    NSString *removeTitle = scope.kind == ManagementScopeTag ? @"从所有账号移除此标签"
        : (scope.kind == ManagementScopeSupplier ? @"清除这些账号的供应商"
        : (scope.kind == ManagementScopeAuthorizedApp ? @"把这些账号对它的授权标记为已撤销" : @"解散分组（账号移到未分组）"));
    NSMenuItem *remove = [menu addItemWithTitle:removeTitle action:@selector(removeScope:) keyEquivalent:@""];
    for (NSMenuItem *item in @[rename, remove]) {
        item.target = self;
        item.representedObject = scope;
    }
}

- (void)renameScope:(NSMenuItem *)sender {
    ManagementScope *scope = sender.representedObject;
    NSString *noun = scope.kind == ManagementScopeTag ? @"标签" : (scope.kind == ManagementScopeSupplier ? @"供应商"
        : (scope.kind == ManagementScopeAuthorizedApp ? @"应用" : @"分组"));
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"重命名%@“%@”", noun, scope.value];
    alert.informativeText = @"使用已有名称时会与其合并。";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    field.stringValue = scope.value;
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"重命名"];
    [alert addButtonWithTitle:@"取消"];
    [alert layout];
    alert.window.initialFirstResponder = field;
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        NSString *name = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (response != NSAlertFirstButtonReturn || !name.length || [name isEqualToString:scope.value]) return;
        [weakSelf replaceScope:scope with:name];
    }];
}

- (void)removeScope:(NSMenuItem *)sender { [self replaceScope:sender.representedObject with:nil]; }

- (void)replaceScope:(ManagementScope *)scope with:(NSString *)name {
    AccountStore *store = self.coordinator.store;
    for (Account *account in store.accounts) {
        if (scope.kind == ManagementScopeAuthorizedApp) {
            for (AccountAuthorization *authorization in account.authorizations) {
                if (![authorization.appName isEqualToString:scope.value]) continue;
                if (name) authorization.appName = name;
                else if (!authorization.revoked) authorization.revokedAt = NSDate.date;
            }
        } else if (scope.kind == ManagementScopeSupplier && [account.supplier isEqualToString:scope.value]) {
            account.supplier = name ?: @"";
        } else if (scope.kind == ManagementScopeGroup && [account.group isEqualToString:scope.value]) {
            account.group = name ?: @"";
        } else if (scope.kind == ManagementScopeTag && [account.tags containsObject:scope.value]) {
            NSMutableArray *tags = [account.tags mutableCopy];
            NSUInteger index = [tags indexOfObject:scope.value];
            if (name) [tags replaceObjectAtIndex:index withObject:name]; else [tags removeObjectAtIndex:index];
            account.tags = tags;
        }
    }
    if ([self.scope isEqual:scope]) {
        self.scope = name ? [ManagementScope scopeWithKind:scope.kind value:name] : ManagementScope.all;
        if (self.scopeChosen) self.scopeChosen(self.scope);
    }
    [store commit];
}
@end
