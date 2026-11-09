import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  final cameras = await availableCameras();

  // Select the front camera
  final frontCamera = cameras.firstWhere(
    (camera) => camera.lensDirection == CameraLensDirection.front,
    orElse: () => cameras.first, // fallback to first if no front camera found
  );

  runApp(MyApp(camera: frontCamera));
}

class MyApp extends StatelessWidget {
  final CameraDescription camera;
  const MyApp({super.key, required this.camera});
  
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: InOutScreen(camera: camera),
    );
  }
}

class InOutScreen extends StatefulWidget {
  final CameraDescription camera;
  const InOutScreen({super.key, required this.camera});

  @override
  _InOutScreenState createState() => _InOutScreenState();
}

class _InOutScreenState extends State<InOutScreen> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  FlutterTts flutterTts = FlutterTts();
  bool _isProcessing = false;
  String _detectedName = "";
  Rect? _faceRect;
  Timer? _detectionTimer;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(widget.camera, ResolutionPreset.medium);
    _initializeControllerFuture = _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      
      // Start real-time detection after camera initialization
      _startRealTimeDetection();
    });
    
    // Initialize TTS for Thai language
    _initTts();
  }

  Future<void> _initTts() async {
    await flutterTts.setLanguage("th-TH");
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);
  }

  void _startRealTimeDetection() {
    // Run face detection every 3 seconds
    _detectionTimer = Timer.periodic(Duration(seconds: 3), (timer) {
      if (!_isProcessing) {
        _processFrame();
      }
    });
  }

  Future<void> _processFrame() async {
    if (_isProcessing) return;
    
    setState(() {
      _isProcessing = true;
    });
    
    try {
      await _initializeControllerFuture;
      final XFile image = await _controller.takePicture();
      
      var uri = Uri.parse('${dotenv.env['API_BASE_URL']}/api/recognize');
      var request = http.MultipartRequest('POST', uri);
      request.files.add(await http.MultipartFile.fromPath('image', image.path));
      
      var response = await request.send();
      final responseString = await response.stream.bytesToString();
      final responseData = jsonDecode(responseString);
      
      if (response.statusCode == 200) {
        setState(() {
          _detectedName = responseData['name'];
          
          // Parse face rectangle data from response
          if (responseData.containsKey('face_location')) {
            final faceLocation = responseData['face_location'];
            final screenWidth = MediaQuery.of(context).size.width;
            final screenHeight = MediaQuery.of(context).size.height;
            
            // Convert face location to screen coordinates
            _faceRect = Rect.fromLTRB(
              faceLocation[3] * screenWidth / _controller.value.previewSize!.height,
              faceLocation[0] * screenHeight / _controller.value.previewSize!.width,
              faceLocation[1] * screenWidth / _controller.value.previewSize!.height,
              faceLocation[2] * screenHeight / _controller.value.previewSize!.width,
            );
          }
        });
        
        // Speak the greeting in Thai
        await flutterTts.speak("ยินดีต้อนรับคุณ $_detectedName");
      } else {
        setState(() {
          _detectedName = "";
          _faceRect = null;
        });
      }
    } catch (e) {
      print("Error during face detection: $e");
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  @override
  void dispose() {
    _detectionTimer?.cancel();
    _controller.dispose();
    flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Stack(
              fit: StackFit.expand,
              children: [
                // Full-screen camera preview
                CameraPreview(_controller),
                
                // Face rectangle overlay
                if (_faceRect != null)
                  Positioned.fromRect(
                    rect: _faceRect!,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.green, width: 3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                
                // Name display
                if (_detectedName.isNotEmpty)
                  Positioned(
                    top: _faceRect != null ? _faceRect!.bottom + 10 : 50,
                    left: _faceRect != null ? _faceRect!.left : 20,
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _detectedName,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                
                // Processing indicator
                if (_isProcessing)
                  Positioned(
                    top: 20,
                    right: 20,
                    child: Container(
                      padding: EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                  ),
              ],
            );
          } else {
            return Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}