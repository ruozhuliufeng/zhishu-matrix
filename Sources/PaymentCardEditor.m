#import "PaymentCardEditor.h"
#import "Account.h"
#import "DeskUI.h"

void PaymentCardEdit(NSWindow *window, AccountStore *store, NSString *last4) {
    if (last4.length != 4 || !window) return;
    PaymentCard *card = [store cardWithLast4:last4] ?: [PaymentCard cardWithLast4:last4];
    NSMutableArray<NSString *> *users = [NSMutableArray array];
    for (Account *account in store.visibleAccounts)
        if ([account.cardLast4 isEqualToString:last4]) [users addObject:account.name];

    NSTextField *name = [NSTextField new];
    name.stringValue = card.name;
    name.placeholderString = @"例如：招行信用卡、工资卡";
    [name.widthAnchor constraintEqualToConstant:240].active = YES;
    NSButton *hasExpiry = [NSButton checkboxWithTitle:@"有效期至" target:nil action:nil];
    hasExpiry.state = card.expiry ? NSControlStateValueOn : NSControlStateValueOff;
    NSDatePicker *expiry = [NSDatePicker new];
    expiry.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    expiry.datePickerElements = NSDatePickerElementFlagYearMonth;
    NSDate *month = card.expiry ? AccountDateFromDayString([card.expiry stringByAppendingString:@"-01"]) : nil;
    expiry.dateValue = month ?: [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitYear value:3 toDate:NSDate.date options:0];
    NSTextField *hint = DeskLabel(@"卡面上的 MM/YY", 11, NSFontWeightRegular);
    hint.textColor = NSColor.tertiaryLabelColor;
    NSStackView *expiryRow = [NSStackView stackViewWithViews:@[hasExpiry, expiry, hint]];
    expiryRow.spacing = 8;
    NSTextField *note = [NSTextField new];
    note.stringValue = card.note;
    note.placeholderString = @"可选";
    [note.widthAnchor constraintEqualToConstant:240].active = YES;
    NSString *usage = users.count ? [NSString stringWithFormat:@"%lu 个账号：%@", (unsigned long)users.count,
        [users componentsJoinedByString:@"、"]] : @"暂时没有账号使用";
    NSTextField *usedBy = [NSTextField wrappingLabelWithString:usage];
    usedBy.font = [NSFont systemFontOfSize:12];
    usedBy.textColor = NSColor.secondaryLabelColor;
    usedBy.preferredMaxLayoutWidth = 300;
    usedBy.maximumNumberOfLines = 4;

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[DeskLabel(@"名称", 13, NSFontWeightRegular), name],
        @[DeskLabel(@"有效期", 13, NSFontWeightRegular), expiryRow],
        @[DeskLabel(@"备注", 13, NSFontWeightRegular), note],
        @[DeskLabel(@"绑定", 13, NSFontWeightRegular), usedBy]]];
    grid.rowSpacing = 10;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid rowAtIndex:3].yPlacement = NSGridCellPlacementTop;
    grid.frame = NSMakeRect(0, 0, 380, grid.fittingSize.height);

    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"付款卡 · 尾号 %@", last4];
    alert.informativeText = @"只记录卡号后 4 位和你填写的名称、有效期；有效期前 30 天和到期后会提醒换卡。";
    alert.accessoryView = grid;
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];
    [alert layout];
    alert.window.initialFirstResponder = name;
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        PaymentCard *updated = [PaymentCard cardWithLast4:last4];
        updated.name = name.stringValue;
        updated.note = note.stringValue;
        if (hasExpiry.state == NSControlStateValueOn) {
            NSDateComponents *parts = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:expiry.dateValue];
            updated.expiry = [NSString stringWithFormat:@"%04ld-%02ld", (long)parts.year, (long)parts.month];
        }
        [store saveCard:updated];
        [store commit];
    }];
}
