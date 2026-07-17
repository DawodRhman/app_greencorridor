import 'package:flutter/material.dart';
import 'api_service.dart';
import 'login_page.dart';
import 'home_page.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = ApiService();
  await api.loadSavedAuth();

  // Server returned 401 (token expired/revoked): force re-login.
  api.onSessionExpired = () {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    navigator.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
    final ctx = navigatorKey.currentContext;
    if (ctx != null) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(content: Text('Session expired. Please log in again.')),
      );
    }
  };

  runApp(const GreenCorridorApp());
}

class GreenCorridorApp extends StatelessWidget {
  const GreenCorridorApp({super.key});

  @override
  Widget build(BuildContext context) {
    final api = ApiService();
    final isLoggedIn = api.token != null && api.user != null;

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Green Corridor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF16A34A),
          primary: const Color(0xFF16A34A),
          secondary: Colors.grey.shade700,
          surface: Colors.white,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          floatingLabelBehavior: FloatingLabelBehavior.auto,
        ),
      ),
      home: isLoggedIn ? const HomePage() : const LoginPage(),
    );
  }
}
