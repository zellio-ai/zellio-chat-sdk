import 'package:flutter_test/flutter_test.dart';
import 'package:zellio_chat_example/main.dart';

void main() {
  testWidgets('shows the store and the chat button without an app key',
      (WidgetTester tester) async {
    await tester.pumpWidget(const StoreApp());
    expect(find.text('Demo Store'), findsOneWidget);
    expect(find.text('Open chat'), findsOneWidget);
    expect(find.textContaining('No app key'), findsOneWidget);
  });
}
