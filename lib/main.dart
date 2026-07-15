import 'package:flutter/material.dart';
import 'api_service.dart';
import 'login_page.dart';
import 'home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = ApiService();
  await api.loadSavedAuth();

  runApp(const GreenCorridorApp());
}

class GreenCorridorApp extends StatelessWidget {
  const GreenCorridorApp({super.key});

  @override
  Widget build(BuildContext context) {
    final api = ApiService();
    final isLoggedIn = api.token != null && api.user != null;

    return MaterialApp(
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
