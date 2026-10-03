#import "BackupPasswordPrompt.h"
#import "BackupCrypto.h"
#import "BackupManager.h"

static NSUInteger const MinimumPasswordLength = 8;

static NSSecureTextField *PasswordField(NSString *placeholder) {
    NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    field.placeholderString = placeholder;
    return field;
}

static void AskPassword(NSData *data, NSString *name, NSWindow *window, NSString *problem, void (^completion)(NSData *)) {
    NSSecureTextField *field = PasswordField(@"备份密码");
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"“%@”已加密", name];
    alert.informativeText = problem ?: @"输入加密这份备份时设置的密码。";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"解密"];
    [alert addButtonWithTitle:@"取消"];
    [alert layout];
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) { completion(nil); return; }
        NSError *error = nil;
        NSData *plain = BackupDecrypt(data, field.stringValue, &error);
        if (plain) { completion(plain); return; }
        // Let this sheet close before the next one opens.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error.code == BackupCryptoErrorUnreadable) {
                NSAlert *failure = [NSAlert new];
                failure.messageText = @"无法打开这份备份";
                failure.informativeText = error.localizedDescription;
                [failure beginSheetModalForWindow:window completionHandler:^(NSModalResponse ignored) { completion(nil); }];
                return;
            }
            AskPassword(data, name, window, @"密码不正确，或备份文件已被修改。请重新输入。", completion);
        });
    }];
}

void BackupOpenData(NSData *data, NSString *name, NSWindow *window, void (^completion)(NSData *)) {
    if (!BackupDataIsEncrypted(data)) { completion(data); return; }
    NSString *saved = BackupEncryptionPassword();
    NSData *plain = saved.length ? BackupDecrypt(data, saved, nil) : nil;
    if (plain) { completion(plain); return; }
    AskPassword(data, name, window, nil, completion);
}

void BackupAskNewPassword(NSWindow *window, NSString *title, void (^completion)(NSString *)) {
    NSSecureTextField *password = PasswordField([NSString stringWithFormat:@"至少 %lu 位", (unsigned long)MinimumPasswordLength]);
    NSSecureTextField *repeat = PasswordField(@"再输入一次");
    NSStackView *fields = [NSStackView stackViewWithViews:@[password, repeat]];
    fields.orientation = NSUserInterfaceLayoutOrientationVertical;
    fields.spacing = 8;
    fields.frame = NSMakeRect(0, 0, 280, 56);
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = @"密码保存在本机的钥匙串中，自动备份时使用；在其他电脑上恢复时需要输入它。"
        "忘记密码将无法恢复加密的备份，请另外妥善保存。";
    alert.accessoryView = fields;
    [alert addButtonWithTitle:@"设置密码"];
    [alert addButtonWithTitle:@"取消"];
    [alert layout];
    alert.window.initialFirstResponder = password;
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) { completion(nil); return; }
        NSString *problem = nil;
        if (password.stringValue.length < MinimumPasswordLength)
            problem = [NSString stringWithFormat:@"密码至少需要 %lu 位。", (unsigned long)MinimumPasswordLength];
        else if (![password.stringValue isEqualToString:repeat.stringValue]) problem = @"两次输入的密码不一致。";
        if (!problem) { completion(password.stringValue); return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *retry = [NSAlert new];
            retry.messageText = problem;
            [retry addButtonWithTitle:@"重新输入"];
            [retry addButtonWithTitle:@"取消"];
            [retry beginSheetModalForWindow:window completionHandler:^(NSModalResponse again) {
                if (again != NSAlertFirstButtonReturn) { completion(nil); return; }
                dispatch_async(dispatch_get_main_queue(), ^{ BackupAskNewPassword(window, title, completion); });
            }];
        });
    }];
}
