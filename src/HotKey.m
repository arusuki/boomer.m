#import "HotKey.h"

@interface BMHotKey ()
- (OSStatus)handleEvent:(EventRef)event;
@end

static OSStatus BMHandleHotKey(EventHandlerCallRef next, EventRef event, void *context) {
    (void)next;
    return [(__bridge BMHotKey *)context handleEvent:event];
}

@implementation BMHotKey {
    UInt32 _keyCode, _modifiers;
    EventHotKeyID _identifier;
    EventHotKeyRef _hotKey;
    EventHandlerRef _eventHandler;
    dispatch_block_t _handler;
    BOOL _pressed;
}

- (instancetype)initWithKeyCode:(UInt32)keyCode
                      modifiers:(UInt32)modifiers
                        handler:(dispatch_block_t)handler {
    self = [super init];
    if (!self)
        return nil;
    static UInt32 nextID;
    _identifier = (EventHotKeyID){0x426D7248, ++nextID}; // BmrH
    _keyCode = keyCode;
    _modifiers = modifiers;
    _handler = [handler copy];
    return self;
}

- (BOOL)isRegistered {
    return _hotKey != NULL;
}

- (UInt32)keyCode {
    return _keyCode;
}

- (UInt32)modifiers {
    return _modifiers;
}

- (BMHotKey *)replacementWithKeyCode:(UInt32)keyCode
                           modifiers:(UInt32)modifiers
                               error:(NSError **)error {
    if (keyCode == _keyCode && modifiers == _modifiers)
        return [self registerWithError:error] ? self : nil;
    BMHotKey *next = [[BMHotKey alloc] initWithKeyCode:keyCode
                                             modifiers:modifiers
                                               handler:_handler];
    if (![next registerWithError:error])
        return nil;
    [self unregister];
    return next;
}

- (BOOL)registerWithError:(NSError **)error {
    if (_hotKey)
        return YES;
    EventTypeSpec events[] = {{kEventClassKeyboard, kEventHotKeyPressed},
                              {kEventClassKeyboard, kEventHotKeyReleased}};
    OSStatus status = InstallEventHandler(GetApplicationEventTarget(), BMHandleHotKey, 2, events,
                                          (__bridge void *)self, &_eventHandler);
    if (status == noErr)
        status = RegisterEventHotKey(_keyCode, _modifiers, _identifier, GetApplicationEventTarget(),
                                     kEventHotKeyExclusive, &_hotKey);
    if (status == noErr)
        return YES;
    [self unregister];
    if (error)
        *error = [NSError
            errorWithDomain:NSOSStatusErrorDomain
                       code:status
                   userInfo:@{
                       NSLocalizedDescriptionKey :
                           @"Could not register the global shortcut. Remove its old Shortcuts or "
                           @"launcher binding, then retry from the Boomer menu."
                   }];
    return NO;
}

- (OSStatus)handleEvent:(EventRef)event {
    EventHotKeyID identifier;
    if (!_hotKey ||
        GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof identifier, NULL, &identifier) != noErr ||
        identifier.signature != _identifier.signature || identifier.id != _identifier.id)
        return eventNotHandledErr;
    if (GetEventKind(event) == kEventHotKeyReleased)
        _pressed = NO;
    else if (GetEventKind(event) == kEventHotKeyPressed && !_pressed) {
        _pressed = YES;
        if (_handler)
            _handler();
    }
    return noErr;
}

- (void)unregister {
    if (_hotKey) {
        UnregisterEventHotKey(_hotKey);
        _hotKey = NULL;
    }
    if (_eventHandler) {
        RemoveEventHandler(_eventHandler);
        _eventHandler = NULL;
    }
    _pressed = NO;
}

- (void)dealloc {
    [self unregister];
}

@end
