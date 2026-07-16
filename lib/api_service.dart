import 'dart:convert';
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

  String get baseUrl => _baseUrl;
  String? get token => _token;
  String? get apiKey => _apiKey;
  Map<String, dynamic>? get user => _user;

  void setBaseUrl(String url) {
    _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  Future<void> loadSavedAuth() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('token');
    _apiKey = prefs.getString('apiKey');
    final userStr = prefs.getString('user');
    if (userStr != null) {
      try {
        _user = json.decode(userStr);
      } catch (_) {
        _user = null;
      }
    }
  }

  /// Login with MD5-hashed password (hex lowercase). Do not send plain password.
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

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', _token!);
      await prefs.setString('user', json.encode(_user));
      if (_apiKey != null) {
        await prefs.setString('apiKey', _apiKey!);
      }
      if (_user?['cityId'] != null) {
        await prefs.setString('selectedCityId', _user?['cityId']);
      }
      return data;
    }

    throw Exception(_parseError(res, 'Login failed'));
  }

  Future<void> logout() async {
    _token = null;
    _apiKey = null;
    _user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('apiKey');
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

  String _parseError(http.Response res, String fallback) {
    try {
      final err = json.decode(res.body);
      final message = err['message'];
      if (message is List) return message.join(', ');
      if (message != null) return message.toString();
    } catch (_) {}
    return '$fallback (${res.statusCode})';
  }

  Future<List<dynamic>> fetchHospitals(String cityId) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/hospitals?cityId=$cityId'),
      headers: _headers(),
    );
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception(_parseError(res, 'Failed to load hospitals'));
  }

  Future<List<dynamic>> fetchEmergencyTypes() async {
    final res = await http.get(
      Uri.parse('$_baseUrl/emergency-types'),
      headers: _headers(),
    );
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception(_parseError(res, 'Failed to load emergency types'));
  }

  Future<List<dynamic>> fetchTriageCodes() async {
    final res = await http.get(
      Uri.parse('$_baseUrl/triage-codes'),
      headers: _headers(),
    );
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception(_parseError(res, 'Failed to load triage codes'));
  }

  Future<List<dynamic>> fetchAmbulances(String cityId) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/ambulances?cityId=$cityId'),
      headers: _headers(),
    );
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception(_parseError(res, 'Failed to load ambulances'));
  }

  /// Assigned ambulance for the logged-in driver (driverId must match in Admin).
  /// Response: { ambulance: {...}, activeTransit: {...}|null }
  Future<Map<String, dynamic>> fetchMyAmbulance() async {
    final res = await http.get(
      Uri.parse('$_baseUrl/ambulances/mine'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      if (data is Map) return Map<String, dynamic>.from(data);
    }
    throw Exception(_parseError(res, 'Failed to load my ambulance'));
  }

  Future<List<dynamic>> fetchActiveTransits(String cityId) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/transits?active=true&cityId=$cityId'),
      headers: _headers(),
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
    final res = await http.post(
      Uri.parse('$_baseUrl/transits'),
      headers: _headers(),
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
    final res = await http.patch(
      Uri.parse('$_baseUrl/transits/$id/start'),
      headers: _headers(),
      body: json.encode({'currentLat': lat, 'currentLng': lng}),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return json.decode(res.body);
    }
    throw Exception(_parseError(res, 'Failed to start transit'));
  }

  Future<Map<String, dynamic>> markArrived(String id) async {
    final res = await http.patch(
      Uri.parse('$_baseUrl/transits/$id/arrived'),
      headers: _headers(),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return json.decode(res.body);
    }
    throw Exception(_parseError(res, 'Failed to mark arrived'));
  }

  Future<Map<String, dynamic>> completeTransit(String id) async {
    final res = await http.patch(
      Uri.parse('$_baseUrl/transits/$id/complete'),
      headers: _headers(),
    );
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

    final res = await http.patch(
      Uri.parse('$_baseUrl/transits/$transitId/eta'),
      headers: _headers(),
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

    final res = await http.patch(
      Uri.parse('$_baseUrl/ambulances/$ambulanceId/gps'),
      headers: _headers(),
      body: json.encode(body),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return json.decode(res.body);
    }
    throw Exception(_parseError(res, 'Failed to post GPS update'));
  }
}
