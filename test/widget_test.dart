import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:take_my_med/main.dart';

void main() {
  testWidgets('renders home experience', (tester) async {
    SharedPreferences.setMockInitialValues({'welcomed': true});
    await tester.pumpWidget(const TakeMyMedApp());
    await tester.pumpAndSettle();
    expect(find.text('TAKE MY MED'), findsOneWidget);
    expect(find.text('Add medicine'), findsWidgets);
  });
}
