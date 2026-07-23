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
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final api = ApiService();

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

      api.postAuditEvent('mobile_login'); // best-effort, non-blocking

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
    final size = MediaQuery.of(context).size;
    final isTablet = size.shortestSide >= 600;
    final cardMaxWidth = isTablet ? 480.0 : 420.0;
    final horizontalPad = isTablet ? 40.0 : 24.0;
    final logoHeight = isTablet ? 112.0 : 96.0;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(vertical: isTablet ? 32 : 16),
            child: Container(
              constraints: BoxConstraints(maxWidth: cardMaxWidth),
              margin: EdgeInsets.all(horizontalPad),
              padding: EdgeInsets.all(isTablet ? 40 : 32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE2E8F0)),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF16A34A).withValues(alpha: 0.04),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  )
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Image.asset(
                      'assets/images/gchq_logo.png',
                      height: logoHeight,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Green Corridor',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF16A34A),
                      fontSize: isTablet ? 28 : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Paramedic Dispatch',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.grey.shade600,
                      fontSize: isTablet ? 16 : null,
                    ),
                  ),
                  SizedBox(height: isTablet ? 40 : 32),
                  TextField(
                    controller: _emailController,
                    decoration: const InputDecoration(
                      labelText: 'Email Address',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.email, color: Color(0xFF16A34A)),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF16A34A), width: 2),
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
                      prefixIcon: Icon(Icons.lock, color: Color(0xFF16A34A)),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF16A34A), width: 2),
                      ),
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 8),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: Color(0xFF16A34A),
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
                      minimumSize: Size.fromHeight(isTablet ? 56 : 48),
                      padding: EdgeInsets.symmetric(vertical: isTablet ? 18 : 16),
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
                        : Text(
                            'Enter Green Corridor',
                            style: TextStyle(
                              fontSize: isTablet ? 18 : 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
