/// ZeeChat for Flutter.
///
/// A thin wrapper over the native Zellio chat SDKs. The native SDKs draw every screen
/// and hold all chat logic. This library only forwards calls and events.
library;

export 'src/models.dart';
export 'src/zellio_chat.dart' show ZellioChat, ZellioTokenProvider;
