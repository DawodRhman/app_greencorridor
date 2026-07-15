import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'api_service.dart';
import 'home_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController(text: 'driver@1122.pk');
  final _passwordController = TextEditingController(text: 'password123');
  final _apiUrlController = TextEditingController(text: 'https://gchq-backend.vercel.app/api');
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _apiUrlController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final api = ApiService();
    api.setBaseUrl(_apiUrlController.text);

    try {
      final bytes = utf8.encode(_passwordController.text);
      final md5Password = md5.convert(bytes).toString();

      final res = await api.login(
        _emailController.text.trim(),
        md5Password,
      );

      final user = res['user'];
      if (user['role'] != 'paramedic' && user['role'] != 'admin') {
        throw Exception('Access denied. Only paramedic staff may use this application.');
      }

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomePage()),
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF16A34A).withOpacity(0.04),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                )
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.local_hospital,
                  size: 48,
                  color: const Color(0xFF16A34A),
                ),
                const SizedBox(height: 16),
                Text(
                  'Green Corridor',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF16A34A),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Green Corridor — Paramedic Dispatch',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _apiUrlController,
                  decoration: const InputDecoration(
                    labelText: 'API Gateway Endpoint',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.dns, color: const Color(0xFF16A34A)),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: const Color(0xFF16A34A), width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: 'Email Address',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.email, color: const Color(0xFF16A34A)),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: const Color(0xFF16A34A), width: 2),
                    ),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'Access Password',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock, color: const Color(0xFF16A34A)),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: const Color(0xFF16A34A), width: 2),
                    ),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: const Color(0xFF16A34A),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                ElevatedButton(
                  onPressed: _loading ? null : _handleLogin,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    elevation: 0,
                  ),
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Enter Green Corridor',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 12),
                const Text(
                  'Demo Accounts: driver@1122.pk | password123',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
