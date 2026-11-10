import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zellio_chat/zellio_chat.dart';
import 'package:zellio_chat/src/version.dart';

const MethodChannel _methods = MethodChannel('ai.zellio.chat/methods');
const String _eventsName = 'ai.zellio.chat/events';
const String _unreadName = 'ai.zellio.chat/unread';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final List<MethodCall> calls = <MethodCall>[];
  Object? Function(MethodCall call) nativeAnswer = (MethodCall call) => null;

  setUp(() {
    calls.clear();
    nativeAnswer = (MethodCall call) => null;
    ZellioChat.debugReset();
    messenger.setMockMethodCallHandler(_methods, (MethodCall call) async {
      calls.add(call);
      return nativeAnswer(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockStreamHandler(const EventChannel(_eventsName), null);
    messenger.setMockStreamHandler(const EventChannel(_unreadName), null);
  });

  group('method forwarding', () {
    test('configure sends every option and the wrapper id', () async {
      await ZellioChat.configure(
        'zk_test',
        baseUrl: 'https://staging.example.com',
        locale: ZellioLocale.arabic,
        theme: const ZellioTheme(
          mode: ZellioThemeMode.dark,
          primaryColor: Color(0xFF1A73E8),
        ),
        logLevel: ZellioLogLevel.debug,
        showsInAppBanner: false,
        bannerShowsPreview: false,
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'configure');
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(args['appKey'], 'zk_test');
      expect(args['baseUrl'], 'https://staging.example.com');
      expect(args['locale'], 'ar');
      expect(args['logLevel'], 'debug');
      expect(args['showsInAppBanner'], false);
      expect(args['bannerShowsPreview'], false);
      expect(args['wrapper'], 'flutter/$zellioChatPluginVersion');
      final Map<Object?, Object?> theme =
          args['theme']! as Map<Object?, Object?>;
      expect(theme['mode'], 'dark');
      expect(theme['primaryColor'], '#1A73E8');
      expect(theme['customerMessageColor'], isNull);
    });

    test('configure defaults', () async {
      await ZellioChat.configure('zk_test');
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(args['baseUrl'], isNull);
      expect(args['locale'], 'auto');
      expect(args['logLevel'], 'error');
      expect(args['showsInAppBanner'], true);
      expect(args['bannerShowsPreview'], true);
    });

    test('simple calls forward by name', () async {
      await ZellioChat.present();
      await ZellioChat.dismiss();
      await ZellioChat.logout();
      expect(calls.map((MethodCall c) => c.method),
          <String>['present', 'dismiss', 'logout']);
    });

    test('presentConversation forwards the id, or null for a new one',
        () async {
      await ZellioChat.presentConversation('c1');
      await ZellioChat.presentConversation();
      expect((calls[0].arguments as Map<Object?, Object?>)['conversationId'],
          'c1');
      expect((calls[1].arguments as Map<Object?, Object?>)['conversationId'],
          isNull);
    });

    test('setContext forwards the fields, and null clears', () async {
      await ZellioChat.setContext(const ZellioContext(
        screen: 'product',
        itemType: 'product',
        itemId: '42',
        itemTitle: 'Shoes',
        url: 'https://shop.example.com/42',
      ));
      await ZellioChat.setContext(null);
      final Map<Object?, Object?> first =
          calls[0].arguments as Map<Object?, Object?>;
      expect(first['itemId'], '42');
      expect(first['url'], 'https://shop.example.com/42');
      expect(calls[1].method, 'setContext');
      expect(calls[1].arguments, isNull);
    });

    test('setPushToken forwards token and environment', () async {
      await ZellioChat.setPushToken('abc', environment: 'sandbox');
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(args['token'], 'abc');
      expect(args['environment'], 'sandbox');
    });

    test('unreadCount reads the native value', () async {
      nativeAnswer =
          (MethodCall call) => call.method == 'unreadCount' ? 3 : null;
      expect(await ZellioChat.unreadCount, 3);
    });

    test('unreadCount is 0 when the native side answers nothing', () async {
      expect(await ZellioChat.unreadCount, 0);
    });

    test('push helpers send string values and return the native answer',
        () async {
      nativeAnswer = (MethodCall call) => call.method != 'handlePush';
      final Map<String, dynamic> payload = <String, dynamic>{
        'zellio': <String, dynamic>{'v': 1, 'conversationId': 'c1'},
        'count': 2,
        'skip': null,
      };
      expect(await ZellioChat.isZellioPush(payload), isTrue);
      expect(await ZellioChat.handlePush(payload), isFalse);
      expect(await ZellioChat.handleNotificationTap(payload), isTrue);
      final Map<Object?, Object?> sent =
          calls.first.arguments as Map<Object?, Object?>;
      expect(sent['zellio'], '{"v":1,"conversationId":"c1"}');
      expect(sent['count'], '2');
      expect(sent.containsKey('skip'), isFalse);
    });

    test('a missing native side does not throw', () async {
      messenger.setMockMethodCallHandler(_methods, null);
      await ZellioChat.present();
      expect(await ZellioChat.unreadCount, 0);
      expect(await ZellioChat.isZellioPush(<String, dynamic>{'zellio': '{}'}),
          isFalse);
    });

    test('a native error does not throw', () async {
      nativeAnswer = (MethodCall call) => throw PlatformException(code: 'boom');
      await ZellioChat.present();
    });
  });

  group('identify', () {
    Future<Object?> askToken() async {
      final Completer<Object?> done = Completer<Object?>();
      await messenger.handlePlatformMessage(
        _methods.name,
        _methods.codec.encodeMethodCall(const MethodCall('identifyToken')),
        (ByteData? data) =>
            done.complete(data == null ? 'no-handler' : _decode(data)),
      );
      return done.future;
    }

    test('registers with native, then answers the token request', () async {
      await ZellioChat.identify(() async => 'jwt-from-server');
      expect(calls.single.method, 'identify');
      expect(await askToken(), 'jwt-from-server');
    });

    test('a null token (logged out) goes back as null', () async {
      await ZellioChat.identify(() async => null);
      expect(await askToken(), isNull);
    });

    test('a provider error becomes a coded error without the error text',
        () async {
      await ZellioChat.identify(() async => throw StateError('secret-detail'));
      final Object? answer = await askToken();
      expect(answer, isA<PlatformException>());
      final PlatformException error = answer! as PlatformException;
      expect(error.code, 'token_provider_failed');
      expect(error.message, 'StateError');
      expect(error.toString(), isNot(contains('secret-detail')));
    });

    test('a provider that is too slow times out', () async {
      ZellioChat.debugTokenTimeout = const Duration(milliseconds: 50);
      await ZellioChat.identify(() => Completer<String?>().future);
      final Object? answer = await askToken();
      expect(answer, isA<PlatformException>());
      expect((answer! as PlatformException).code, 'token_timeout');
    });

    test('a request without identify is an error', () async {
      await ZellioChat.present(); // installs the handler
      final Object? answer = await askToken();
      expect((answer! as PlatformException).code, 'no_token_provider');
    });

    test('logout forgets the provider', () async {
      await ZellioChat.identify(() async => 'jwt');
      await ZellioChat.logout();
      final Object? answer = await askToken();
      expect((answer! as PlatformException).code, 'no_token_provider');
    });

    test('the default timeout is 15 seconds', () {
      expect(ZellioChat.tokenTimeout, const Duration(seconds: 15));
    });
  });

  group('streams', () {
    void mockStream(String name, List<Object?> items) {
      messenger.setMockStreamHandler(
        EventChannel(name),
        MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink sink) {
            for (final Object? item in items) {
              sink.success(item);
            }
            sink.endOfStream();
          },
        ),
      );
    }

    test('events decode, and unknown or broken events are ignored', () async {
      mockStream(_eventsName, <Object?>[
        <String, Object?>{'type': 'chatOpened'},
        <String, Object?>{'type': 'somethingNew', 'x': 1},
        'not a map',
        null,
        <String, Object?>{'type': 'messageSent'},
        <String, Object?>{'type': 'messageReceived'},
        <String, Object?>{'type': 'error', 'code': 'network'},
        <String, Object?>{'type': 'error'},
        <String, Object?>{'type': 'chatClosed'},
      ]);
      final List<ZellioChatEvent> got = await ZellioChat.events.toList();
      expect(got, hasLength(6));
      expect(got[0], isA<ChatOpened>());
      expect(got[1], isA<MessageSent>());
      expect(got[2], isA<MessageReceived>());
      expect(got[3], const ChatError('network'));
      expect(got[4], const ChatError('unknown'));
      expect(got[5], isA<ChatClosed>());
    });

    test('unread stream passes integers and drops other values', () async {
      mockStream(_unreadName, <Object?>[0, 2, 'x', null, 5]);
      expect(await ZellioChat.unreadStream.toList(), <int>[0, 2, 5]);
    });
  });

  test('plugin version matches pubspec.yaml', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch? match =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(match!.group(1), zellioChatPluginVersion);
  });
}

Object? _decode(ByteData data) {
  try {
    return _methods.codec.decodeEnvelope(data);
  } on PlatformException catch (e) {
    return e;
  }
}
