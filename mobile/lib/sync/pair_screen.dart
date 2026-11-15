/// "Pair with laptop": scan the QR code in the laptop HUD (Settings -> Phone) and pair over
/// the local Wi-Fi. No account, no Snapy server.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'pairing.dart';
import 'sync_client.dart';
import 'sync_store.dart';

/// App-level wiring: the app sets [keyStore] to its Android Keystore-backed store
/// (MethodChannel to Kotlin). Until then pairing refuses to run rather than keep the
/// private key in plain storage.
class SyncHost {
  static SecureKeyStore? keyStore;
}

class PairLaptopPage extends StatefulWidget {
  final SecureKeyStore? keyStore;
  const PairLaptopPage({super.key, this.keyStore});

  @override
  State<PairLaptopPage> createState() => _PairLaptopPageState();
}

class _PairLaptopPageState extends State<PairLaptopPage> {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  String? _status;
  bool _busy = false;
  bool _done = false;
  List<PairedLaptop> _laptops = [];

  SecureKeyStore? get _store => widget.keyStore ?? SyncHost.keyStore;

  @override
  void initState() {
    super.initState();
    _loadLaptops();
  }

  Future<void> _loadLaptops() async {
    final s = _store;
    if (s == null) return;
    final l = await PairingRepository(s).laptops();
    if (mounted) setState(() => _laptops = l);
  }

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture cap) async {
    if (_busy || _done) return;
    final raw = cap.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw == null) return;
    PairingPayload qr;
    try {
      qr = PairingPayload.parse(raw);
    } on FormatException catch (e) {
      setState(() => _status = e.message);
      return;
    }
    final store = _store;
    if (store == null) {
      setState(() => _status = 'Secure storage isn\'t ready on this phone yet, so pairing is off.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Pairing with ${qr.name}…';
    });
    try {
      final laptop = await pairWithLaptop(qr, PairingRepository(store));
      await _scanner.stop();
      setState(() {
        _done = true;
        _status = 'Paired with ${laptop.name}. Your phone and laptop now sync over this Wi-Fi.';
      });
      _loadLaptops();
    } catch (e) {
      setState(() => _status = 'Couldn\'t pair. Make sure both are on the same Wi-Fi and the code is fresh.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unpair(PairedLaptop l) async {
    final s = _store;
    if (s == null) return;
    await PairingRepository(s).removeLaptop(l.id);
    _loadLaptops();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pair with laptop')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('On your laptop open Snapy → Settings → Phone and scan the code. '
            'Both devices must be on the same Wi-Fi. Data is encrypted end to end and never leaves your network.'),
        const SizedBox(height: 16),
        if (!_done)
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: MobileScanner(controller: _scanner, onDetect: _onDetect),
            ),
          ),
        if (_status != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_status!)),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        if (_laptops.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('Paired laptops', style: Theme.of(context).textTheme.titleMedium),
          for (final l in _laptops)
            ListTile(
              title: Text(l.name),
              subtitle: Text(l.lastHost ?? ''),
              trailing: IconButton(icon: const Icon(Icons.link_off), tooltip: 'Unpair', onPressed: () => _unpair(l)),
            ),
        ],
      ]),
    );
  }
}
