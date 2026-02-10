// ==========================================
// SERVICES SECTION (Future move to lib/services)
// ==========================================
// - _getPlacePredictions()
// - _loadDiscoveryData()
// - _startTracking()

// ==========================================
// UI SCREENS (Future move to lib/screens)
// ==========================================
// - HomeScreen class
// - _buildBottomPanel()
// - _buildSpotList()
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:io';

void main() => runApp(const TravPilotApp());

class TravPilotApp extends StatelessWidget {
  const TravPilotApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.cyanAccent, brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0F172A),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  String _statusMessage = "READY FOR DEPARTURE";
  int _selectedMinutes = 10;
  bool _isTracking = false;
  bool _isLoadingSpots = false;
  StreamSubscription<Position>? _positionStream;
  final TextEditingController _destinationController = TextEditingController();
  final AudioPlayer _audioPlayer = AudioPlayer();
  late TabController _tabController;

  double? _targetLat;
  double? _targetLong;
  double _currentSpeed = 0.0;
  double _accuracy = 0.0;

  List _hotels = [];
  List _restaurants = [];
  List _attractions = [];
  List _adventure = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  // --- SEARCH PREDICTIONS ---
  Future<List<String>> _getPlacePredictions(String query) async {
    if (query.length < 3) return [];
    final url = Uri.parse('https://nominatim.openstreetmap.org/search?q=$query&format=json&limit=5&countrycodes=in');
    try {
      final response = await http.get(url, headers: {'User-Agent': 'TravPilot_CS_Project'});
      if (response.statusCode == 200) {
        List data = json.decode(response.body);
        return data.map((place) => place['display_name'] as String).toList();
      }
    } catch (e) { return []; }
    return [];
  }

  // --- DATA LOADING & CATEGORIZATION ---
  Future<void> _loadDiscoveryData(String address) async {
    setState(() {
      _isLoadingSpots = true;
      _updateStatus("ANALYZING DESTINATION...");
    });

    try {
      List<Location> locations = await locationFromAddress(address);
      if (locations.isNotEmpty) {
        _targetLat = locations.first.latitude;
        _targetLong = locations.first.longitude;
        await _fetchCategorizedSpots();
      }
    } on SocketException {
      _updateStatus("NO INTERNET CONNECTION");
    } catch (e) {
      _updateStatus("COULD NOT FIND LOCATION");
    } finally {
      setState(() => _isLoadingSpots = false);
    }
  }

  Future<void> _fetchCategorizedSpots() async {
    final query = """
    [out:json];
    (
      node["tourism"~"hotel|hostel|guest_house"](around:3000, $_targetLat, $_targetLong);
      node["amenity"~"restaurant|cafe|fast_food"](around:3000, $_targetLat, $_targetLong);
      node["tourism"~"attraction|museum|viewpoint"](around:3000, $_targetLat, $_targetLong);
      node["leisure"~"park|nature_reserve|climbing"](around:5000, $_targetLat, $_targetLong);
    );
    out body 50;
    """;
    
    final url = Uri.parse('https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent(query)}');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        List elements = data['elements'];
        setState(() {
          _hotels = elements.where((e) => e['tags']['tourism']?.toString().contains('hotel') ?? false).toList();
          
          // --- FIX: EXCLUDE INTERNET CAFES ---
          _restaurants = elements.where((e) {
            final amenity = e['tags']['amenity'];
            return (amenity == 'restaurant' || amenity == 'cafe' || amenity == 'fast_food') &&
                   e['tags']['internet_access'] == null && 
                   !(e['tags']['name']?.toString().toLowerCase().contains('internet') ?? false);
          }).toList();

          _attractions = elements.where((e) => e['tags']['tourism'] == 'attraction' || e['tags']['tourism'] == 'museum').toList();
          _adventure = elements.where((e) => e['tags']['leisure'] != null || e['tags']['tourism'] == 'viewpoint').toList();
        });
        _updateStatus("LOCATION LOADED");
      }
    } catch (e) { debugPrint("API Error: $e"); }
  }

  // --- GPS TRACKING ---
  Future<void> _startTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _updateStatus("GPS is turned OFF");
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    if (_targetLat == null) {
      _updateStatus("Search destination first!");
      return;
    }
    
    setState(() => _isTracking = true);

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
    ).listen((Position position) {
      double distMeters = Geolocator.distanceBetween(position.latitude, position.longitude, _targetLat!, _targetLong!);
      double distKm = distMeters / 1000;
      double speedKmh = position.speed > 0 ? position.speed * 3.6 : 30.0;
      double thresholdKm = (speedKmh * _selectedMinutes) / 60;

      setState(() {
        _currentSpeed = position.speed * 3.6;
        _accuracy = position.accuracy;
        
        if (distKm <= thresholdKm || distMeters < 500) {
          _statusMessage = "🚨 ARRIVED! 🚨";
          _triggerAlarm();
          _stopTracking();
        } else {
          _statusMessage = "${distKm.toStringAsFixed(2)} KM REMAINING";
        }
      });
    }, onError: (e) => _updateStatus("GPS Error: Try Outdoors"));
  }

  void _triggerAlarm() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [500, 1000, 500, 1000], repeat: 1);
    }
    _audioPlayer.play(AssetSource('alarm.mp3'));
  }

  void _stopTracking() {
    _positionStream?.cancel();
    _audioPlayer.stop();
    Vibration.cancel();
    setState(() { _isTracking = false; _statusMessage = "TRACKING STOPPED"; });
  }

  void _updateStatus(String msg) => setState(() => _statusMessage = msg);

  @override
  void dispose() {
    _tabController.dispose();
    _destinationController.dispose();
    _positionStream?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0F172A), Color(0xFF1E293B)]),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Text("TRAVPILOT", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 5, color: Colors.cyanAccent)),
                    const SizedBox(height: 20),
                    // --- SEARCH BAR WITH CROSS BUTTON ---
                    TypeAheadField<String>(
                      controller: _destinationController,
                      suggestionsCallback: (search) => _getPlacePredictions(search),
                      builder: (context, controller, focusNode) => TextField(
                        controller: controller,
                        focusNode: focusNode,
                        decoration: InputDecoration(
                          hintText: "Where to?",
                          prefixIcon: const Icon(Icons.search, color: Colors.cyanAccent),
                          suffixIcon: controller.text.isNotEmpty 
                            ? IconButton(
                                icon: const Icon(Icons.close, color: Colors.white54),
                                onPressed: () {
                                  controller.clear();
                                  setState(() { _hotels = []; _restaurants = []; _attractions = []; _adventure = []; });
                                },
                              ) 
                            : null,
                          filled: true, fillColor: Colors.white.withOpacity(0.05),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
                        ),
                      ),
                      itemBuilder: (context, suggestion) => ListTile(title: Text(suggestion, style: const TextStyle(fontSize: 12))),
                      onSelected: (suggestion) {
                        _destinationController.text = suggestion;
                        _loadDiscoveryData(suggestion);
                      },
                    ),
                  ],
                ),
              ),

              TabBar(
                controller: _tabController,
                indicatorColor: Colors.cyanAccent,
                tabs: const [Tab(text: "Hotel"), Tab(text: "Food"), Tab(text: "Spot"), Tab(text: "Fun")],
              ),

              Expanded(
                child: _isLoadingSpots 
                  ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildSpotList(_hotels, Icons.hotel),
                        _buildSpotList(_restaurants, Icons.restaurant),
                        _buildSpotList(_attractions, Icons.camera_alt),
                        _buildSpotList(_adventure, Icons.landscape),
                      ],
                    ),
              ),

              _buildBottomPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildStatTile(Icons.speed, "${_currentSpeed.toStringAsFixed(1)}", "KM/H"),
              _buildStatTile(Icons.gps_fixed, "${_accuracy.toStringAsFixed(0)}m", "SIGNAL"),
              DropdownButton<int>(
                value: _selectedMinutes,
                dropdownColor: const Color(0xFF1E293B),
                underline: const SizedBox(),
                items: [1,3,5, 10, 15, 20].map((v) => DropdownMenuItem(value: v, child: Text("$v Mins"))).toList(),
                onChanged: (v) => setState(() => _selectedMinutes = v!),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              GestureDetector(
                onTap: _isTracking ? _stopTracking : _startTracking,
                child: CircleAvatar(
                  backgroundColor: _isTracking ? Colors.redAccent.withOpacity(0.2) : Colors.cyanAccent.withOpacity(0.1),
                  child: Icon(_isTracking ? Icons.stop : Icons.play_arrow, color: _isTracking ? Colors.redAccent : Colors.cyanAccent),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(child: Text(_statusMessage, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.cyanAccent))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSpotList(List spots, IconData icon) {
    if (spots.isEmpty) return const Center(child: Text("No locations found here"));
    return ListView.builder(
      itemCount: spots.length,
      itemBuilder: (context, index) {
        final spot = spots[index]['tags'];
        return ListTile(
          leading: Icon(icon, color: Colors.cyanAccent, size: 18),
          title: Text(spot['name'] ?? "Local Spot", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          subtitle: Text(spot['amenity'] ?? spot['tourism'] ?? "Place", style: const TextStyle(fontSize: 10, color: Colors.white38)),
        );
      },
    );
  }

  Widget _buildStatTile(IconData icon, String val, String label) {
    return Column(children: [Icon(icon, size: 14, color: Colors.white38), Text(val, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)), Text(label, style: const TextStyle(fontSize: 8, color: Colors.white38))]);
  }
}