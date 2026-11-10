import * as ZellioChat from '@zellio/chat-react-native';
import { useEffect, useState } from 'react';
import { Pressable, SafeAreaView, ScrollView, StatusBar, StyleSheet, Text, View } from 'react-native';
import config from './zellio.config.json';

// A store-like screen. The chat itself is drawn by the native SDK: this file only configures it, opens it,
// shows the unread badge and tells agents which product the customer looks at.
const PRODUCTS = [
  { id: 'p-100', title: 'Linen shirt', price: '$39' },
  { id: 'p-200', title: 'Canvas sneakers', price: '$65' },
  { id: 'p-300', title: 'Leather belt', price: '$24' },
];

const KEY_IS_PLACEHOLDER = config.appKey.includes('replace_with');

ZellioChat.configure({
  appKey: config.appKey,
  baseUrl: config.baseUrl,
  locale: config.locale === 'ar' || config.locale === 'en' ? config.locale : 'auto',
  logLevel: 'debug',
});

// In a real app this calls your server, which signs a token for the signed-in customer. Return null for a guest.
ZellioChat.identify(async () => null);

export default function App() {
  const [unread, setUnread] = useState(0);
  const [lastEvent, setLastEvent] = useState('none yet');
  const [selected, setSelected] = useState<string | null>(null);

  useEffect(() => {
    const unreadSubscription = ZellioChat.addUnreadListener(setUnread);
    const eventSubscription = ZellioChat.addEventListener((event) => {
      setLastEvent(event.type === 'error' ? `error (${event.code})` : event.type);
    });
    return () => {
      unreadSubscription.remove();
      eventSubscription.remove();
    };
  }, []);

  useEffect(() => {
    const product = PRODUCTS.find((item) => item.id === selected);
    ZellioChat.setContext(
      product
        ? { screen: 'Product', itemType: 'product', itemId: product.id, itemTitle: product.title }
        : { screen: 'Shop' },
    );
  }, [selected]);

  return (
    <SafeAreaView style={styles.screen}>
      <StatusBar barStyle="dark-content" />
      <View style={styles.header}>
        <Text style={styles.title} accessibilityRole="header">
          Zellio Shop
        </Text>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={unread > 0 ? `Open chat, ${unread} unread` : 'Open chat'}
          testID="open-chat"
          style={styles.chatButton}
          onPress={() => ZellioChat.present()}>
          <Text style={styles.chatButtonText}>Open chat</Text>
          {unread > 0 ? (
            <View style={styles.badge} testID="unread-badge">
              <Text style={styles.badgeText}>{unread > 99 ? '99+' : String(unread)}</Text>
            </View>
          ) : null}
        </Pressable>
      </View>

      <ScrollView contentContainerStyle={styles.list}>
        {PRODUCTS.map((product) => (
          <Pressable
            key={product.id}
            accessibilityRole="button"
            accessibilityState={{ selected: selected === product.id }}
            onPress={() => setSelected(selected === product.id ? null : product.id)}
            style={[styles.card, selected === product.id && styles.cardSelected]}>
            <Text style={styles.cardTitle}>{product.title}</Text>
            <Text style={styles.cardPrice}>{product.price}</Text>
          </Pressable>
        ))}
        <Text style={styles.note}>
          {selected ? 'Agents see the selected product when you write to them.' : 'Pick a product to share it as context.'}
        </Text>
        <View style={styles.debug}>
          <Text style={styles.debugLine}>Unread: {unread}</Text>
          <Text style={styles.debugLine}>Last event: {lastEvent}</Text>
          <Text style={styles.debugLine}>
            Server: {config.baseUrl}
            {KEY_IS_PLACEHOLDER ? ' (placeholder app key: put yours in zellio.config.json)' : ''}
          </Text>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#FAFAFC' },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', padding: 20 },
  title: { fontSize: 28, fontWeight: '700', color: '#111426' },
  chatButton: {
    minHeight: 48,
    paddingHorizontal: 18,
    borderRadius: 12,
    backgroundColor: '#3B5BDB',
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
  },
  chatButtonText: { color: '#FFFFFF', fontSize: 16, fontWeight: '600' },
  badge: {
    minWidth: 22,
    height: 22,
    borderRadius: 11,
    marginStart: 8,
    paddingHorizontal: 6,
    backgroundColor: '#D92D32',
    alignItems: 'center',
    justifyContent: 'center',
  },
  badgeText: { color: '#FFFFFF', fontSize: 12, fontWeight: '700' },
  list: { padding: 20, gap: 12 },
  card: {
    padding: 18,
    borderRadius: 16,
    backgroundColor: '#FFFFFF',
    borderWidth: 1,
    borderColor: '#E7E7EF',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  cardSelected: { borderColor: '#3B5BDB', borderWidth: 2 },
  cardTitle: { fontSize: 16, color: '#111426' },
  cardPrice: { fontSize: 16, fontWeight: '600', color: '#111426' },
  note: { fontSize: 13, color: '#50556B', marginTop: 4 },
  debug: { marginTop: 16, padding: 12, borderRadius: 12, backgroundColor: '#F1F1F6' },
  debugLine: { fontSize: 12, color: '#50556B' },
});
