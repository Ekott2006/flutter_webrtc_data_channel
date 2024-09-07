import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart' as shelf_router;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Webrtc Data Channel Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _textController = TextEditingController();
  final signaling = Signaling();

  final _serverTextController = TextEditingController();
  final webService = WebService();

  @override
  void initState() {
    signaling.initialize();
    super.initState();
  }

  @override
  void dispose() {
    _textController.dispose();
    _serverTextController.dispose();
    signaling.hangUp();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: SizedBox(
          width: 800,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  TextButton(
                    child: const Text("Start Server"),
                    onPressed: () async {
                      // TODO: Start Server
                      await webService.startServer(signaling);
                    },
                  ),
                  Flexible(
                    child: TextField(
                      controller: _serverTextController,
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.digitsOnly
                      ],
                      maxLength: 3,
                      maxLengthEnforcement: MaxLengthEnforcement.enforced,
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      // TODO: Join Server
                      await webService.joinServer(signaling);
                    },
                    child: const Text("Join Server"),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: TextField(
                      controller: _textController,
                    ),
                  ),
                  FilledButton(
                    child: const Text("Send Message"),
                    onPressed: () {
                      signaling.send(_textController.text);
                    },
                  )
                ],
              ),
              StreamBuilder<String>(
                stream: signaling.stringStream.stream,
                builder: (context, snapshot) =>
                    Text('Got Data From ${snapshot.data}'),
              )
            ],
          ),
        ),
      ),
    );
  }
}

class Signaling {
  late RTCPeerConnection _peerConnection;
  late RTCDataChannel? _dataChannel;
  final _label = Helper().getRandomString();
  final List<RTCIceCandidate> candidates = [];
  final StreamController<String> stringStream = StreamController<String>();

  initialize() async {
    _peerConnection = await createPeerConnection({});
    _peerConnection.onIceCandidate = (candidate) {
      print('peerConnection --  onIceCandidate: ${candidate.candidate}');
      candidates.add(candidate);
    };
  }

  Future<RTCSessionDescription> createOffer() async {
    _dataChannel = await _peerConnection.createDataChannel(
        _label, RTCDataChannelInit()..id = 1);
    _dataChannel?.onMessage = (data) => stringStream.add(data.text);

    var offer = await _peerConnection.createOffer({});
    await _peerConnection.setLocalDescription(offer);
    return offer;
  }

  Future<RTCSessionDescription> createAnswer(RTCSessionDescription description,
      List<RTCIceCandidate> iceCandidates) async {
    for (var x in iceCandidates) {
      _peerConnection.addCandidate(x);
    }
    _peerConnection.setRemoteDescription(description);
    var answer = await _peerConnection.createAnswer();
    _peerConnection.setLocalDescription(answer);

    _peerConnection.onDataChannel = (channel) {
      print("Channel Ready");
      _dataChannel = channel;
      _dataChannel?.onMessage = (data) => stringStream.add(data.text);
    };
    return answer;
  }

  respondOffer(RTCSessionDescription description,
      List<RTCIceCandidate> iceCandidates) async {
    await _peerConnection.setRemoteDescription(description);
    for (var x in iceCandidates) {
      _peerConnection.addCandidate(x);
    }
  }

  send(String text) async {
    await _dataChannel?.send(RTCDataChannelMessage(text));
  }

  hangUp() async {
    await _dataChannel?.close();
    await _peerConnection.close();
  }
}

class Helper {
  static const _chars =
      'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';
  final Random _rnd = Random();

  String getRandomString() => String.fromCharCodes(Iterable.generate(
      _rnd.nextInt(50), (_) => _chars.codeUnitAt(_rnd.nextInt(_chars.length))));
}

class WebService {
  startServer(Signaling signaling) async {
    final router = shelf_router.Router();
    var handler =
        const Pipeline().addMiddleware(corsHeaders()).addHandler(router.call);
    router.get("/", (request) => Response.ok("Hello World"));
    router.post("/", (request) async {
      print("Request Received");
      // Create Answer
      final payload = jsonDecode(await request.readAsString());
      var answer = await signaling.createAnswer(
          RTCSessionDescription(payload['sdp'], payload['type']), [
        RTCIceCandidate(
            payload['candidate'], payload['sdpMid'], payload['sdpMLineIndex'])
      ]);

      await Future.delayed(
          const Duration(seconds: 2)); // Wait for ICE Candidates

      var response = jsonEncode(<String, dynamic>{
        ...answer.toMap(),
        ...signaling.candidates.first.toMap()
      });
      print("Response: $response");
      return Response.ok(response,
          headers: {'Content-Type': 'application/json'});
    });
    await shelf_io.serve(handler.call, 'localhost', 8083);
    print("Server Started");
  }

  joinServer(Signaling signaling) async {
    final url = Uri.parse("http://localhost:8083/");
    await Future.delayed(const Duration(seconds: 2));

    final Map<String, dynamic> body = {
      ...(await signaling.createOffer()).toMap(),
      ...signaling.candidates.first.toMap()
    };
    await Future.delayed(const Duration(seconds: 2));
    var response = await http.post(url, body: jsonEncode(body));
    final payload = jsonDecode(response.body);
    await signaling
        .respondOffer(RTCSessionDescription(payload['sdp'], payload['type']), [
      RTCIceCandidate(
          payload['candidate'], payload['sdpMid'], payload['sdpMLineIndex'])
    ]);
    print('Response body: ${response.body}');
  }
}
