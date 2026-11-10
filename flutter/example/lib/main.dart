import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zellio_chat/zellio_chat.dart';

// Run with your own values:
//   flutter run \
//     --dart-define=ZELLIO_APP_KEY=zca_xxx \
//     --dart-define=ZELLIO_BASE_URL=https://app.zellio.ai \
//     --dart-define=ZELLIO_LOCALE=en \
//     --dart-define=ZELLIO_DEMO_TOKEN=<a test identity JWT from your server>
// Without ZELLIO_APP_KEY the app still runs, but the chat button is off.
const String appKey = String.fromEnvironment('ZELLIO_APP_KEY');
const String baseUrl = String.fromEnvironment('ZELLIO_BASE_URL');
const String localeName =
    String.fromEnvironment('ZELLIO_LOCALE', defaultValue: 'auto');
const String demoToken = String.fromEnvironment('ZELLIO_DEMO_TOKEN');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (appKey.isNotEmpty) {
    await ZellioChat.configure(
      appKey,
      baseUrl: baseUrl.isEmpty ? null : baseUrl,
      locale: switch (localeName) {
        'ar' => ZellioLocale.arabic,
        'en' => ZellioLocale.english,
        _ => ZellioLocale.auto,
      },
      logLevel: ZellioLogLevel.info,
    );
  }
  runApp(const StoreApp());
}

class StoreApp extends StatelessWidget {
  const StoreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zellio Chat Example',
      theme: ThemeData(
          colorSchemeSeed: const Color(0xFF1A73E8), useMaterial3: true),
      home: const StoreHome(),
    );
  }
}

class Product {
  const Product(this.id, this.title, this.price);
  final String id;
  final String title;
  final String price;
}

const List<Product> products = <Product>[
  Product('p1', 'Canvas sneakers', '\$49'),
  Product('p2', 'Linen shirt', '\$35'),
  Product('p3', 'Leather wallet', '\$29'),
  Product('p4', 'Travel backpack', '\$79'),
];

class StoreHome extends StatefulWidget {
  const StoreHome({super.key});

  @override
  State<StoreHome> createState() => _StoreHomeState();
}

class _StoreHomeState extends State<StoreHome> {
  final List<String> _log = <String>[];
  StreamSubscription<ZellioChatEvent>? _events;
  bool _signedIn = false;

  bool get _chatReady => appKey.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_chatReady) {
      _events = ZellioChat.events.listen((ZellioChatEvent event) {
        if (!mounted) return;
        setState(() {
          _log.insert(
              0,
              switch (event) {
                ChatOpened() => 'chat opened',
                ChatClosed() => 'chat closed',
                MessageSent() => 'message sent',
                MessageReceived() => 'message received',
                ChatError(:final code) => 'error: $code',
              });
          if (_log.length > 5) _log.removeLast();
        });
      });
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  Future<void> _toggleSignIn() async {
    if (_signedIn) {
      await ZellioChat.logout();
    } else {
      // A real app asks its own server for a short-lived identity token here.
      await ZellioChat.identify(
          () async => demoToken.isEmpty ? null : demoToken);
    }
    setState(() => _signedIn = !_signedIn);
  }

  Future<void> _openProduct(Product product) async {
    await ZellioChat.setContext(ZellioContext(
      screen: 'product_detail',
      itemType: 'product',
      itemId: product.id,
      itemTitle: product.title,
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Chat knows you look at ${product.title}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Demo Store'),
        actions: <Widget>[
          if (_chatReady)
            TextButton(
              key: const Key('signIn'),
              onPressed: _toggleSignIn,
              child: Text(_signedIn ? 'Sign out' : 'Sign in'),
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (!_chatReady)
            const MaterialBanner(
              content: Text(
                  'No app key. Run with --dart-define=ZELLIO_APP_KEY=zca_...'),
              actions: <Widget>[SizedBox.shrink()],
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                for (final Product p in products)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.shopping_bag_outlined),
                      title: Text(p.title),
                      subtitle: Text(p.price),
                      onTap: _chatReady ? () => _openProduct(p) : null,
                    ),
                  ),
              ],
            ),
          ),
          if (_log.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('Events: ${_log.join(', ')}',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('openChat'),
        onPressed: _chatReady ? ZellioChat.present : null,
        icon: _chatReady
            ? StreamBuilder<int>(
                stream: ZellioChat.unreadStream,
                initialData: 0,
                builder: (BuildContext context, AsyncSnapshot<int> snapshot) {
                  final int unread = snapshot.data ?? 0;
                  return Badge(
                    isLabelVisible: unread > 0,
                    label: Text('$unread'),
                    child: const Icon(Icons.chat_bubble_outline),
                  );
                },
              )
            : const Icon(Icons.chat_bubble_outline),
        label: const Text('Open chat'),
      ),
    );
  }
}
