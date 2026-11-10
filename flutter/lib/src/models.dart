import 'package:flutter/painting.dart';

/// The language of the chat screens. [auto] follows the Studio policy and the device language.
enum ZellioLocale {
  /// Follow the device, then the Studio language policy.
  auto('auto'),

  /// Egyptian Arabic, right to left.
  arabic('ar'),

  /// English.
  english('en');

  const ZellioLocale(this.wire);

  /// The value sent to the native SDK.
  final String wire;
}

/// Light, dark, or follow the device.
enum ZellioThemeMode {
  /// Follow the device.
  auto('auto'),

  /// Always light.
  light('light'),

  /// Always dark.
  dark('dark');

  const ZellioThemeMode(this.wire);

  /// The value sent to the native SDK.
  final String wire;
}

/// How much the native SDK writes to the platform log. Chat text and tokens are never logged.
enum ZellioLogLevel {
  /// Nothing.
  none('none'),

  /// Errors only.
  error('error'),

  /// Errors and warnings. On iOS this maps to [error].
  warn('warn'),

  /// Also info lines.
  info('info'),

  /// Everything the SDK logs.
  debug('debug');

  const ZellioLogLevel(this.wire);

  /// The value sent to the native SDK.
  final String wire;
}

/// Theme overrides. A value set here wins over Studio. Every field is optional.
class ZellioTheme {
  /// Creates theme overrides.
  const ZellioTheme({
    this.mode = ZellioThemeMode.auto,
    this.primaryColor,
    this.customerMessageColor,
    this.surfaceColor,
  });

  /// Light, dark, or follow the device.
  final ZellioThemeMode mode;

  /// The brand color. The alpha channel is ignored.
  final Color? primaryColor;

  /// The color of the customer message bubbles. The alpha channel is ignored.
  final Color? customerMessageColor;

  /// The chat background in light mode. The alpha channel is ignored.
  final Color? surfaceColor;

  /// The map that goes over the method channel. Colors are `#RRGGBB`.
  Map<String, Object?> toWire() => <String, Object?>{
        'mode': mode.wire,
        'primaryColor': _hex(primaryColor),
        'customerMessageColor': _hex(customerMessageColor),
        'surfaceColor': _hex(surfaceColor),
      };

  static String? _hex(Color? color) {
    if (color == null) return null;
    final int rgb = color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}

/// What the customer looks at in the app. Agents see it. It is sent with the next messages.
///
/// The native SDK cuts each text to 200 characters and keeps [url] only if it starts with `https://`.
class ZellioContext {
  /// Creates a context.
  const ZellioContext({
    this.screen,
    this.itemType,
    this.itemId,
    this.itemTitle,
    this.url,
  });

  /// The screen name, for example `product_detail`.
  final String? screen;

  /// The kind of item, for example `product`.
  final String? itemType;

  /// The id of the item.
  final String? itemId;

  /// The title of the item.
  final String? itemTitle;

  /// A link to the item. Must be https.
  final String? url;

  /// The map that goes over the method channel.
  Map<String, Object?> toWire() => <String, Object?>{
        'screen': screen,
        'itemType': itemType,
        'itemId': itemId,
        'itemTitle': itemTitle,
        'url': url,
      };
}

/// Events for the app analytics. They never carry message text.
sealed class ZellioChatEvent {
  const ZellioChatEvent();

  /// Reads an event from the native side. Returns null for anything that is not a known event,
  /// so a newer native SDK never breaks an older plugin.
  static ZellioChatEvent? fromWire(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    switch (raw['type']) {
      case 'chatOpened':
        return const ChatOpened();
      case 'chatClosed':
        return const ChatClosed();
      case 'messageSent':
        return const MessageSent();
      case 'messageReceived':
        return const MessageReceived();
      case 'error':
        final Object? code = raw['code'];
        return ChatError(code is String && code.isNotEmpty ? code : 'unknown');
      default:
        return null;
    }
  }
}

/// The chat screen opened.
final class ChatOpened extends ZellioChatEvent {
  /// Creates the event.
  const ChatOpened();
}

/// The chat screen closed.
final class ChatClosed extends ZellioChatEvent {
  /// Creates the event.
  const ChatClosed();
}

/// The customer sent a message.
final class MessageSent extends ZellioChatEvent {
  /// Creates the event.
  const MessageSent();
}

/// A message from an agent arrived.
final class MessageReceived extends ZellioChatEvent {
  /// Creates the event.
  const MessageReceived();
}

/// The SDK reported an error. [code] is a stable code, never message text.
final class ChatError extends ZellioChatEvent {
  /// Creates the event.
  const ChatError(this.code);

  /// The error code.
  final String code;

  @override
  bool operator ==(Object other) => other is ChatError && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'ChatError($code)';
}
