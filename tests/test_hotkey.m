#import <Cocoa/Cocoa.h>
#import "../src/HotKey.m"
#import "ShortcutSettings.h"

@implementation BMHotKey (TestEvents)

- (EventHotKeyID)testIdentifier {
    return _identifier;
}

@end

static BOOL Send(BMHotKey *key, UInt32 kind) {
    EventRef event = NULL;
    EventHotKeyID identifier = [key testIdentifier];
    if (CreateEvent(NULL, kEventClassKeyboard, kind, GetCurrentEventTime(), 0, &event) != noErr)
        return NO;
    OSStatus status = SetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                        sizeof identifier, &identifier);
    if (status == noErr)
        status = SendEventToEventTarget(event, GetApplicationEventTarget());
    ReleaseEvent(event);
    return status == noErr;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        __block NSUInteger calls = 0;
        // Avoid the user's real Cmd+Shift+2 binding during automated tests.
        BMHotKey *key = [[BMHotKey alloc] initWithKeyCode:kVK_F19
                                                modifiers:cmdKey | controlKey | optionKey
                                                  handler:^{
                                                      ++calls;
                                                  }];
        NSError *error = nil;
        if (![key registerWithError:&error]) {
            fprintf(stderr, "FAIL register test hotkey: %s\n",
                    error.localizedDescription.UTF8String);
            return 1;
        }
        BOOL dispatched = Send(key, kEventHotKeyPressed) && Send(key, kEventHotKeyPressed) &&
                          calls == 1 && Send(key, kEventHotKeyReleased) &&
                          Send(key, kEventHotKeyPressed) && calls == 2;
        BMHotKey *other = [[BMHotKey alloc] initWithKeyCode:kVK_F19
                                                  modifiers:cmdKey | controlKey | optionKey
                                                    handler:^{
                                                    }];
        BOOL conflict = ![other registerWithError:&error] && !other.registered;
        [key unregister];
        BOOL released = !key.registered && [other registerWithError:&error];
        // An event for the removed handler must not trigger the replacement.
        Send(key, kEventHotKeyReleased);
        Send(key, kEventHotKeyPressed);
        BOOL isolated = calls == 2;
        // Replacement failure preserves the old registration, success releases it.
        [key registerWithError:&error]; // Occupied by other, so still unregistered.
        BMHotKey *blocking = [[BMHotKey alloc] initWithKeyCode:kVK_F18
                                                     modifiers:cmdKey | controlKey | optionKey
                                                       handler:^{
                                                       }];
        BOOL blocked = [blocking registerWithError:&error];
        BMHotKey *failed = [other replacementWithKeyCode:kVK_F18
                                               modifiers:cmdKey | controlKey | optionKey
                                                   error:&error];
        BOOL preserved = !failed && other.registered;
        [blocking unregister];
        BMHotKey *replacement = [other replacementWithKeyCode:kVK_F18
                                                    modifiers:cmdKey | controlKey | optionKey
                                                        error:&error];
        BOOL replaced =
            replacement.registered && !other.registered && [key registerWithError:&error];
        BOOL unchanged = [replacement replacementWithKeyCode:kVK_F18
                                                   modifiers:cmdKey | controlKey | optionKey
                                                       error:&error] == replacement;
        BOOL valid = BMShortcutIsValid(kVK_ANSI_A, cmdKey) &&
                     !BMShortcutIsValid(kVK_ANSI_A, shiftKey) &&
                     !BMShortcutIsValid(kVK_ANSI_Q, cmdKey) && !BMShortcutIsValid(65535, cmdKey) &&
                     [BMShortcutLabel(kVK_ANSI_2, cmdKey | shiftKey) isEqualToString:@"⇧⌘2"];
        [replacement unregister];
        [key unregister];
        [other unregister];
        BOOL passed = dispatched && conflict && released && isolated && blocked && preserved &&
                      replaced && unchanged && valid;
        fprintf(stderr,
                "%s global hotkey: dispatch, repeat suppression, conflict, unregister/retry, event "
                "identity\n",
                passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
