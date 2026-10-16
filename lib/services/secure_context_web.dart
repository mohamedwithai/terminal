import 'dart:js_interop';

@JS('isSecureContext')
external bool get _windowIsSecureContext;

/// Browsers expose WebCrypto, which secure storage needs, only to secure
/// contexts: HTTPS pages and `localhost`.
bool isSecureContext() => _windowIsSecureContext;
