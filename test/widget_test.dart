import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:take_your_med/main.dart';

void main() {
  testWidgets('renders home experience', (tester) async {
    SharedPreferences.setMockInitialValues({'welcomed': true});
    await tester.pumpWidget(const TakeYourMedApp());
    await tester.pumpAndSettle();
    expect(find.text('TAKE YOUR MED'), findsOneWidget);
    expect(find.text('Add medicine'), findsWidgets);
  });
}
