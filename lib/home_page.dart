import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'api_service.dart';
import 'login_page.dart';


class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _api = ApiService();
  final _mapController = MapController();

  List<dynamic> _hospitals = [];
  List<dynamic> _emergencyTypes = [];
  List<dynamic> _triageCodes = [];
  Map<String, dynamic>? _myAmbulance;
  Map<String, dynamic>? _activeTransit;

  String? _selectedHospitalId;
  String? _selectedEmergencyTypeId;
  String? _selectedTriageCodeId;
  final PageController _pageController = PageController();
  final TextEditingController _searchController = TextEditingController();
  int _currentStep = 0;
  String _globalSearchQuery = '';
  bool _isExpanded = false;

  bool _loading = false;
  bool _initializing = true;
  String? _error;
  String? _statusMessage;

  // Simulation parameters
  List<LatLng> _routePoints = [];
  List<LatLng> _previewRoutePoints = [];
  double _progress = 0.0;
  Timer? _simulationTimer;
  bool _simBusy = false;
  bool _showingOverview = false;

  final LatLng _lahoreCenter = const LatLng(31.5204, 74.3587);

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  @override
  void dispose() {
    _simulationTimer?.cancel();
    _pageController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchPreviewRoute() async {
    if (_selectedHospitalId == null || _myAmbulance == null) return;
    final hospital = _hospitals.firstWhere(
      (h) => h['id'] == _selectedHospitalId,
      orElse: () => null,
    );
    if (hospital == null) return;
    final startLat = double.tryParse(_myAmbulance?['currentLat']?.toString() ?? '') ?? _lahoreCenter.latitude;
    final startLng = double.tryParse(_myAmbulance?['currentLng']?.toString() ?? '') ?? _lahoreCenter.longitude;
    final destLat = double.tryParse(hospital['latitude']?.toString() ?? '') ?? _lahoreCenter.latitude;
    final destLng = double.tryParse(hospital['longitude']?.toString() ?? '') ?? _lahoreCenter.longitude;
    final pts = await _fetchLiveRoute(LatLng(startLat, startLng), LatLng(destLat, destLng));
    if (mounted) {
      setState(() {
        _previewRoutePoints = pts;
      });
    }
  }

  Future<void> _initializeData() async {
    setState(() {
      _initializing = true;
      _error = null;
    });

    try {
      final cityId = _api.user?['cityId'] ?? 'LHE';
      final h = await _api.fetchHospitals(cityId);
      final et = await _api.fetchEmergencyTypes();
      final tc = await _api.fetchTriageCodes();
      final ambulances = await _api.fetchAmbulances(cityId);
      final transits = await _api.fetchActiveTransits(cityId);

      _hospitals = h;
      _emergencyTypes = et;
      _triageCodes = tc;

      _myAmbulance = ambulances.firstWhere(
        (a) => a['driverId'] == _api.user?['id'],
        orElse: () => ambulances.firstWhere(
          (a) => a['status'] == 'available',
          orElse: () => ambulances.isNotEmpty ? ambulances.first : null,
        ),
      );

      if (_myAmbulance != null) {
        _activeTransit = transits.firstWhere(
          (t) =>
              t['ambulanceId'] == _myAmbulance?['id'] &&
              (t['status'] == 'en_route' ||
                  t['status'] == 'pending' ||
                  t['status'] == 'arrived'),
          orElse: () => null,
        );

        if (_activeTransit != null) {
          await _loadActiveRoute();
        }
      }
    } catch (e) {
      _error = e.toString().replaceAll('Exception: ', '');
    } finally {
      setState(() {
        _initializing = false;
      });
    }
  }

  Future<List<LatLng>> _fetchLiveRoute(LatLng from, LatLng to) async {
    try {
      final url = 'https://router.project-osrm.org/route/v1/driving/${from.longitude},${from.latitude};${to.longitude},${to.latitude}?overview=full&geometries=geojson';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['code'] == 'Ok' && data['routes'] != null && data['routes'].isNotEmpty) {
          final coords = data['routes'][0]['geometry']['coordinates'] as List<dynamic>;
          return coords.map<LatLng>((c) => LatLng(c[1] as double, c[0] as double)).toList();
        }
      }
    } catch (e) {
      print('OSRM routing failed: $e');
    }
    // Fallback to local Bezier generator
    return _buildDemoRoute(from, to);
  }

  Future<void> _loadActiveRoute({bool showOverview = false}) async {
    final startLat = double.tryParse(_activeTransit?['currentLat']?.toString() ?? '') ??
        double.tryParse(_activeTransit?['originLat']?.toString() ?? '') ??
        double.tryParse(_myAmbulance?['currentLat']?.toString() ?? '') ??
        _lahoreCenter.latitude;
    final startLng = double.tryParse(_activeTransit?['currentLng']?.toString() ?? '') ??
        double.tryParse(_activeTransit?['originLng']?.toString() ?? '') ??
        double.tryParse(_myAmbulance?['currentLng']?.toString() ?? '') ??
        _lahoreCenter.longitude;

    final destLat = double.tryParse(_activeTransit?['hospital']?['latitude']?.toString() ?? '') ??
        _lahoreCenter.latitude;
    final destLng = double.tryParse(_activeTransit?['hospital']?['longitude']?.toString() ?? '') ??
        _lahoreCenter.longitude;

    final from = LatLng(startLat, startLng);
    final to = LatLng(destLat, destLng);
    final pts = await _fetchLiveRoute(from, to);
    setState(() {
      _routePoints = pts;
      _progress = 0.0;
    });

    if (showOverview) {
      setState(() {
        _showingOverview = true;
      });
      _animateToOverview(from, to);
    } else if (_activeTransit?['status'] == 'en_route') {
      _startGpsSimulation();
    }
  }

  void _animateToOverview(LatLng from, LatLng to) {
    final midLat = (from.latitude + to.latitude) / 2;
    final midLng = (from.longitude + to.longitude) / 2;
    final latDiff = (from.latitude - to.latitude).abs();
    final lngDiff = (from.longitude - to.longitude).abs();
    final maxDiff = latDiff > lngDiff ? latDiff : lngDiff;
    double zoom = 13.0;
    if (maxDiff > 0.15) zoom = 11.0;
    else if (maxDiff > 0.07) zoom = 12.0;
    else if (maxDiff < 0.01) zoom = 14.5;
    _mapController.move(LatLng(midLat, midLng), zoom);
  }

  void _beginNavigation() {
    setState(() {
      _showingOverview = false;
    });
    // Zoom back in to ambulance position
    if (_routePoints.isNotEmpty) {
      _mapController.move(_routePoints.first, 15.5);
    }
    _startGpsSimulation();
  }

  List<LatLng> _buildDemoRoute(LatLng from, LatLng to, {int steps = 24}) {
    final List<LatLng> points = [];
    final double midLat = (from.latitude + to.latitude) / 2 + (to.longitude - from.longitude) * 0.15;
    final double midLng = (from.longitude + to.longitude) / 2 - (to.latitude - from.latitude) * 0.15;

    for (int i = 0; i <= steps; i++) {
      final double t = i / steps;
      final double lat = (1 - t) * (1 - t) * from.latitude + 2 * (1 - t) * t * midLat + t * t * to.latitude;
      final double lng = (1 - t) * (1 - t) * from.longitude + 2 * (1 - t) * t * midLng + t * t * to.longitude;
      points.add(LatLng(lat, lng));
    }
    return points;
  }

  LatLng _interpolateRouteProgress(List<LatLng> route, double progress) {
    if (route.isEmpty) return const LatLng(0, 0);
    if (progress <= 0) return route.first;
    if (progress >= 1) return route.last;
    final double idx = progress * (route.length - 1);
    final int i = idx.floor();
    final double f = idx - i;
    final LatLng a = route[i];
    final LatLng b = route[(i + 1).clamp(0, route.length - 1)];
    return LatLng(a.latitude + (b.latitude - a.latitude) * f, a.longitude + (b.longitude - a.longitude) * f);
  }

  void _startGpsSimulation() {
    _simulationTimer?.cancel();
    _simulationTimer = Timer.periodic(const Duration(milliseconds: 2500), (timer) async {
      if (_simBusy || _activeTransit == null || _myAmbulance == null || _routePoints.length < 2) return;

      _simBusy = true;
      final nextProgress = (_progress + 0.04).clamp(0.0, 1.0);
      final nextCoords = _interpolateRouteProgress(_routePoints, nextProgress);

      try {
        final res = await _api.postGpsUpdate(
          _myAmbulance!['id'],
          nextCoords.latitude,
          nextCoords.longitude,
          38.0,
        );

        if (res['transit']?['status'] == 'completed') {
          timer.cancel();
          setState(() {
            _statusMessage = 'Destination hospital entered (geofence). Corridor completed.';
            _activeTransit = null;
            _routePoints = [];
            _progress = 0.0;
          });
          _initializeData();
        } else {
          setState(() {
            _progress = nextProgress;
            if (res['transit'] != null) {
              _activeTransit = res['transit'];
            }
          });
        }
      } catch (_) {
        // Continue simulation on network blips
      } finally {
        _simBusy = false;
      }
    });
  }

  Future<void> _handleStartTransit() async {
    if (_myAmbulance == null ||
        _selectedHospitalId == null ||
        _selectedEmergencyTypeId == null ||
        _selectedTriageCodeId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete all selection fields first.')),
      );
      return;
    }

    setState(() {
      _loading = true;
      _statusMessage = null;
    });

    try {
      final selectedHospital = _hospitals.firstWhere((h) => h['id'] == _selectedHospitalId);
      final startLat = double.tryParse(_myAmbulance?['currentLat']?.toString() ?? '') ?? _lahoreCenter.latitude + 0.01;
      final startLng = double.tryParse(_myAmbulance?['currentLng']?.toString() ?? '') ?? _lahoreCenter.longitude - 0.01;

      final transit = await _api.createTransit(
        ambulanceId: _myAmbulance!['id'],
        hospitalId: _selectedHospitalId!,
        emergencyTypeId: _selectedEmergencyTypeId!,
        triageCodeId: _selectedTriageCodeId!,
        sectorId: selectedHospital['sectorId'],
        paramedicNotes: null,
        originLat: startLat,
        originLng: startLng,
      );

      final started = await _api.startTransit(transit['id'], startLat, startLng);

      setState(() {
        _activeTransit = started;
        _previewRoutePoints = [];
        _statusMessage = 'Green Corridor LIVE — GPS updates started.';
      });
      await _loadActiveRoute(showOverview: true);
    } catch (e) {
      _error = e.toString().replaceAll('Exception: ', '');
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _handleArrived() async {
    if (_activeTransit == null) return;
    setState(() => _loading = true);
    try {
      final res = await _api.markArrived(_activeTransit!['id']);
      setState(() {
        _activeTransit = res;
        _statusMessage = 'Arrived status reported to hospital ER.';
      });
    } catch (e) {
      _error = e.toString().replaceAll('Exception: ', '');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _handleComplete() async {
    if (_activeTransit == null) return;
    setState(() => _loading = true);
    try {
      await _api.completeTransit(_activeTransit!['id']);
      _simulationTimer?.cancel();
      setState(() {
        _activeTransit = null;
        _routePoints = [];
        _previewRoutePoints = [];
        _showingOverview = false;
        _progress = 0.0;
        _selectedHospitalId = null;
        _selectedEmergencyTypeId = null;
        _selectedTriageCodeId = null;
        _currentStep = 0;
        _globalSearchQuery = '';
        _isExpanded = false;
        _statusMessage = 'Green Corridor complete. Ambulance available.';
      });
      _searchController.clear();
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
      _initializeData();
    } catch (e) {
      _error = e.toString().replaceAll('Exception: ', '');
    } finally {
      setState(() => _loading = false);
    }
  }



  void _handleLogout() async {
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
        body: Center(child: CircularProgressIndicator(color: const Color(0xFF16A34A))),
      );
    }


    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final isTablet = size.width > 720;

    LatLng mapCenter = _lahoreCenter;
    if (_routePoints.isNotEmpty) {
      mapCenter = _interpolateRouteProgress(_routePoints, _progress);
    } else if (_myAmbulance != null) {
      final lat = double.tryParse(_myAmbulance?['currentLat']?.toString() ?? '') ?? _lahoreCenter.latitude;
      final lng = double.tryParse(_myAmbulance?['currentLng']?.toString() ?? '') ?? _lahoreCenter.longitude;
      mapCenter = LatLng(lat, lng);
    }

    // Build map marker objects
    final List<Marker> markers = [];
    if (_myAmbulance != null) {
      markers.add(
        Marker(
          point: mapCenter,
          width: 52,
          height: 52,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF16A34A),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 3))
              ],
            ),
            child: const Icon(Icons.local_shipping, color: Colors.white, size: 26),
          ),
        ),
      );
    }

    if (_activeTransit != null) {
      final destLat = double.tryParse(_activeTransit?['hospital']?['latitude']?.toString() ?? '') ?? _lahoreCenter.latitude;
      final destLng = double.tryParse(_activeTransit?['hospital']?['longitude']?.toString() ?? '') ?? _lahoreCenter.longitude;
      markers.add(
        Marker(
          point: LatLng(destLat, destLng),
          width: 72,
          height: 84,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF16A34A), width: 3),
                  boxShadow: const [
                    BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))
                  ],
                ),
                child: const Icon(Icons.local_hospital, color: const Color(0xFF16A34A), size: 32),
              ),
              const SizedBox(height: 2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF16A34A),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _activeTransit?['hospital']?['name']?.toString().split(' ').take(2).join(' ') ?? 'Hospital',
                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget controlPanel = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragUpdate: (details) {
              if (details.primaryDelta! < -5) {
                setState(() {
                  _isExpanded = true;
                });
              } else if (details.primaryDelta! > 5) {
                setState(() {
                  _isExpanded = false;
                });
              }
            },
            child: Column(
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
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _myAmbulance?['unitNumber'] ?? 'Ambulance Unit',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF16A34A),
                          ),
                        ),
                        Text(
                          _api.user?['name'] ?? '',
                          style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.logout, color: const Color(0xFF16A34A)),
                      onPressed: _handleLogout,
                    ),
                  ],
                ),
              ],
            ),
          ),
            const SizedBox(height: 4),
            if (_statusMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Text(
                  _statusMessage!,
                  style: const TextStyle(
                    color: const Color(0xFF16A34A),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 4),
            ],
            if (_activeTransit == null) ...[
              Row(
                children: [
                  if (_currentStep > 0)
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: const Color(0xFF16A34A), size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        _pageController.previousPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      },
                    ),
                  if (_currentStep > 0) const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Step ${_currentStep + 1} of 4: ' +
                          (_currentStep == 0
                              ? 'Triage Code'
                              : _currentStep == 1
                                  ? 'Medical Issue'
                                  : _currentStep == 2
                                      ? 'Destination Hospital'
                                      : 'Confirm & Depart'),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: const Color(0xFF16A34A),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                      color: const Color(0xFF16A34A),
                      size: 20,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () {
                      setState(() {
                        _isExpanded = !_isExpanded;
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: (_currentStep + 1) / 4.0,
                backgroundColor: Colors.grey.shade200,
                color: const Color(0xFF16A34A),
              ),
              const SizedBox(height: 8),
              if (_currentStep < 3) ...[
                SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(fontSize: 12, color: const Color(0xFF16A34A)),
                    decoration: InputDecoration(
                      hintText: 'Search...',
                      hintStyle: TextStyle(color: Colors.grey.shade500),
                      prefixIcon: const Icon(Icons.search, size: 16, color: const Color(0xFF16A34A)),
                      isDense: true,
                      fillColor: Colors.grey.shade100,
                      filled: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: _globalSearchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 14, color: const Color(0xFF16A34A)),
                              onPressed: () {
                                setState(() {
                                  _globalSearchQuery = '';
                                  _searchController.clear();
                                });
                              },
                            )
                          : null,
                    ),
                    onChanged: (val) {
                      setState(() {
                        _globalSearchQuery = val;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Expanded(
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (val) {
                    setState(() {
                      _currentStep = val;
                    });
                  },
                  children: [
                    _buildTriagePage(),
                    _buildIssuePage(),
                    _buildHospitalPage(),
                    _buildConfirmPage(theme),
                  ],
                ),
              ),
            ] else ...[
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Corridor Active: ${_activeTransit!['transitId']}',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: const Color(0xFF16A34A)),
                            ),
                            const SizedBox(height: 6),
                            Text('Issue: ${_activeTransit!['emergencyType']['name']}', style: const TextStyle(color: const Color(0xFF16A34A))),
                            Text('Triage: ${_activeTransit!['triageCode']['name']}', style: const TextStyle(color: const Color(0xFF16A34A))),
                            Text('Destination: ${_activeTransit!['hospital']['name']}', style: const TextStyle(color: const Color(0xFF16A34A))),
                            const SizedBox(height: 6),
                            Text(
                              'Status: ${_activeTransit!['status'].toString().toUpperCase()}',
                              style: const TextStyle(fontWeight: FontWeight.bold, color: const Color(0xFF16A34A)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_activeTransit!['status'] == 'en_route') ...[
                        ElevatedButton.icon(
                          onPressed: _loading ? null : _handleArrived,
                          icon: const Icon(Icons.check_circle_outline),
                          label: const Text('MARK ARRIVED AT HOSPITAL'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF16A34A),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      ElevatedButton.icon(
                        onPressed: _loading ? null : _handleComplete,
                        icon: const Icon(Icons.done_all),
                        label: const Text('COMPLETE TRIP'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF16A34A),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(
                _error!,
                style: const TextStyle(color: const Color(0xFF16A34A), fontWeight: FontWeight.bold, fontSize: 11),
              ),
            ]
          ],
        ),
      );

    Widget mapPanel = Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: mapCenter,
            initialZoom: 14.0,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'pk.gchq.paramedic_app',
            ),
            if (_previewRoutePoints.isNotEmpty && _activeTransit == null)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _previewRoutePoints,
                    strokeWidth: 4.0,
                    color: Colors.grey.shade500,
                    isDotted: true,
                  ),
                ],
              ),
            if (_routePoints.isNotEmpty)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _routePoints,
                    strokeWidth: 5.0,
                    color: const Color(0xFF16A34A),
                  ),
                ],
              ),
            MarkerLayer(markers: markers),
          ],
        ),
        // Live status pill on top of map
        if (_activeTransit != null)
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF16A34A),
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
              ),
              child: const Row(
                children: [
                  Icon(Icons.radar, color: Colors.white, size: 14),
                  SizedBox(width: 6),
                  Text(
                    'GREEN CORRIDOR LIVE',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5),
                  ),
                ],
              ),
            ),
          ),
        // Route preview pill when hospital selected
        if (_previewRoutePoints.isNotEmpty && _activeTransit == null)
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF16A34A), width: 1.5),
                boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6)],
              ),
              child: const Row(
                children: [
                  Icon(Icons.route, color: const Color(0xFF16A34A), size: 14),
                  SizedBox(width: 6),
                  Text(
                    'ROUTE PREVIEW',
                    style: TextStyle(color: const Color(0xFF16A34A), fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5),
                  ),
                ],
              ),
            ),
          ),
      ],
    );

    return Scaffold(
      body: Stack(
        children: [
          mapPanel,
          if (isTablet)
            Positioned(
              top: 24,
              left: 24,
              width: 380,
              height: _isExpanded ? 400 : 250,
              child: Card(
                elevation: 6,
                shadowColor: Colors.black38,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: controlPanel,
              ),
            )
          else
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              height: _isExpanded ? 400 : 250,
              child: Card(
                elevation: 6,
                shadowColor: Colors.black38,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: controlPanel,
              ),
            ),
          // Route overview overlay — shown after DEPART, before guidance starts
          if (_showingOverview && _activeTransit != null)
            Positioned(
              bottom: 24,
              left: 16,
              right: 16,
              child: SafeArea(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 24, offset: Offset(0, 8))],
                    border: Border.all(color: Colors.black12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: const BoxDecoration(color: const Color(0xFF16A34A), shape: BoxShape.circle),
                            child: const Icon(Icons.local_shipping, color: Colors.white, size: 18),
                          ),
                          Expanded(
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              height: 2,
                              color: const Color(0xFF16A34A),
                            ),
                          ),
                          const Icon(Icons.navigation, color: const Color(0xFF16A34A), size: 16),
                          Expanded(
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              height: 2,
                              color: const Color(0xFF16A34A),
                            ),
                          ),
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFF16A34A), width: 2),
                            ),
                            child: const Icon(Icons.local_hospital, color: const Color(0xFF16A34A), size: 18),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _activeTransit?['hospital']?['name'] ?? 'Destination Hospital',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: const Color(0xFF16A34A)),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Pan & zoom to explore • ${_routePoints.length} waypoints',
                                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: _beginNavigation,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF16A34A),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              elevation: 0,
                            ),
                            icon: const Icon(Icons.navigation, size: 18),
                            label: const Text(
                              'GO',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 0.5),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTriagePage() {
    final filtered = _triageCodes.where((tc) {
      final name = (tc['name'] ?? '').toString().toLowerCase();
      return name.contains(_globalSearchQuery.toLowerCase());
    }).toList();

    if (filtered.isEmpty) {
      return const Center(child: Text('No results found', style: TextStyle(fontSize: 12, color: Colors.grey)));
    }

    if (_isExpanded) {
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final tc = filtered[index];
          final name = tc['name'] ?? '';
          final isSelected = _selectedTriageCodeId == tc['id'];
          Color dotColor = Colors.grey;
          if (name.toLowerCase().contains('red')) dotColor = Colors.red;
          else if (name.toLowerCase().contains('amber')) dotColor = Colors.amber;
          else if (name.toLowerCase().contains('green')) dotColor = Colors.green;

          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: isSelected ? const Color(0xFF16A34A) : Colors.grey.shade300, width: isSelected ? 2 : 1),
              ),
              tileColor: isSelected ? Colors.grey.shade100 : Colors.white,
              leading: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              title: Text(name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, color: const Color(0xFF16A34A))),
              onTap: () {
                setState(() {
                  _selectedTriageCodeId = tc['id'];
                });
                Future.delayed(const Duration(milliseconds: 300), () {
                  if (_pageController.hasClients) {
                    _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
                  }
                });
              },
            ),
          );
        },
      );
    }

    return Align(
      alignment: Alignment.center,
      child: SizedBox(
        height: 56,
        child: Row(
          children: filtered.map<Widget>((tc) {
            final name = tc['name'] ?? '';
            final isSelected = _selectedTriageCodeId == tc['id'];
            Color dotColor = Colors.grey;
            if (name.toLowerCase().contains('red')) dotColor = Colors.red;
            else if (name.toLowerCase().contains('amber')) dotColor = Colors.amber;
            else if (name.toLowerCase().contains('green')) dotColor = Colors.green;

            return Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _selectedTriageCodeId = tc['id'];
                    });
                    Future.delayed(const Duration(milliseconds: 300), () {
                      if (_pageController.hasClients) {
                        _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
                      }
                    });
                  },
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.grey.shade100 : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isSelected ? const Color(0xFF16A34A) : Colors.grey.shade300, width: isSelected ? 2 : 1),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            name.replaceAll('Code ', ''),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: const Color(0xFF16A34A),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildIssuePage() {
    final filtered = _emergencyTypes.where((et) {
      final name = (et['name'] ?? '').toString().toLowerCase();
      return name.contains(_globalSearchQuery.toLowerCase());
    }).toList();

    if (filtered.isEmpty) {
      return const Center(child: Text('No results found', style: TextStyle(fontSize: 12, color: Colors.grey)));
    }

    if (_isExpanded) {
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final et = filtered[index];
          final name = et['name'] ?? '';
          final isSelected = _selectedEmergencyTypeId == et['id'];

          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: isSelected ? const Color(0xFF16A34A) : Colors.grey.shade300, width: isSelected ? 2 : 1),
              ),
              tileColor: isSelected ? Colors.grey.shade100 : Colors.white,
              leading: Icon(Icons.medical_services_outlined, color: isSelected ? const Color(0xFF16A34A) : Colors.grey.shade600, size: 16),
              title: Text(name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, color: const Color(0xFF16A34A))),
              onTap: () {
                setState(() {
                  _selectedEmergencyTypeId = et['id'];
                });
                Future.delayed(const Duration(milliseconds: 300), () {
                  if (_pageController.hasClients) {
                    _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
                  }
                });
              },
            ),
          );
        },
      );
    }

    return Align(
      alignment: Alignment.center,
      child: SizedBox(
        height: 56,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: filtered.map<Widget>((et) {
              final name = et['name'] ?? '';
              final isSelected = _selectedEmergencyTypeId == et['id'];

              return Container(
                margin: const EdgeInsets.only(right: 6),
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _selectedEmergencyTypeId = et['id'];
                    });
                    Future.delayed(const Duration(milliseconds: 300), () {
                      if (_pageController.hasClients) {
                        _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
                      }
                    });
                  },
                  child: Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.grey.shade100 : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isSelected ? const Color(0xFF16A34A) : Colors.grey.shade300, width: isSelected ? 2 : 1),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.medical_services_outlined, size: 14, color: isSelected ? const Color(0xFF16A34A) : Colors.grey.shade600),
                        const SizedBox(width: 6),
                        Text(
                          name,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: const Color(0xFF16A34A),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildHospitalPage() {
    final reqSpecialty = _selectedEmergencyTypeId != null
        ? _emergencyTypes.firstWhere(
            (et) => et['id'] == _selectedEmergencyTypeId,
            orElse: () => {'requiredSpecialty': null},
          )['requiredSpecialty']
        : null;

    final filteredHospitals = _hospitals.where((h) {
      final name = (h['name'] ?? '').toString().toLowerCase();
      return name.contains(_globalSearchQuery.toLowerCase());
    }).toList();

    if (filteredHospitals.isEmpty) {
      return const Center(child: Text('No results found', style: TextStyle(fontSize: 12, color: Colors.grey)));
    }

    if (_isExpanded) {
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: filteredHospitals.length,
        itemBuilder: (context, index) {
          final h = filteredHospitals[index];
          final id = h['id'];
          String name = h['name'] ?? '';
          final List<dynamic>? specs = h['specialties'];
          final hasRecommended = reqSpecialty != null && specs != null && specs.contains(reqSpecialty);
          if (hasRecommended) {
            name += ' (Recommended)';
          }
          final isSelected = _selectedHospitalId == id;

          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(
                  color: isSelected ? const Color(0xFF16A34A) : (hasRecommended ? Colors.grey.shade700 : Colors.grey.shade300),
                  width: isSelected ? 2 : 1,
                ),
              ),
              tileColor: isSelected ? Colors.grey.shade100 : (hasRecommended ? Colors.grey.shade50 : Colors.white),
              leading: Icon(
                Icons.local_hospital_outlined,
                color: isSelected ? const Color(0xFF16A34A) : (hasRecommended ? Colors.grey.shade700 : Colors.grey.shade600),
                size: 16,
              ),
              title: Text(
                name,
                style: TextStyle(
                  fontWeight: isSelected || hasRecommended ? FontWeight.bold : FontWeight.normal,
                  color: const Color(0xFF16A34A),
                ),
              ),
              subtitle: specs != null ? Text(specs.join(', '), style: const TextStyle(fontSize: 10, color: Colors.grey)) : null,
              trailing: isSelected
                  ? const Icon(Icons.check_circle, color: const Color(0xFF16A34A), size: 18)
                  : (hasRecommended ? const Icon(Icons.star, color: const Color(0xFF16A34A), size: 16) : null),
              onTap: () {
                setState(() {
                  _selectedHospitalId = id;
                });
                _fetchPreviewRoute();
                Future.delayed(const Duration(milliseconds: 300), () {
                  if (_pageController.hasClients) {
                    _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
                  }
                });
              },
            ),
          );
        },
      );
    }

    return Align(
      alignment: Alignment.center,
      child: SizedBox(
        height: 56,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: filteredHospitals.map<Widget>((h) {
              final id = h['id'];
              String name = h['name'] ?? '';
              final List<dynamic>? specs = h['specialties'];
              final hasRecommended = reqSpecialty != null && specs != null && specs.contains(reqSpecialty);
              final isSelected = _selectedHospitalId == id;

              return Container(
                margin: const EdgeInsets.only(right: 6, bottom: 4),
                width: 160,
                child: InkWell(
                   onTap: () {
                     setState(() {
                       _selectedHospitalId = id;
                     });
                     _fetchPreviewRoute();
                     Future.delayed(const Duration(milliseconds: 300), () {
                       if (_pageController.hasClients) {
                         _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
                       }
                     });
                   },
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.grey.shade100 : (hasRecommended ? Colors.grey.shade50 : Colors.white),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected ? const Color(0xFF16A34A) : (hasRecommended ? Colors.grey.shade600 : Colors.grey.shade300),
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.local_hospital_outlined,
                              size: 13,
                              color: isSelected ? const Color(0xFF16A34A) : (hasRecommended ? Colors.grey.shade700 : Colors.grey.shade600),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: isSelected || hasRecommended ? FontWeight.bold : FontWeight.normal,
                                  color: const Color(0xFF16A34A),
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (hasRecommended)
                          const Text('Recommended', style: TextStyle(color: const Color(0xFF16A34A), fontSize: 8, fontWeight: FontWeight.bold))
                        else if (specs != null && specs.isNotEmpty)
                          Text(specs.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 8)),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildConfirmPage(ThemeData theme) {
    final triageName = _selectedTriageCodeId != null
        ? _triageCodes.firstWhere(
            (tc) => tc['id'] == _selectedTriageCodeId,
            orElse: () => {'name': 'Not Selected'},
          )['name']
        : 'Not Selected';
    final issueName = _selectedEmergencyTypeId != null
        ? _emergencyTypes.firstWhere(
            (et) => et['id'] == _selectedEmergencyTypeId,
            orElse: () => {'name': 'Not Selected'},
          )['name']
        : 'Not Selected';
    final hospitalName = _selectedHospitalId != null
        ? _hospitals.firstWhere(
            (h) => h['id'] == _selectedHospitalId,
            orElse: () => {'name': 'Not Selected'},
          )['name']
        : 'Not Selected';

    final double buttonHeight = _isExpanded ? 46.0 : 38.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_isExpanded) ...[
          const Text('Confirm Details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: const Color(0xFF16A34A))),
          const SizedBox(height: 6),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _buildCompactSummaryItem('Triage', triageName, 0),
                _buildCompactSummaryItem('Issue', issueName, 1),
                _buildCompactSummaryItem('Hospital', hospitalName, 2),
              ],
            ),
          ),
        ] else ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                _buildCompactSummaryItem('Triage', triageName.replaceAll('Code ', ''), 0),
                _buildCompactSummaryItem('Issue', issueName, 1),
                _buildCompactSummaryItem('Hospital', hospitalName, 2),
              ],
            ),
          ),
        ],
        const SizedBox(height: 6),
        SizedBox(
          height: buttonHeight,
          child: ElevatedButton(
            onPressed: _loading ? null : _handleStartTransit,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              foregroundColor: Colors.white,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: _loading
                ? const CircularProgressIndicator(color: Colors.white)
                : const Text('DEPART & LOCK CORRIDOR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ),
      ],
    );
  }

  Widget _buildCompactSummaryItem(String label, String value, int stepIndex) {
    return Container(
      margin: EdgeInsets.only(right: _isExpanded ? 0 : 6, bottom: _isExpanded ? 6 : 0),
      width: _isExpanded ? double.infinity : 110.0,
      child: Card(
        elevation: 0,
        color: Colors.grey.shade50,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: Colors.grey.shade300),
        ),
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: () {
            if (_pageController.hasClients) {
              _pageController.animateToPage(
                stepIndex,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(label, style: TextStyle(fontSize: _isExpanded ? 10 : 9, color: Colors.grey.shade600)),
                      const SizedBox(height: 2),
                      Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: const Color(0xFF16A34A)),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.edit, size: 12, color: const Color(0xFF16A34A)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
