#import "AccountCardItem.h"
#import "Account.h"
#import "DeskUI.h"

@implementation DeskQuotaRow {
    NSTextField *_title;
    DeskQuotaBar *_bar;
    NSTextField *_percent;
    NSTextField *_reset;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _title = DeskLabel(@"", 11, NSFontWeightMedium);
        _title.textColor = NSColor.secondaryLabelColor;
        _bar = [DeskQuotaBar new];
        _percent = DeskLabel(@"", 11.5, NSFontWeightSemibold);
        _percent.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightSemibold];
        _percent.alignment = NSTextAlignmentRight;
        _reset = DeskLabel(@"", 10.5, NSFontWeightRegular);
        _reset.textColor = NSColor.tertiaryLabelColor;
        [_reset setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_reset setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        for (NSView *view in @[_title, _bar, _percent, _reset]) [self addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:16],
            [_title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_title.widthAnchor constraintEqualToConstant:42],
            [_title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_bar.leadingAnchor constraintEqualToAnchor:_title.trailingAnchor constant:4],
            [_bar.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_bar.heightAnchor constraintEqualToConstant:6],
            [_bar.widthAnchor constraintGreaterThanOrEqualToConstant:50],
            [_percent.leadingAnchor constraintEqualToAnchor:_bar.trailingAnchor constant:6],
            [_percent.widthAnchor constraintEqualToConstant:36],
            [_percent.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_reset.leadingAnchor constraintEqualToAnchor:_percent.trailingAnchor constant:6],
            [_reset.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_reset.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
    }
    return self;
}

- (void)showWindow:(AccountUsageWindow *)window title:(NSString *)title {
    _title.stringValue = window.title ?: title;
    _bar.remainingPercent = window ? @(window.remainingPercent) : nil;
    _percent.stringValue = window ? [NSString stringWithFormat:@"%.0f%%", window.remainingPercent] : @"—";
    _percent.textColor = window ? DeskColorForQuota(window.remainingPercent) : NSColor.tertiaryLabelColor;
    _reset.stringValue = DeskResetDescription(window.resetAt);
    self.toolTip = window ? [NSString stringWithFormat:@"%@额度剩余 %.0f%%%@", _title.stringValue, window.remainingPercent,
        window.resetAt ? [@"，" stringByAppendingString:DeskResetDescription(window.resetAt)] : @""] : nil;
}
@end

@interface AccountCardView : NSView
@property (nonatomic, weak) AccountCardItem *item;
@property (nonatomic) BOOL selected;
@end

@interface AccountCardItem ()
@property (nonatomic, copy) NSString *accountID;
@property (nonatomic, strong) DeskAvatarView *avatar;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *detailLabel;
@property (nonatomic, strong) DeskPillView *planPill;
@property (nonatomic, strong) DeskTagsView *tagsView;
@property (nonatomic, strong) DeskPillView *statusBadge;
@property (nonatomic, strong) DeskQuotaRow *shortRow;
@property (nonatomic, strong) DeskQuotaRow *longRow;
@property (nonatomic, strong) NSTextField *usageNote;
@property (nonatomic, strong) NSTextField *renewalLabel;
@property (nonatomic, strong) NSTextField *priceLabel;
@property (nonatomic, strong) NSButton *refreshButton;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSTextField *updatedLabel;
@end

@implementation AccountCardView
- (void)setSelected:(BOOL)selected { _selected = selected; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirtyRect {
    NSRect frame = NSInsetRect(self.bounds, 1, 1);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:frame xRadius:12 yRadius:12];
    [NSColor.controlBackgroundColor setFill];
    [path fill];
    if (self.selected) {
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.07] setFill];
        [path fill];
    }
    path.lineWidth = self.selected ? 2 : 1;
    [(self.selected ? NSColor.controlAccentColor : NSColor.separatorColor) setStroke];
    [path stroke];
}
- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2 && self.item.accountID) {
        [self.item.coordinator openAccountID:self.item.accountID];
        return;
    }
    [super mouseDown:event];
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
    AccountCardItem *item = self.item;
    if (!item.accountID) return nil;
    NSMenu *menu = [NSMenu new];
    NSArray *identifiers = item.menuAccountIDs ? item.menuAccountIDs(item.accountID) : @[item.accountID];
    [item.coordinator populateMenu:menu forAccountIDs:identifiers];
    return menu;
}
@end

@implementation AccountCardItem

- (void)loadView {
    AccountCardView *card = [AccountCardView new];
    card.item = self;
    self.view = card;

    self.avatar = [DeskAvatarView new];
    self.avatar.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel = DeskLabel(@"", 14, NSFontWeightSemibold);
    self.detailLabel = DeskLabel(@"", 11, NSFontWeightRegular);
    self.detailLabel.textColor = NSColor.secondaryLabelColor;
    for (NSTextField *label in @[self.nameLabel, self.detailLabel])
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.planPill = [DeskPillView new];
    NSButton *more = DeskIconButton(@"ellipsis.circle", @"更多操作", self, @selector(showMore:));
    self.tagsView = [DeskTagsView new];
    self.statusBadge = [DeskPillView new];
    self.shortRow = [DeskQuotaRow new];
    self.longRow = [DeskQuotaRow new];
    self.usageNote = DeskLabel(@"", 11, NSFontWeightRegular);
    self.usageNote.textColor = NSColor.tertiaryLabelColor;
    NSBox *separator = DeskSeparator();
    self.renewalLabel = DeskLabel(@"", 11.5, NSFontWeightMedium);
    [self.renewalLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.priceLabel = DeskLabel(@"", 11.5, NSFontWeightSemibold);
    self.priceLabel.alignment = NSTextAlignmentRight;
    [self.priceLabel setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSButton *open = DeskButton(@"打开", @"globe", self, @selector(openAccount:));
    NSButton *authorize = DeskButton(@"授权", @"person.badge.key", self, @selector(authorize:));
    authorize.toolTip = @"用此账号打开客户端授权链接";
    self.refreshButton = DeskButton(@"刷新", @"arrow.clockwise", self, @selector(refresh:));
    self.refreshButton.toolTip = @"刷新用量与订阅";
    for (NSButton *button in @[open, authorize, self.refreshButton]) button.controlSize = NSControlSizeSmall;
    self.spinner = [NSProgressIndicator new];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.updatedLabel = DeskLabel(@"", 10.5, NSFontWeightRegular);
    self.updatedLabel.textColor = NSColor.tertiaryLabelColor;
    self.updatedLabel.alignment = NSTextAlignmentRight;
    [self.updatedLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    for (NSView *view in @[self.avatar, self.nameLabel, self.detailLabel, self.planPill, more, self.tagsView, self.statusBadge, self.shortRow,
                           self.longRow, self.usageNote, separator, self.renewalLabel, self.priceLabel, open, authorize,
                           self.refreshButton, self.spinner, self.updatedLabel]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:view];
    }
    CGFloat inset = 14;
    [NSLayoutConstraint activateConstraints:@[
        [self.avatar.topAnchor constraintEqualToAnchor:card.topAnchor constant:inset],
        [self.avatar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:inset],
        [self.avatar.widthAnchor constraintEqualToConstant:34],
        [self.avatar.heightAnchor constraintEqualToConstant:34],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.avatar.trailingAnchor constant:10],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.avatar.topAnchor constant:-1],
        [self.nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.planPill.leadingAnchor constant:-6],
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.detailLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:2],
        [self.detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:more.leadingAnchor constant:-4],
        [more.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],
        [more.centerYAnchor constraintEqualToAnchor:self.nameLabel.centerYAnchor],
        [self.planPill.trailingAnchor constraintEqualToAnchor:more.leadingAnchor constant:-2],
        [self.planPill.centerYAnchor constraintEqualToAnchor:self.nameLabel.centerYAnchor],

        [self.tagsView.topAnchor constraintEqualToAnchor:self.avatar.bottomAnchor constant:10],
        [self.tagsView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:inset],
        [self.tagsView.trailingAnchor constraintLessThanOrEqualToAnchor:self.statusBadge.leadingAnchor constant:-8],
        [self.tagsView.heightAnchor constraintEqualToConstant:17],
        [self.statusBadge.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-inset],
        [self.statusBadge.centerYAnchor constraintEqualToAnchor:self.tagsView.centerYAnchor],

        [self.shortRow.topAnchor constraintEqualToAnchor:self.tagsView.bottomAnchor constant:12],
        [self.shortRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:inset],
        [self.shortRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-inset],
        [self.longRow.topAnchor constraintEqualToAnchor:self.shortRow.bottomAnchor constant:8],
        [self.longRow.leadingAnchor constraintEqualToAnchor:self.shortRow.leadingAnchor],
        [self.longRow.trailingAnchor constraintEqualToAnchor:self.shortRow.trailingAnchor],
        [self.usageNote.leadingAnchor constraintEqualToAnchor:self.shortRow.leadingAnchor],
        [self.usageNote.trailingAnchor constraintLessThanOrEqualToAnchor:self.shortRow.trailingAnchor],
        [self.usageNote.centerYAnchor constraintEqualToAnchor:self.shortRow.bottomAnchor constant:4],

        [separator.topAnchor constraintEqualToAnchor:self.longRow.bottomAnchor constant:12],
        [separator.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:inset],
        [separator.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-inset],
        [self.renewalLabel.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:9],
        [self.renewalLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:inset],
        [self.renewalLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.priceLabel.leadingAnchor constant:-8],
        [self.priceLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-inset],
        [self.priceLabel.centerYAnchor constraintEqualToAnchor:self.renewalLabel.centerYAnchor],

        [open.topAnchor constraintEqualToAnchor:self.renewalLabel.bottomAnchor constant:10],
        [open.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:inset - 2],
        [authorize.leadingAnchor constraintEqualToAnchor:open.trailingAnchor constant:6],
        [authorize.centerYAnchor constraintEqualToAnchor:open.centerYAnchor],
        [self.refreshButton.leadingAnchor constraintEqualToAnchor:authorize.trailingAnchor constant:6],
        [self.refreshButton.centerYAnchor constraintEqualToAnchor:open.centerYAnchor],
        [self.spinner.leadingAnchor constraintEqualToAnchor:self.refreshButton.trailingAnchor constant:6],
        [self.spinner.centerYAnchor constraintEqualToAnchor:open.centerYAnchor],
        [self.updatedLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.spinner.trailingAnchor constant:6],
        [self.updatedLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-inset],
        [self.updatedLabel.centerYAnchor constraintEqualToAnchor:open.centerYAnchor]
    ]];
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    ((AccountCardView *)self.view).selected = selected;
}

- (void)configureWithAccount:(Account *)account status:(AccountStatus *)status busy:(BOOL)refreshing now:(NSDate *)now {
    (void)self.view;
    self.accountID = account.identifier;
    self.avatar.name = account.name;
    self.avatar.seed = account.identifier;
    self.avatar.statusColor = account.signedIn.boolValue ? NSColor.systemGreenColor : nil;
    self.nameLabel.stringValue = account.name;
    self.nameLabel.toolTip = account.name;
    NSMutableArray *detail = [NSMutableArray array];
    if (account.email.length) [detail addObject:account.email];
    if (account.group.length) [detail addObject:account.group];
    self.detailLabel.stringValue = detail.count ? [detail componentsJoinedByString:@" · "] : @"未填写邮箱";
    [self.statusBadge showStatus:status showsNormal:NO];
    self.planPill.text = account.plan ?: @"未获取";
    self.planPill.tintColor = DeskColorForPlan(account.planFamily);
    self.tagsView.tags = account.tags;

    AccountUsage *usage = account.usage;
    BOOL hasUsage = usage.windows.count > 0;
    self.shortRow.hidden = !hasUsage;
    self.longRow.hidden = !hasUsage;
    self.usageNote.hidden = hasUsage;
    if (hasUsage) {
        [self.shortRow showWindow:usage.shortWindow ?: usage.windows.firstObject title:@"5 小时"];
        [self.longRow showWindow:usage.longWindow title:@"每周"];
    }
    if (account.refreshError.length) {
        self.usageNote.stringValue = account.refreshError;
        self.usageNote.textColor = NSColor.systemOrangeColor;
        self.usageNote.hidden = NO;
        self.shortRow.hidden = YES;
        self.longRow.hidden = YES;
    } else {
        self.usageNote.stringValue = refreshing ? @"正在读取用量…" : @"尚未读取用量，点击“刷新”获取";
        self.usageNote.textColor = NSColor.tertiaryLabelColor;
    }

    AccountExpiryState state = [account expiryStateFromDate:now];
    if (state == AccountExpiryStateUnknown) {
        self.renewalLabel.stringValue = account.isPaid ? @"未设置续费日期" : @"免费账号";
        self.renewalLabel.textColor = NSColor.tertiaryLabelColor;
    } else {
        self.renewalLabel.stringValue = [NSString stringWithFormat:@"%@ · %@", account.renewalDescription,
            [account expiryDescriptionFromDate:now]];
        self.renewalLabel.textColor = state == AccountExpiryStateActive || state == AccountExpiryStateRenewing
            ? NSColor.secondaryLabelColor : DeskColorForExpiry(state);
    }
    self.priceLabel.stringValue = account.monthlyPrice ? [AccountFormatMoney(account.monthlyPrice, account.currency) stringByAppendingString:@"/月"] : @"";

    self.refreshButton.enabled = !refreshing;
    if (refreshing) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
    self.updatedLabel.stringValue = usage ? [@"更新于" stringByAppendingString:DeskRelativeTime(usage.fetchedAt)] : @"";
}

- (void)openAccount:(id)sender { if (self.accountID) [self.coordinator openAccountID:self.accountID]; }
- (void)authorize:(id)sender { if (self.accountID) [self.coordinator promptAuthorizationForAccountID:self.accountID]; }
- (void)refresh:(id)sender { if (self.accountID) [self.coordinator refreshUsageForAccountIDs:@[self.accountID]]; }

- (void)showMore:(NSButton *)sender {
    if (!self.accountID) return;
    NSMenu *menu = [NSMenu new];
    NSArray *identifiers = self.menuAccountIDs ? self.menuAccountIDs(self.accountID) : @[self.accountID];
    [self.coordinator populateMenu:menu forAccountIDs:identifiers];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4) inView:sender];
}
@end
