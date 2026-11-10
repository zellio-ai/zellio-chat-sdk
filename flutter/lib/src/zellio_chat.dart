import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'version.dart';

/// Returns the identity JWT of the signed-in customer, from the brand server.
/// Return null when nobody is signed in.
typedef ZellioTokenProvider = Future<String?> Function();

/// ZeeChat for Flutter. Every call forwards to the native SDK, which draws all screens.
///
/// No call throws. A call before [configure] is ignored by the native SDK.
abstract final class ZellioChat {
  static const MethodChannel _channel = MethodChannel('ai.zellio.chat/methods');
  static const EventChannel _eventChannel =
      EventChannel('ai.zellio.chat/events');
  static const EventChannel _unreadChannel =
      EventChannel('ai.zellio.chat/unread');

  /// How long the token provider may take before the SDK treats it as a failure.
  static const Duration tokenTimeout = Duration(seconds: 15);

  static ZellioTokenProvider? _tokenProvider;
  static bool _handlerInstalled = false;
  static Duration _tokenTimeout = tokenTimeout;

  static Stream<ZellioChatEvent>? _events;
  static Stream<int>? _unread;

  /// Starts the SDK. Call once at app start, after `WidgetsFlutterBinding.ensureInitialized()`.
  ///
  /// [baseUrl] defaults to production. [showsInAppBanner] and [bannerShowsPreview] control the small
  /// banner for a new message while chat is closed.
  static Future<void> configure(
    String appKey, {
    String? baseUrl,
    ZellioLocale locale = ZellioLocale.auto,
    ZellioTheme? theme,
    ZellioLogLevel logLevel = ZellioLogLevel.error,
    bool showsInAppBanner = true,
    bool bannerShowsPreview = true,
  }) {
    return _invoke<void>('configure', <String, Object?>{
      'appKey': appKey,
      'baseUrl': baseUrl,
      'locale': locale.wire,
      'theme': (theme ?? const ZellioTheme()).toWire(),
      'logLevel': logLevel.wire,
      'showsInAppBanner': showsInAppBanner,
      'bannerShowsPreview': bannerShowsPreview,
      'wrapper': zellioChatWrapperId,
    });
  }

  /// Marks a signed-in customer. The native SDK calls [tokenProvider] when it needs a session,
  /// and once more if the server rejects the token. The token is never logged.
  ///
  /// The provider has 15 seconds. A slower provider or one that throws counts as a failure.
  static Future<void> identify(ZellioTokenProvider tokenProvider) {
    _tokenProvider = tokenProvider;
    return _invoke<void>('identify');
  }

  /// Ends the session, deletes the local chat data and removes the push token.
  static Future<void> logout() {
    _tokenProvider = null;
    return _invoke<void>('logout');
  }

  /// Shows chat on top of the app.
  static Future<void> present() => _invoke<void>('present');

  /// Opens one conversation, or a new one when [conversationId] is null.
  static Future<void> presentConversation([String? conversationId]) =>
      _invoke<void>('presentConversation', <String, Object?>{
        'conversationId': conversationId,
      });

  /// Closes chat.
  static Future<void> dismiss() => _invoke<void>('dismiss');

  /// Tells the SDK what the customer looks at. Null clears it.
  static Future<void> setContext(ZellioContext? context) =>
      _invoke<void>('setContext', context?.toWire());

  /// The number of unread agent messages, across all conversations, right now.
  static Future<int> get unreadCount async {
    final int? value = await _invoke<int>('unreadCount');
    return value ?? 0;
  }

  /// The unread number now and on every change.
  static Stream<int> get unreadStream => _unread ??= _unreadChannel
      .receiveBroadcastStream()
      .where((Object? value) => value is int)
      .cast<int>();

  /// Chat events for analytics. Unknown events from a newer native SDK are ignored.
  static Stream<ZellioChatEvent> get events => _events ??= _eventChannel
      .receiveBroadcastStream()
      .map<ZellioChatEvent?>(ZellioChatEvent.fromWire)
      .where((ZellioChatEvent? event) => event != null)
      .cast<ZellioChatEvent>();

  /// Gives the SDK the push token. On Android pass the FCM token. On iOS pass the APNs token as hex
  /// (`FirebaseMessaging.instance.getAPNSToken()`). [environment] is `sandbox` or `production` (iOS only).
  static Future<void> setPushToken(String token, {String? environment}) =>
      _invoke<void>('setPushToken', <String, Object?>{
        'token': token,
        'environment': environment,
      });

  /// True only if the payload has the `zellio` key.
  static Future<bool> isZellioPush(Map<String, dynamic> payload) async =>
      await _invoke<bool>('isZellioPush', _normalizePayload(payload)) ?? false;

  /// Refreshes the unread state. Returns true if the push was ours.
  static Future<bool> handlePush(Map<String, dynamic> payload) async =>
      await _invoke<bool>('handlePush', _normalizePayload(payload)) ?? false;

  /// Opens the conversation that the push names. Returns true if the push was ours.
  static Future<bool> handleNotificationTap(
          Map<String, dynamic> payload) async =>
      await _invoke<bool>(
          'handleNotificationTap', _normalizePayload(payload)) ??
      false;

  // ---- internals ----

  /// The native SDK wants string values (the FCM data shape). Maps and lists become JSON text.
  static Map<String, String> _normalizePayload(Map<String, dynamic> payload) {
    final Map<String, String> out = <String, String>{};
    payload.forEach((String key, dynamic value) {
      if (value == null) return;
      if (value is String) {
        out[key] = value;
      } else if (value is Map<dynamic, dynamic> || value is List<dynamic>) {
        try {
          out[key] = jsonEncode(value);
        } catch (_) {
          // Not JSON-safe: skip the field.
        }
      } else {
        out[key] = value.toString();
      }
    });
    return out;
  }

  static Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    _ensureHandler();
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      // No native side (for example a desktop or web build). Do nothing.
      return null;
    } on PlatformException catch (e) {
      debugPrint('zellio_chat: $method failed (${e.code})');
      return null;
    } catch (e) {
      debugPrint('zellio_chat: $method failed (${e.runtimeType})');
      return null;
    }
  }

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'identifyToken':
        final ZellioTokenProvider? provider = _tokenProvider;
        if (provider == null) {
          throw PlatformException(code: 'no_token_provider');
        }
        try {
          final String? token = await provider().timeout(_tokenTimeout);
          return token;
        } on TimeoutException {
          throw PlatformException(code: 'token_timeout');
        } catch (e) {
          // Only the type name goes over the channel. The error text could hold a token.
          throw PlatformException(
            code: 'token_provider_failed',
            message: e.runtimeType.toString(),
          );
        }
      default:
        throw MissingPluginException(call.method);
    }
  }

  /// Test hook: shortens the token timeout.
  @visibleForTesting
  static set debugTokenTimeout(Duration value) => _tokenTimeout = value;

  /// Test hook: forgets the provider and the cached streams.
  @visibleForTesting
  static void debugReset() {
    _tokenProvider = null;
    _tokenTimeout = tokenTimeout;
    _events = null;
    _unread = null;
  }
}
