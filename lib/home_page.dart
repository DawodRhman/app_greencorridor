import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'api_service.dart';
import 'login_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _green = Color(0xFF16A34A);
  static const _lahoreCenter = LatLng(31.5204, 74.3587);

  final _api = ApiService();
  late MapController _mapController;
  bool _mapReady = false;

  List<dynamic> _hospitals = [];
  List<dynamic> _emergencyTypes = [];
  List<dynamic> _triageCodes = [];
  Map<String, dynamic>? _myAmbulance;
  /// Always from GET /ambulances/mine — never hardcode another unit.
  String? _ambulanceId;
  Map<String, dynamic>? _activeTransit;
  Map<String, dynamic>? _destinationHospital;

  bool _loading = false;
  bool _initializing = true;
  String? _error;
  String? _statusMessage;
  String? _gpsStatus;

  LatLng? _devicePosition;
  LatLng? _previousPosition;
  DateTime? _previousPositionAt;
  double _deviceSpeed = 0; // km/h — always what we report to backend
  double _lastKnownSpeedKmh = 0;
  double? _deviceHeading;
  Timer? _gpsSyncTimer;
  StreamSubscription<Position>? _positionSub;
  bool _gpsBusy = false;
  bool _followDevice = true;
  DateTime? _lastRouteRefresh;

  List<LatLng> _routePoints = [];
  double? _routeDistanceMeters;
  double? _etaMinutes;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _initializeData();
  }

  @override
  void dispose() {
    _gpsSyncTimer?.cancel();
    _positionSub?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  void _safeMoveMap(LatLng target, double zoom) {
    if (!_mapReady || !mounted) return;
    try {
      _mapController.move(target, zoom);
    } catch (_) {
      // Ignore after hot reload until map re-attaches
      _mapReady = false;
    }
  }

  double _currentZoomOr(double fallback) {
    if (!_mapReady) return fallback;
    try {
      return _mapController.camera.zoom;
    } catch (_) {
      _mapReady = false;
      return fallback;
    }
  }

  Future<void> _initializeData() async {
    setState(() {
      _initializing = true;
      _error = null;
    });

    try {
      final cityId = _api.user?['cityId']?.toString();
      if (cityId == null || cityId.isEmpty) {
        throw Exception('No cityId on user. Please log in again.');
      }

      final results = await Future.wait([
        _api.fetchHospitals(cityId),
        _api.fetchEmergencyTypes(),
        _api.fetchTriageCodes(),
        _api.fetchMyAmbulance(),
      ]);

      _hospitals = results[0] as List<dynamic>;
      _emergencyTypes = results[1] as List<dynamic>;
      _triageCodes = results[2] as List<dynamic>;

      final mine = results[3] as Map<String, dynamic>;
      final ambulance = mine['ambulance'];
      if (ambulance is Map) {
        _myAmbulance = Map<String, dynamic>.from(ambulance);
      } else if (mine['id'] != null) {
        _myAmbulance = mine;
      } else {
        _myAmbulance = null;
      }

      _ambulanceId = _myAmbulance?['id']?.toString();
      if (_ambulanceId == null || _ambulanceId!.isEmpty) {
        _myAmbulance = null;
        _error =
            'No ambulance assigned. Admin must set this user as the ambulance Driver.';
      }

      final active = mine['activeTransit'];
      if (active is Map) {
        _activeTransit = Map<String, dynamic>.from(active);
      } else {
        _activeTransit = null;
        try {
          final transits = await _api.fetchActiveTransits(cityId);
          if (_myAmbulance != null) {
            _activeTransit = transits.cast<dynamic>().firstWhere(
              (t) =>
                  t['ambulanceId'] == _myAmbulance!['id'] &&
                  (t['status'] == 'en_route' ||
                      t['status'] == 'pending' ||
                      t['status'] == 'arrived'),
              orElse: () => null,
            );
          }
        } catch (_) {}
      }

      if (_myAmbulance != null) {
        final lastLat = double.tryParse(_myAmbulance!['currentLat']?.toString() ?? '');
        final lastLng = double.tryParse(_myAmbulance!['currentLng']?.toString() ?? '');
        if (lastLat != null && lastLng != null && _devicePosition == null) {
          _devicePosition = LatLng(lastLat, lastLng);
        }
      }

      if (_activeTransit != null) {
        _resolveDestinationHospital();
        await _refreshRouteToHospital(fitOverview: true);
      }

      await _startLiveGpsTracking();
    } catch (e) {
      _error = e.toString().replaceAll('Exception: ', '');
    } finally {
      if (mounted) {
        setState(() => _initializing = false);
      }
    }
  }

  void _resolveDestinationHospital() {
    final hospitalId = _activeTransit?['hospitalId'] ??
        _activeTransit?['hospital']?['id'];
    if (hospitalId == null) {
      if (_activeTransit?['hospital'] is Map) {
        _destinationHospital =
            Map<String, dynamic>.from(_activeTransit!['hospital'] as Map);
      }
      return;
    }
    final match = _hospitals.cast<dynamic>().firstWhere(
      (h) => h['id'] == hospitalId,
      orElse: () => _activeTransit?['hospital'],
    );
    if (match is Map) {
      _destinationHospital = Map<String, dynamic>.from(match);
    }
  }

  Future<bool> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _error = 'Location services are disabled. Enable GPS to share live position.';
      });
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      setState(() {
        _error = 'Location permission is required for live GPS tracking.';
      });
      return false;
    }
    return true;
  }

  Future<void> _startLiveGpsTracking() async {
    final ok = await _ensureLocationPermission();
    if (!ok) return;

    // Immediate GPS ping after login / home load (Admin Lat/Lng only update via this API)
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _applyDevicePosition(pos);
      await _syncGpsToServer(force: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _gpsStatus = 'Waiting for GPS fix…';
        });
      }
    }

    await _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((pos) {
      _applyDevicePosition(pos);
    });

    _gpsSyncTimer?.cancel();
    _gpsSyncTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      // If we still have no fix, try once more before syncing
      if (_devicePosition == null) {
        try {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
          );
          _applyDevicePosition(pos);
        } catch (_) {}
      }
      await _syncGpsToServer(force: true);
      if (_activeTransit != null && _destinationHospital != null) {
        await _refreshRouteToHospital();
      }
    });
  }

  void _applyDevicePosition(Position pos) {
    if (!mounted) return;

    final next = LatLng(pos.latitude, pos.longitude);
    final now = DateTime.now();

    // Geolocator speed is m/s → convert to km/h for Safe City / HQ
    double? gpsSpeedKmh;
    if (!pos.speed.isNaN && pos.speed >= 0) {
      gpsSpeedKmh = pos.speed * 3.6;
    }

    double? derivedSpeedKmh;
    if (_previousPosition != null && _previousPositionAt != null) {
      final elapsedSec =
          now.difference(_previousPositionAt!).inMilliseconds / 1000.0;
      if (elapsedSec >= 0.8) {
        final meters = Geolocator.distanceBetween(
          _previousPosition!.latitude,
          _previousPosition!.longitude,
          next.latitude,
          next.longitude,
        );
        derivedSpeedKmh = (meters / elapsedSec) * 3.6;
      }
    }

    final reported = _resolveSpeedKmh(
      gpsSpeedKmh: gpsSpeedKmh,
      derivedSpeedKmh: derivedSpeedKmh,
    );

    setState(() {
      _previousPosition = _devicePosition ?? next;
      _previousPositionAt = now;
      _devicePosition = next;
      _deviceSpeed = reported;
      if (reported > 1) _lastKnownSpeedKmh = reported;
      _deviceHeading = (pos.heading.isNaN || pos.heading < 0) ? _deviceHeading : pos.heading;
    });

    if (_followDevice) {
      final zoom = _currentZoomOr(15.0);
      _safeMoveMap(_devicePosition!, zoom < 12 ? 15.0 : zoom);
    }
  }

  /// Always return km/h for backend. Prefer GPS speed; else derived; else last known.
  double _resolveSpeedKmh({double? gpsSpeedKmh, double? derivedSpeedKmh}) {
    // Trust GPS when it reports meaningful motion
    if (gpsSpeedKmh != null && gpsSpeedKmh >= 1.5) {
      return double.parse(gpsSpeedKmh.clamp(0, 200).toStringAsFixed(1));
    }
    // Fallback: distance / time between consecutive fixes
    if (derivedSpeedKmh != null && derivedSpeedKmh >= 1.5) {
      return double.parse(derivedSpeedKmh.clamp(0, 200).toStringAsFixed(1));
    }
    // Low GPS/derived reading — treat as stopped only if both agree we're nearly still
    if ((gpsSpeedKmh ?? 0) < 1.0 && (derivedSpeedKmh == null || derivedSpeedKmh < 1.5)) {
      return 0.0;
    }
    // Keep last known while GPS briefly drops to 0 (common on some phones)
    if (_lastKnownSpeedKmh > 1.5) {
      return double.parse(_lastKnownSpeedKmh.toStringAsFixed(1));
    }
    return 0.0;
  }

  /// Speed value always included in telemetry (km/h number).
  double _speedForTelemetry() {
    return double.parse(_deviceSpeed.clamp(0, 200).toStringAsFixed(1));
  }

  Future<void> _syncGpsToServer({bool force = false}) async {
    if (_gpsBusy && !force) return;
    if (_api.isRateLimited) {
      // 429 backoff: skip this cycle; the 15s periodic timer retries naturally.
      if (mounted) {
        setState(() => _gpsStatus = 'GPS paused briefly (rate limit) — retrying soon');
      }
      return;
    }
    if (_ambulanceId == null || _ambulanceId!.isEmpty) {
      if (mounted) {
        setState(() {
          _gpsStatus = 'GPS not sent — no ambulance from /ambulances/mine';
        });
      }
      return;
    }
    if (_devicePosition == null) {
      if (mounted) {
        setState(() => _gpsStatus = 'GPS not sent — no device fix yet');
      }
      return;
    }

    _gpsBusy = true;
    final lat = _devicePosition!.latitude.toDouble();
    final lng = _devicePosition!.longitude.toDouble();
    final speed = _speedForTelemetry(); // always km/h, never omitted
    final heading = _deviceHeading?.toDouble();
    final transitId = _activeTransit?['id']?.toString();

    try {
      // Always PATCH the id returned by /ambulances/mine for this driver.
      final res = await _api.postGpsUpdate(
        _ambulanceId!,
        lat,
        lng,
        speed,
        heading: heading,
        transitId: transitId,
        etaMinutes: (transitId != null && _etaMinutes != null) ? _etaMinutes : null,
      );

      if (!mounted) return;

      if (res['ambulance'] is Map) {
        final updated = Map<String, dynamic>.from(res['ambulance'] as Map);
        setState(() {
          _myAmbulance = {...?_myAmbulance, ...updated};
          if (updated['id'] != null) {
            _ambulanceId = updated['id'].toString();
          }
          _gpsStatus =
              'Admin sync OK · ${_myAmbulance?['unitNumber'] ?? _ambulanceId} · ${speed.toStringAsFixed(0)} km/h · ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
          _error = null;
        });
      } else {
        setState(() {
          _gpsStatus = 'Admin sync OK · $_ambulanceId · ${speed.toStringAsFixed(0)} km/h';
        });
      }

      final transit = res['transit'];
      if (transit is Map) {
        final status = transit['status']?.toString();
        if (status == 'completed') {
          setState(() {
            _statusMessage = 'Corridor completed.';
            _activeTransit = null;
            _destinationHospital = null;
            _routePoints = [];
            _routeDistanceMeters = null;
            _etaMinutes = null;
          });
        } else {
          setState(() {
            _activeTransit = Map<String, dynamic>.from(transit);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _gpsStatus = 'GPS sync failed: ${e.toString().replaceAll('Exception: ', '')}';
        });
      }
    } finally {
      _gpsBusy = false;
    }
  }

  Future<({List<LatLng> points, double? distanceM, double? durationS})> _fetchShortestRoute(
    LatLng from,
    LatLng to,
  ) async {
    try {
      final url =
          'https://router.project-osrm.org/route/v1/driving/${from.longitude},${from.latitude};${to.longitude},${to.latitude}?overview=full&geometries=geojson';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['code'] == 'Ok' && data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0] as Map<String, dynamic>;
          final coords = route['geometry']['coordinates'] as List<dynamic>;
          final points = coords
              .map<LatLng>((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
              .toList();
          return (
            points: points,
            distanceM: (route['distance'] as num?)?.toDouble(),
            durationS: (route['duration'] as num?)?.toDouble(),
          );
        }
      }
    } catch (_) {}
    return (points: [from, to], distanceM: null, durationS: null);
  }

  LatLng? _hospitalLatLng(Map<String, dynamic>? hospital) {
    if (hospital == null) return null;
    final lat = double.tryParse(hospital['latitude']?.toString() ?? '');
    final lng = double.tryParse(hospital['longitude']?.toString() ?? '');
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  String _formatEta(double? minutes) {
    if (minutes == null || minutes.isNaN) return '—';
    final m = minutes.round().clamp(0, 9999);
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final rem = m % 60;
    return '${h}h ${rem}m';
  }

  String _formatDistance(double? meters) {
    if (meters == null || meters.isNaN) return '—';
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  /// Prefer OSRM road ETA; optionally blend with live ambulance speed if moving.
  double? _computeDisplayEtaMinutes({
    required double? osrmDurationSeconds,
    required double? distanceMeters,
  }) {
    double? osrmMin;
    if (osrmDurationSeconds != null && osrmDurationSeconds > 0) {
      osrmMin = osrmDurationSeconds / 60.0;
    }

    // If ambulance is moving meaningfully, also estimate from remaining distance / speed
    double? speedMin;
    if (distanceMeters != null && distanceMeters > 0 && _deviceSpeed >= 8) {
      speedMin = (distanceMeters / 1000.0) / _deviceSpeed * 60.0;
    }

    if (osrmMin != null && speedMin != null) {
      // Weight toward live speed when corridor is active and vehicle is moving
      return (osrmMin * 0.4) + (speedMin * 0.6);
    }
    return osrmMin ?? speedMin;
  }

  Future<void> _refreshRouteToHospital({bool fitOverview = false}) async {
    final dest = _hospitalLatLng(_destinationHospital);
    final from = _devicePosition ??
        (_myAmbulance != null
            ? LatLng(
                double.tryParse(_myAmbulance!['currentLat']?.toString() ?? '') ??
                    _lahoreCenter.latitude,
                double.tryParse(_myAmbulance!['currentLng']?.toString() ?? '') ??
                    _lahoreCenter.longitude,
              )
            : null);
    if (from == null || dest == null) return;

    final now = DateTime.now();
    if (!fitOverview &&
        _lastRouteRefresh != null &&
        now.difference(_lastRouteRefresh!) < const Duration(seconds: 12)) {
      return;
    }
    _lastRouteRefresh = now;

    final result = await _fetchShortestRoute(from, dest);
    if (!mounted) return;

    final backendEta = double.tryParse(_activeTransit?['etaMinutes']?.toString() ?? '');
    final displayEta = _computeDisplayEtaMinutes(
          osrmDurationSeconds: result.durationS,
          distanceMeters: result.distanceM,
        ) ??
        backendEta;

    setState(() {
      _routePoints = result.points;
      _routeDistanceMeters = result.distanceM;
      _etaMinutes = displayEta;
    });

    if (fitOverview && result.points.isNotEmpty) {
      _followDevice = false;
      _fitRoute(from, dest);
    }

    // Push the same ETA the driver sees to HQ / Hospital / Safe City
    if (displayEta != null) {
      await _pushEtaToBackend(displayEta);
    }
  }

  Future<void> _pushEtaToBackend(double etaMinutes) async {
    // 429 backoff: skip this push; the next GPS cycle sends a fresh ETA.
    if (_api.isRateLimited) return;
    final transitId = _activeTransit?['id']?.toString();
    if (transitId == null || transitId.isEmpty) return;

    final status = _activeTransit?['status']?.toString();
    if (status != null &&
        status != 'pending' &&
        status != 'en_route' &&
        status != 'arrived') {
      return;
    }

    try {
      final speed = _speedForTelemetry();
      final updated = await _api.updateTransitEta(
        transitId: transitId,
        etaMinutes: double.parse(etaMinutes.toStringAsFixed(1)),
        currentLat: _devicePosition?.latitude,
        currentLng: _devicePosition?.longitude,
        currentSpeed: speed, // always km/h so Safe City card is not stuck at 0
      );
      if (!mounted) return;
      setState(() {
        _activeTransit = {...?_activeTransit, ...updated};
        final serverEta = double.tryParse(updated['etaMinutes']?.toString() ?? '');
        if (serverEta != null) _etaMinutes = serverEta;
      });
    } catch (_) {
      // Don't block navigation if ETA sync fails; GPS loop will retry
    }
  }

  void _fitRoute(LatLng from, LatLng to) {
    final midLat = (from.latitude + to.latitude) / 2;
    final midLng = (from.longitude + to.longitude) / 2;
    final latDiff = (from.latitude - to.latitude).abs();
    final lngDiff = (from.longitude - to.longitude).abs();
    final maxDiff = latDiff > lngDiff ? latDiff : lngDiff;
    double zoom = 13.0;
    if (maxDiff > 0.15) {
      zoom = 11.0;
    } else if (maxDiff > 0.07) {
      zoom = 12.0;
    } else if (maxDiff < 0.01) {
      zoom = 14.5;
    }
    _safeMoveMap(LatLng(midLat, midLng), zoom);
  }

  Future<void> _openRequestForm() async {
    if (_ambulanceId == null || _myAmbulance == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No ambulance assigned. Ask Admin to set your driverId.'),
        ),
      );
      return;
    }
    if (_activeTransit != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Finish the active corridor before starting another.')),
      );
      return;
    }

    String? hospitalId;
    String? triageId;
    String? emergencyId;
    List<Map<String, dynamic>> suitableHospitals = [];
    String? recommendedHospitalId;
    var loadingHospitals = false;
    var noHospitals = false;
    final notesController = TextEditingController();
    var submitting = false;
    String? formError;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;

            Future<void> loadSuitableHospitals(String forEmergencyId) async {
              final cityId = (_myAmbulance?['cityId'] ?? _api.user?['cityId'])?.toString();
              final origin = _devicePosition ??
                  LatLng(
                    double.tryParse(_myAmbulance?['currentLat']?.toString() ?? '') ??
                        _lahoreCenter.latitude,
                    double.tryParse(_myAmbulance?['currentLng']?.toString() ?? '') ??
                        _lahoreCenter.longitude,
                  );
              try {
                final data = await _api.fetchSuitableHospitals(
                  cityId: cityId ?? '',
                  emergencyTypeId: forEmergencyId,
                  latitude: origin.latitude,
                  longitude: origin.longitude,
                );
                // Ignore stale responses if the user changed emergency type again
                if (emergencyId != forEmergencyId) return;

                // Keep server order unchanged: it is already nearest-to-farthest
                final list = (data['hospitals'] as List? ?? [])
                    .whereType<Map>()
                    .map((h) => Map<String, dynamic>.from(h))
                    .toList();
                final recommendedId = data['recommendedHospitalId']?.toString();

                setSheetState(() {
                  loadingHospitals = false;
                  suitableHospitals = list;
                  recommendedHospitalId = recommendedId;
                  noHospitals = list.isEmpty;
                  if (list.isEmpty) {
                    hospitalId = null;
                  } else if (list.length == 1) {
                    hospitalId = list.first['id']?.toString();
                  } else {
                    hospitalId = list.any((h) => h['id']?.toString() == recommendedId)
                        ? recommendedId
                        : list.first['id']?.toString();
                  }
                });
              } catch (e) {
                if (emergencyId != forEmergencyId) return;
                setSheetState(() {
                  loadingHospitals = false;
                  suitableHospitals = [];
                  recommendedHospitalId = null;
                  noHospitals = false;
                  formError = e.toString().replaceAll('Exception: ', '');
                });
              }
            }
            return Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomInset),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Request Green Corridor',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: _green,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Select emergency type, hospital, and triage code.',
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 20),
                    DropdownButtonFormField<String>(
                      value: emergencyId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Emergency type',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.medical_services, color: _green),
                      ),
                      items: _emergencyTypes.map<DropdownMenuItem<String>>((e) {
                        return DropdownMenuItem<String>(
                          value: e['id']?.toString(),
                          child: Text(
                            e['name']?.toString() ?? 'Emergency',
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: submitting
                          ? null
                          : (v) {
                              // Clear old hospital before loading the new list
                              setSheetState(() {
                                emergencyId = v;
                                hospitalId = null;
                                suitableHospitals = [];
                                recommendedHospitalId = null;
                                noHospitals = false;
                                formError = null;
                                loadingHospitals = v != null;
                              });
                              if (v != null) loadSuitableHospitals(v);
                            },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: hospitalId,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: loadingHospitals ? 'Loading hospitals…' : 'Hospital',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.local_hospital, color: _green),
                      ),
                      items: suitableHospitals.map<DropdownMenuItem<String>>((h) {
                        final id = h['id']?.toString();
                        final distance = double.tryParse(h['distanceKm']?.toString() ?? '');
                        final name = h['name']?.toString() ?? 'Hospital';
                        final isRecommended = id != null && id == recommendedHospitalId;
                        final caters = h['catersSelectedEmergency'] == true;

                        Widget badge(String label, Color color) => Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: color,
                                ),
                              ),
                            );

                        return DropdownMenuItem<String>(
                          value: id,
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  distance != null
                                      ? '$name · ${distance.toStringAsFixed(1)} km'
                                      : name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isRecommended) badge('Recommended', _green),
                              if (caters) badge('Caters this emergency', Colors.blue.shade700),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (submitting || loadingHospitals || suitableHospitals.isEmpty)
                          ? null
                          : (v) => setSheetState(() => hospitalId = v),
                    ),
                    if (noHospitals) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'No hospital caters this emergency type in the selected city.',
                        style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: triageId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Triage code',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.flag, color: _green),
                      ),
                      items: _triageCodes.map<DropdownMenuItem<String>>((t) {
                        return DropdownMenuItem<String>(
                          value: t['id']?.toString(),
                          child: Text(t['name']?.toString() ?? 'Triage'),
                        );
                      }).toList(),
                      onChanged: submitting
                          ? null
                          : (v) => setSheetState(() => triageId = v),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: notesController,
                      enabled: !submitting,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optional)',
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                        prefixIcon: Icon(Icons.notes, color: _green),
                      ),
                    ),
                    if (formError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        formError!,
                        style: const TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: (submitting || loadingHospitals || noHospitals)
                          ? null
                          : () async {
                              if (emergencyId == null ||
                                  hospitalId == null ||
                                  triageId == null) {
                                setSheetState(() {
                                  formError = 'Please select emergency type, hospital, and triage code.';
                                });
                                return;
                              }

                              final hospital = suitableHospitals.firstWhere(
                                (h) => h['id']?.toString() == hospitalId,
                                orElse: () => <String, dynamic>{},
                              );
                              if (hospital.isEmpty) {
                                setSheetState(() {
                                  formError = 'Please select a hospital from the list.';
                                });
                                return;
                              }

                              setSheetState(() {
                                submitting = true;
                                formError = null;
                              });

                              try {
                                await _submitCorridorRequest(
                                  hospital: hospital,
                                  triageId: triageId!,
                                  emergencyId: emergencyId!,
                                  notes: notesController.text.trim(),
                                );
                                if (ctx.mounted) Navigator.of(ctx).pop();
                              } catch (e) {
                                setSheetState(() {
                                  submitting = false;
                                  formError =
                                      e.toString().replaceAll('Exception: ', '');
                                });
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: submitting
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Send Request',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    // The sheet's closing animation still rebuilds the TextField for a few
    // frames after the future completes, so defer disposal until it's done.
    Future<void>.delayed(const Duration(seconds: 1), notesController.dispose);
  }

  Future<void> _submitCorridorRequest({
    required Map<String, dynamic> hospital,
    required String triageId,
    required String emergencyId,
    required String notes,
  }) async {
    final origin = _devicePosition ??
        LatLng(
          double.tryParse(_myAmbulance?['currentLat']?.toString() ?? '') ??
              _lahoreCenter.latitude,
          double.tryParse(_myAmbulance?['currentLng']?.toString() ?? '') ??
              _lahoreCenter.longitude,
        );

    final transit = await _api.createTransit(
      ambulanceId: _ambulanceId!,
      hospitalId: hospital['id'].toString(),
      emergencyTypeId: emergencyId,
      triageCodeId: triageId,
      sectorId: hospital['sectorId']?.toString(),
      paramedicNotes: notes.isEmpty ? null : notes,
      originLat: origin.latitude,
      originLng: origin.longitude,
      baselineEtaMinutes: 12,
    );

    final started = await _api.startTransit(
      transit['id'],
      origin.latitude,
      origin.longitude,
    );

    setState(() {
      _activeTransit = started;
      // Prefer the hospital echoed back by the backend (source of truth)
      final serverHospital = started['hospital'] ?? transit['hospital'];
      _destinationHospital = serverHospital is Map
          ? Map<String, dynamic>.from(serverHospital)
          : hospital;
      _statusMessage = 'Green Corridor LIVE — shortest path drawn.';
      _error = null;
    });

    // Compute OSRM ETA → PATCH /transits/{id}/eta immediately, then GPS ping
    await _refreshRouteToHospital(fitOverview: true);
    await _syncGpsToServer(force: true);
  }

  Future<void> _handleArrived() async {
    if (_activeTransit == null) return;
    setState(() => _loading = true);
    try {
      final res = await _api.markArrived(_activeTransit!['id']);
      setState(() {
        _activeTransit = res;
        _statusMessage = 'Arrived reported to hospital.';
      });
    } catch (e) {
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _handleComplete() async {
    if (_activeTransit == null) return;
    setState(() => _loading = true);
    try {
      await _api.completeTransit(_activeTransit!['id']);
      setState(() {
        _activeTransit = null;
        _destinationHospital = null;
        _routePoints = [];
        _routeDistanceMeters = null;
        _etaMinutes = null;
        _followDevice = true;
        _statusMessage = 'Trip complete. Ambulance available.';
      });
      await _syncGpsToServer(force: true);
    } catch (e) {
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _handleLogout() async {
    _gpsSyncTimer?.cancel();
    await _positionSub?.cancel();
    await _api.logout();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: _green)),
      );
    }

    final mapCenter = _devicePosition ??
        (_myAmbulance != null
            ? LatLng(
                double.tryParse(_myAmbulance!['currentLat']?.toString() ?? '') ??
                    _lahoreCenter.latitude,
                double.tryParse(_myAmbulance!['currentLng']?.toString() ?? '') ??
                    _lahoreCenter.longitude,
              )
            : _lahoreCenter);

    final hospitalPoint = _hospitalLatLng(_destinationHospital);
    final markers = <Marker>[
      Marker(
        point: mapCenter,
        width: 52,
        height: 52,
        child: Container(
          decoration: BoxDecoration(
            color: _green,
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 3)),
            ],
          ),
          child: const Icon(Icons.local_shipping, color: Colors.white, size: 26),
        ),
      ),
    ];

    if (hospitalPoint != null) {
      markers.add(
        Marker(
          point: hospitalPoint,
          width: 56,
          height: 56,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: _green, width: 3),
              boxShadow: const [
                BoxShadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 3)),
              ],
            ),
            child: const Icon(Icons.local_hospital, color: _green, size: 28),
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: mapCenter,
              initialZoom: 14.5,
              onMapReady: () {
                _mapReady = true;
              },
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture) _followDevice = false;
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'pk.gchq.paramedic_app',
              ),
              if (_routePoints.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      strokeWidth: 5,
                      color: _green,
                    ),
                  ],
                ),
              MarkerLayer(markers: markers),
            ],
          ),

          // Top bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Material(
                      elevation: 3,
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _myAmbulance?['unitNumber']?.toString() ?? 'No unit assigned',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _green,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              _api.user?['name']?.toString() ?? '',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                            if (_gpsStatus != null)
                              Text(
                                _gpsStatus!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: _gpsStatus!.contains('failed') ||
                                          _gpsStatus!.contains('not sent')
                                      ? Colors.red.shade700
                                      : Colors.grey.shade700,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    elevation: 3,
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    child: IconButton(
                      tooltip: 'Recenter',
                      icon: const Icon(Icons.my_location, color: _green),
                      onPressed: () {
                        if (_devicePosition != null) {
                          setState(() => _followDevice = true);
                          _safeMoveMap(_devicePosition!, 15.5);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    elevation: 3,
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    child: IconButton(
                      tooltip: 'Logout',
                      icon: const Icon(Icons.logout, color: _green),
                      onPressed: _handleLogout,
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (_activeTransit != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 72,
              left: 12,
              right: 12,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(14),
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: _green,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text(
                              'LIVE',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _activeTransit?['transitId']?.toString() ??
                                  _activeTransit?['id']?.toString() ??
                                  'Corridor active',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          Text(
                            (_activeTransit?['status'] ?? '').toString().toUpperCase(),
                            style: const TextStyle(
                              color: _green,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Destination: ${_destinationHospital?['name'] ?? 'Hospital'}',
                        style: TextStyle(color: Colors.grey.shade800, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _InfoChip(
                              icon: Icons.schedule,
                              label: 'ETA',
                              value: _formatEta(_etaMinutes),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _InfoChip(
                              icon: Icons.straighten,
                              label: 'Distance',
                              value: _formatDistance(_routeDistanceMeters),
                            ),
                          ),
                        ],
                      ),
                      if (_statusMessage != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _statusMessage!,
                          style: const TextStyle(color: _green, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          if (_activeTransit?['status'] == 'en_route')
                            Expanded(
                              child: ElevatedButton(
                                onPressed: _loading ? null : _handleArrived,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _green,
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text('Arrived'),
                              ),
                            ),
                          if (_activeTransit?['status'] == 'en_route')
                            const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _loading ? null : _handleComplete,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _green,
                                side: const BorderSide(color: _green),
                              ),
                              child: const Text('Complete'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_error != null)
            Positioned(
              bottom: _activeTransit == null ? 100 : 24,
              left: 16,
              right: 80,
              child: Material(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Colors.red.shade800,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),

          // Bottom-right + FAB to open request form
          if (_activeTransit == null)
            Positioned(
              right: 20,
              bottom: 28,
              child: SafeArea(
                child: FloatingActionButton(
                  onPressed: _loading ? null : _openRequestForm,
                  backgroundColor: _green,
                  foregroundColor: Colors.white,
                  tooltip: 'Request green corridor',
                  child: const Icon(Icons.add, size: 32),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: const Color(0xFF16A34A)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF16A34A),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
