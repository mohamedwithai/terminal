/// Native builds are not subject to the browser's secure-context rule, so
/// the platform keystore is always reachable.
///
/// The web build imports `secure_context_web.dart` instead.
bool isSecureContext() => true;
