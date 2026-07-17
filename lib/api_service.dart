import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  /// Live driver / paramedic API
  String _baseUrl = 'http://119.30.113.25:3001/api';
  String? _token;
  String? _apiKey;
  Map<String, dynamic>? _user;
  DateTime? _tokenExpiry;

  /// Tokens live in the platform keystore (Android Keystore / iOS Keychain),
  /// never in plain SharedPreferences.
  static const _secureStorage = FlutterSecureStorage();
  static const _kToken = 'accessToken';
  static const _kApiKey = 'apiKey';
  static const _kTokenExpiry = 'tokenExpiry';

  /// Called once when the server rejects the token (401) so the app can
  /// force re-login. Set from main.dart.
  void Function()? onSessionExpired;

  /// Set when the server returns 429; telemetry senders check this and skip
  /// sending until the window has passed (no tight retry loops).
  DateTime? _rateLimitedUntil;
  bool get isRateLimited =>
      _rateLimitedUntil != null && DateTime.now().isBefore(_rateLimitedUntil!);

  String get baseUrl => _baseUrl;
  String? get token => _token;
  String? get apiKey => _apiKey;
  Map<String, dynamic>? get user => _user;

  void setBaseUrl(String url) {
    _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  Future<void> loadSavedAuth() async {
    final prefs = await SharedPreferences.getInstance();

    // One-time migration: move tokens out of plain SharedPreferences.
    final legacyToken = prefs.getString('token');
    final legacyApiKey = prefs.getString('apiKey');
    if (legacyToken != null) {
      await _secureStorage.write(key: _kToken, value: legacyToken);
      await prefs.remove('token');
    }
    if (legacyApiKey != null) {
      await _secureStorage.write(key: _kApiKey, value: legacyApiKey);
      await prefs.remove('apiKey');
    }

    _token = await _secureStorage.read(key: _kToken);
    _apiKey = await _secureStorage.read(key: _kApiKey);
    _tokenExpiry =
        DateTime.tryParse(await _secureStorage.read(key: _kTokenExpiry) ?? '');

    // Tokens now expire in 8 hours; treat unknown expiry (legacy) as expired.
    if (_token != null &&
        (_tokenExpiry == null || DateTime.now().isAfter(_tokenExpiry!))) {
      await _clearLocalAuth();
      return;
    }

    final userStr = prefs.getString('user');
    if (userStr != null) {
      try {
        _user = json.decode(userStr);
      } catch (_) {
        _user = null;
      }
    }
  }

  /// "8h" / "30m" / "7d" → Duration. Defaults to 8 hours.
  static Duration _parseExpiresIn(dynamic raw) {
    final s = raw?.toString().trim() ?? '';
    final match = RegExp(r'^(\d+)\s*([smhd]?)$').firstMatch(s);
    if (match == null) return const Duration(hours: 8);
    final value = int.parse(match.group(1)!);
    switch (match.group(2)) {
      case 's':
        return Duration(seconds: value);
      case 'm':
        return Duration(minutes: value);
      case 'd':
        return Duration(days: value);
      case 'h':
      default:
        return Duration(hours: value);
    }
  }

  /// Login with MD5-hashed password (hex lowercase). The password is never
  /// logged or persisted; only the access token is stored (secure storage).
  Future<Map<String, dynamic>> login(String email, String passwordMd5) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'email': email, 'password': passwordMd5}),
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      final data = json.decode(res.body);
      _token = data['accessToken'] ?? data['token'];
      _user = data['user'];
      _apiKey = _user?['apiKey']?.toString();

      if (_token == null || _user == null) {
        throw Exception('Login succeeded but response was incomplete');
      }

      _tokenExpiry = DateTime.now().add(_parseExpiresIn(data['expiresIn']));
      await _secureStorage.write(key: _kToken, value: _token);
      await _secureStorage.write(
          key: _kTokenExpiry, value: _tokenExpiry!.toIso8601String());
      if (_apiKey != null) {
        await _secureStorage.write(key: _kApiKey, value: _apiKey);
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user', json.encode(_user));
      if (_user?['cityId'] != null) {
        await prefs.setString('selectedCityId', _user?['cityId']);
      }
      return data;
    }

    if (res.statusCode == 429) {
      throw Exception(_parseError(
          res, 'Too many failed attempts. Account locked for 15 minutes.'));
    }
    throw Exception(_parseError(res, 'Login failed'));
  }

  /// Revokes the token server-side, then clears it locally. Local auth is
  /// cleared even if the network call fails, so the user is always signed out.
  Future<void> logout() async {
    final activeToken = _token;
    if (activeToken != null) {
      try {
        await http
            .post(Uri.parse('$_baseUrl/auth/logout'), headers: _headers())
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // Token expires server-side in <=8h anyway; local clear is the priority.
      }
    }
    await _clearLocalAuth();
  }

  /// Optional session check: POST /auth/me. Returns false when the token
  /// has been revoked or expired.
  Future<bool> checkSession() async {
    if (_token == null) return false;
    try {
      final res = await _authPost(Uri.parse('$_baseUrl/auth/me'));
      return res.statusCode == 200 || res.statusCode == 201;
    } catch (_) {
      // Network failure is not proof the session is invalid.
      return true;
    }
  }

  Future<void> _clearLocalAuth() async {
    _token = null;
    _apiKey = null;
    _user = null;
    _tokenExpiry = null;
    await _secureStorage.delete(key: _kToken);
    await _secureStorage.delete(key: _kApiKey);
    await _secureStorage.delete(key: _kTokenExpiry);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user');
    await prefs.remove('selectedCityId');
  }

  Map<String, String> _headers() {
    return {
      'Content-Type': 'application/json',
      if (_token != null) 'Authorization': 'Bearer $_token',
      if (_token == null && _apiKey != null) 'X-API-Key': _apiKey!,
    };
  }

  /// All authenticated requests go through these guards: a 401 means the
  /// token was revoked/expired, so clear it and force re-login.
  Future<http.Response> _guard(Future<http.Response> request) async {
    final res = await request;
    if (res.statusCode == 401 && _token != null) {
      _token = null; // set synchronously so concurrent 401s fire this once
      await _clearLocalAuth();
      onSessionExpired?.call();
    }
    if (res.statusCode == 429) {
      final retryAfter = int.tryParse(res.headers['retry-after'] ?? '');
      _rateLimitedUntil =
          DateTime.now().add(Duration(seconds: retryAfter ?? 5));
    }
    return res;
  }

  Future<http.Response> _authGet(Uri uri) => _guard(http.get(uri, headers: _headers()));

  Future<http.Response> _authPost(Uri uri, {Object? body}) =>
      _guard(http.post(uri, headers: _headers(), body: body));

  Future<http.Response> _authPatch(Uri uri, {Object? body}) =>
      _guard(http.patch(uri, headers: _headers(), body: body));

  String _parseError(http.Response res, String fallback) {
    if (res.statusCode == 401) {
      return 'Session expired. Please log in again.';
    }
    if (res.statusCode == 429) {
      return 'Too many requests. Backing off — will retry shortly.';
    }
    try {
      final err = json.decode(res.body);
      final message = err['message'];
      if (message is List) return message.join(', ');
      if (message != null) return message.toString();
    } catch (_) {}
    return '$fallback (${res.statusCode})';
  }

  Future<List<dynamic>> fetchHospitals(String cityId) async {
    final res = await _authGet(Uri.parse('$_baseUrl/hospitals?cityId=$cityId'));
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception(_parseError(res, 'Failed to load hospitals'));
  }

  /// Hospitals that cater the selected emergency type, nearest first.
  /// Response: { recommendedHospitalId, selectionReason, hospitals: [...] }
  Future<Map<String, dynamic>> fetchSuitableHospitals({
    required String cityId,
    required String emergencyTypeId,
    required double latitude,
    required double longitude,
  }) async {
    final uri = Uri.parse('$_baseUrl/hospitals/suitable').replace(
      queryParameters: {
        'cityId': cityId,
        'emergencyTypeId': emergencyTypeId,
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
      },
    );
    final res = await _authGet(uri);
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      if (data is Map) return Map<String, dynamic>.from(data);
    }
    throw Exception(_parseError(res, 'Failed to load suitable hospitals'));
  }

  Future<List<dynamic>> fetchEmergencyTypes() async {
    final res = await _authGet(Uri.parse('$_baseUrl/emergency-types'));
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception(_parseError(res, 'Failed to load emergency types'));
  }

  Future<List<dynamic>> fetchTriageCodes() async {
    final res = await _authGet(Uri.parse('$_baseUrl/triage-codes'));
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception(_parseError(res, 'Failed to load triage codes'));
  }

  Future<List<dynamic>> fetchAmbulances(String cityId) async {
    final res = await _authGet(Uri.parse('$_baseUrl/ambulances?cityId=$cityId'));
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception(_parseError(res, 'Failed to load ambulances'));
  }

  /// Assigned ambulance for the logged-in driver (driverId must match in Admin).
  /// Response: { ambulance: {...}, activeTransit: {...}|null }
  Future<Map<String, dynamic>> fetchMyAmbulance() async {
    final res = await _authGet(Uri.parse('$_baseUrl/ambulances/mine'));
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      if (data is Map) return Map<String, dynamic>.from(data);
    }
    throw Exception(_parseError(res, 'Failed to load my ambulance'));
  }

  Future<List<dynamic>> fetchActiveTransits(String cityId) async {
    final res = await _authGet(
      Uri.parse('$_baseUrl/transits?active=true&cityId=$cityId'),
    );
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception(_parseError(res, 'Failed to load transits'));
  }

  Future<Map<String, dynamic>> createTransit({
    required String ambulanceId,
    required String hospitalId,
    required String emergencyTypeId,
    required String triageCodeId,
    String? sectorId,
    String? paramedicNotes,
    required double originLat,
    required double originLng,
    int baselineEtaMinutes = 12,
  }) async {
    final res = await _authPost(
      Uri.parse('$_baseUrl/transits'),
      body: json.encode({
        'ambulanceId': ambulanceId,
        'hospitalId': hospitalId,
        'emergencyTypeId': emergencyTypeId,
        'triageCodeId': triageCodeId,
        if (sectorId != null) 'sectorId': sectorId,
        if (paramedicNotes != null && paramedicNotes.isNotEmpty)
          'paramedicNotes': paramedicNotes,
        'originLat': originLat,
        'originLng': originLng,
        'baselineEtaMinutes': baselineEtaMinutes,
      }),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return json.decode(res.body);
    }
    throw Exception(_parseError(res, 'Failed to create transit'));
  }

  Future<Map<String, dynamic>> startTransit(String id, double lat, double lng) async {
    final res = await _authPatch(
      Uri.parse('$_baseUrl/transits/$id/start'),
      body: json.encode({'currentLat': lat, 'currentLng': lng}),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return json.decode(res.body);
    }
    throw Exception(_parseError(res, 'Failed to start transit'));
  }

  Future<Map<String, dynamic>> markArrived(String id) async {
    final res = await _authPatch(Uri.parse('$_baseUrl/transits/$id/arrived'));
    if (res.statusCode == 200 || res.statusCode == 201) {
      return json.decode(res.body);
    }
    throw Exception(_parseError(res, 'Failed to mark arrived'));
  }

  Future<Map<String, dynamic>> completeTransit(String id) async {
    final res = await _authPatch(Uri.parse('$_baseUrl/transits/$id/complete'));
    if (res.statusCode == 200 || res.statusCode == 201) {
      return json.decode(res.body);
    }
    throw Exception(_parseError(res, 'Failed to complete transit'));
  }

  /// Live ETA for HQ / Hospital / Safe City (driver permission).
  /// Overwrites transit.etaMinutes. Allowed for pending | en_route | arrived.
  /// Always send currentSpeed in km/h so Safe City live speed is not stuck at 0.
  Future<Map<String, dynamic>> updateTransitEta({
    required String transitId,
    required double etaMinutes,
    double? currentLat,
    double? currentLng,
    required double currentSpeed,
  }) async {
    final body = <String, dynamic>{
      'etaMinutes': etaMinutes.toDouble(),
      'currentSpeed': currentSpeed.toDouble(),
    };
    if (currentLat != null) body['currentLat'] = currentLat.toDouble();
    if (currentLng != null) body['currentLng'] = currentLng.toDouble();

    final res = await _authPatch(
      Uri.parse('$_baseUrl/transits/$transitId/eta'),
      body: json.encode(body),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return json.decode(res.body);
    }
    throw Exception(_parseError(res, 'Failed to update ETA'));
  }

  /// Live GPS sync for HQ / Safe City / Admin maps.
  /// latitude, longitude, speed, heading must be JSON numbers (not strings).
  /// Optional etaMinutes can be sent in the same GPS call.
  Future<Map<String, dynamic>> postGpsUpdate(
    String ambulanceId,
    double lat,
    double lng,
    double speed, {
    double? heading,
    String? transitId,
    double? etaMinutes,
  }) async {
    final body = <String, dynamic>{
      'latitude': lat.toDouble(),
      'longitude': lng.toDouble(),
      'speed': speed.toDouble(),
    };
    if (heading != null) {
      body['heading'] = heading.toDouble();
    }
    if (transitId != null && transitId.isNotEmpty) {
      body['transitId'] = transitId;
    }
    if (etaMinutes != null) {
      body['etaMinutes'] = etaMinutes.toDouble();
    }

    final res = await _authPatch(
      Uri.parse('$_baseUrl/ambulances/$ambulanceId/gps'),
      body: json.encode(body),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return json.decode(res.body);
    }
    throw Exception(_parseError(res, 'Failed to post GPS update'));
  }
}
