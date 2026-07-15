import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  String _baseUrl = 'http://localhost:3001/api';
  String? _token;
  Map<String, dynamic>? _user;

  String get baseUrl => _baseUrl;
  String? get token => _token;
  Map<String, dynamic>? get user => _user;

  void setBaseUrl(String url) {
    _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  Future<void> loadSavedAuth() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('token');
    final userStr = prefs.getString('user');
    if (userStr != null) {
      try {
        _user = json.decode(userStr);
      } catch (_) {
        _user = null;
      }
    }
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'email': email, 'password': password}),
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      final data = json.decode(res.body);
      _token = data['accessToken'];
      _user = data['user'];

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', _token!);
      await prefs.setString('user', json.encode(_user));
      if (_user?['cityId'] != null) {
        await prefs.setString('selectedCityId', _user?['cityId']);
      }
      return data;
    } else {
      final err = json.decode(res.body);
      throw Exception(err['message'] ?? 'Login failed');
    }
  }

  Future<void> logout() async {
    _token = null;
    _user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('user');
    await prefs.remove('selectedCityId');
  }

  Map<String, String> _headers() {
    return {
      'Content-Type': 'application/json',
      if (_token != null) 'Authorization': 'Bearer $_token',
    };
  }

  Future<List<dynamic>> fetchHospitals(String cityId) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/hospitals?cityId=$cityId'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      return json.decode(res.body);
    }
    throw Exception('Failed to load hospitals');
  }

  Future<List<dynamic>> fetchEmergencyTypes() async {
    final res = await http.get(
      Uri.parse('$_baseUrl/emergency-types'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      return json.decode(res.body);
    }
    throw Exception('Failed to load emergency types');
  }

  Future<List<dynamic>> fetchTriageCodes() async {
    final res = await http.get(
      Uri.parse('$_baseUrl/triage-codes'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      return json.decode(res.body);
    }
    throw Exception('Failed to load triage codes');
  }

  Future<List<dynamic>> fetchAmbulances(String cityId) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/ambulances?cityId=$cityId'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      return json.decode(res.body);
    }
    throw Exception('Failed to load ambulances');
  }

  Future<List<dynamic>> fetchActiveTransits(String cityId) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/transits?active=true&cityId=$cityId'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      return json.decode(res.body);
    }
    throw Exception('Failed to load transits');
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
        if (paramedicNotes != null) 'paramedicNotes': paramedicNotes,
        'originLat': originLat,
        'originLng': originLng,
        'baselineEtaMinutes': 12,
      }),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return json.decode(res.body);
    }
    final err = json.decode(res.body);
    throw Exception(err['message'] ?? 'Failed to create transit');
  }

  Future<Map<String, dynamic>> startTransit(String id, double lat, double lng) async {
    final res = await http.patch(
      Uri.parse('$_baseUrl/transits/$id/start'),
      headers: _headers(),
      body: json.encode({'currentLat': lat, 'currentLng': lng}),
    );
    if (res.statusCode == 200) {
      return json.decode(res.body);
    }
    throw Exception('Failed to start transit');
  }

  Future<Map<String, dynamic>> completeTransit(String id) async {
    final res = await http.patch(
      Uri.parse('$_baseUrl/transits/$id/complete'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      return json.decode(res.body);
    }
    throw Exception('Failed to complete transit');
  }

  Future<Map<String, dynamic>> markArrived(String id) async {
    final res = await http.patch(
      Uri.parse('$_baseUrl/transits/$id/arrived'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      return json.decode(res.body);
    }
    throw Exception('Failed to mark arrived');
  }

  Future<Map<String, dynamic>> postGpsUpdate(
    String ambulanceId,
    double lat,
    double lng,
    double speed,
  ) async {
    final res = await http.patch(
      Uri.parse('$_baseUrl/ambulances/$ambulanceId/gps'),
      headers: _headers(),
      body: json.encode({
        'latitude': lat,
        'longitude': lng,
        'speed': speed,
      }),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return json.decode(res.body);
    }
    throw Exception('Failed to post GPS update');
  }
}
