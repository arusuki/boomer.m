#import "ShortcutSettings.h"

NSArray<NSDictionary *> *BMShortcutKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const UInt32 codes[] = {
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
            kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D,
            kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K,
            kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
            kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
            kVK_ANSI_Z, kVK_F1,     kVK_F2,     kVK_F3,     kVK_F4,     kVK_F5,     kVK_F6,
            kVK_F7,     kVK_F8,     kVK_F9,     kVK_F10,    kVK_F11,    kVK_F12,    kVK_F13,
            kVK_F14,    kVK_F15,    kVK_F16,    kVK_F17,    kVK_F18,    kVK_F19,    kVK_F20};
        NSMutableArray *result = [NSMutableArray array];
        for (NSUInteger i = 0; i < sizeof codes / sizeof *codes; ++i) {
            NSString *name = i < 10   ? [NSString stringWithFormat:@"%lu", (unsigned long)i]
                             : i < 36 ? [NSString stringWithFormat:@"%c", (int)('A' + i - 10)]
                                      : [NSString
                                            stringWithFormat:@"F%lu", (unsigned long)(i - 35)];
            [result addObject:@{@"name" : name, @"code" : @(codes[i])}];
        }
        NSArray *names = @[
            @"Space", @"Tab", @"Return", @"Escape", @"←",
            @"→",     @"↑",   @"↓",      @"Delete", @"Forward Delete",
            @"-",     @"=",   @"[",      @"]",      @";",
            @"'",     @",",   @".",      @"/",      @"\\",
            @"`"
        ];
        const UInt32 extra[] = {kVK_Space,
                                kVK_Tab,
                                kVK_Return,
                                kVK_Escape,
                                kVK_LeftArrow,
                                kVK_RightArrow,
                                kVK_UpArrow,
                                kVK_DownArrow,
                                kVK_Delete,
                                kVK_ForwardDelete,
                                kVK_ANSI_Minus,
                                kVK_ANSI_Equal,
                                kVK_ANSI_LeftBracket,
                                kVK_ANSI_RightBracket,
                                kVK_ANSI_Semicolon,
                                kVK_ANSI_Quote,
                                kVK_ANSI_Comma,
                                kVK_ANSI_Period,
                                kVK_ANSI_Slash,
                                kVK_ANSI_Backslash,
                                kVK_ANSI_Grave};
        for (NSUInteger i = 0; i < names.count; ++i)
            [result addObject:@{@"name" : names[i], @"code" : @(extra[i])}];
        keys = [result copy];
    });
    return keys;
}

@implementation BMShortcutRecorder {
    id _monitor;
    BOOL _recording;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.bezelStyle = NSBezelStyleRounded;
    self.target = self;
    self.action = @selector(record:);
    self.accessibilityLabel = @"Record shortcut";
    self.font = [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
    return self;
}
- (void)refreshTitle {
    self.title =
        [NSString stringWithFormat:@"%@  — Click to record",
                                   BMShortcutLabel(self.recordedKeyCode, self.recordedModifiers)];
}
- (void)record:(id)sender {
    (void)sender;
    [self stopRecording];
    _recording = YES;
    self.title = @"Press your shortcut…";
    __weak BMShortcutRecorder *weakSelf = self;
    _monitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent *(NSEvent *event) {
                                         BMShortcutRecorder *recorder = weakSelf;
                                         if (!recorder || !recorder->_recording ||
                                             !recorder.window.keyWindow)
                                             return event;
                                         NSEventModifierFlags flags = event.modifierFlags;
                                         UInt32 modifiers = 0;
                                         if (flags & NSEventModifierFlagCommand)
                                             modifiers |= cmdKey;
                                         if (flags & NSEventModifierFlagControl)
                                             modifiers |= controlKey;
                                         if (flags & NSEventModifierFlagOption)
                                             modifiers |= optionKey;
                                         if (flags & NSEventModifierFlagShift)
                                             modifiers |= shiftKey;
                                         if (event.keyCode == kVK_Escape && !modifiers) {
                                             [recorder stopRecording];
                                             return nil;
                                         }
                                         if (!BMShortcutIsValid(event.keyCode, modifiers)) {
                                             recorder.title = @"Include ⌘ or ⌃; ⌘Q is reserved";
                                             return nil;
                                         }
                                         recorder.recordedKeyCode = event.keyCode;
                                         recorder.recordedModifiers = modifiers;
                                         [recorder stopRecording];
                                         return nil;
                                     }];
}
- (void)stopRecording {
    _recording = NO;
    if (_monitor) {
        [NSEvent removeMonitor:_monitor];
        _monitor = nil;
    }
    [self refreshTitle];
}
- (void)dealloc {
    if (_monitor)
        [NSEvent removeMonitor:_monitor];
}
@end
BOOL BMShortcutIsValid(UInt32 keyCode, UInt32 modifiers) {
    if (!(modifiers & (cmdKey | controlKey)) ||
        (modifiers & ~(cmdKey | controlKey | optionKey | shiftKey)))
        return NO;
    if (keyCode == kVK_ANSI_Q && modifiers == cmdKey)
        return NO; // Keep Quit available.
    for (NSDictionary *key in BMShortcutKeys())
        if ([key[@"code"] unsignedIntValue] == keyCode)
            return YES;
    return NO;
}
NSString *BMShortcutLabel(UInt32 keyCode, UInt32 modifiers) {
    NSMutableString *label = [NSMutableString string];
    if (modifiers & controlKey)
        [label appendString:@"⌃"];
    if (modifiers & optionKey)
        [label appendString:@"⌥"];
    if (modifiers & shiftKey)
        [label appendString:@"⇧"];
    if (modifiers & cmdKey)
        [label appendString:@"⌘"];
    for (NSDictionary *key in BMShortcutKeys())
        if ([key[@"code"] unsignedIntValue] == keyCode) {
            [label appendString:key[@"name"]];
            break;
        }
    return label;
}
