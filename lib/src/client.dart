part of sockjs_client;

class CloseEvent extends event.Event {
  int code;
  String reason;
  bool wasClean;
  dynamic lastEvent;

  CloseEvent({this.code, this.reason, this.wasClean, this.lastEvent}) : super("close");
}

class MessageEvent extends event.Event {
  String data;
  MessageEvent(this.data) : super("message");
}

class Client extends Object with event.Emitter {

  bool debug;
  bool devel;

  String _baseUrl;
  String server = null;
  String protocol = null;
  List<String> _protocols = <String>[];

  int readyState = CONNECTING;

  Info info;
  num rtt;
  num rto;
  List<String> protocolsWhitelist = <String>[];
  num roundTrips;
  num timeout;

  bool noCredentials;

  InfoReceiver _ir;

  dynamic _transport = null;
  Timer _transportTref;

  Client(String url, {this.devel: false,
                      this.debug: false,
                      this.protocolsWhitelist,
                      this.info,
                      this.noCredentials: false,
                      this.rtt: 0,
                      this.server,
                      this.roundTrips,
                      this.timeout}) {

    _baseUrl = utils.amendUrl(url);

    if (server == null) {
      server = utils.random_number_string(1000);
    }

    _ir = new InfoReceiver.forURL(_baseUrl);
    _ir.onFinish.listen((InfoReceiverEvent evt) {
        _ir = null;
        if (evt.info != null) {
            _applyInfo(evt.info);
            _didClose();
        } else {
            _didClose(1002, 'Can\'t connect to server', true);
        }
    });
  }

  Stream<event.Event> get onOpen => getEventStream<event.Event>('open');
  Stream<MessageEvent> get onMessage => getEventStream<MessageEvent>('message');
  Stream<CloseEvent> get onClose => getEventStream<CloseEvent>('close');
  Stream<event.Event> get onHeartbeat => getEventStream<event.Event>('heartbeat');

  void close([int code, String reason]) {
    if (_transport != null) {
      if (_transport is WebSocketTransport) {
        _transport.doClose(code ?? 1000, reason);
      } else if (_transport is XhrStreamingTransport) {
        if (code == null) {
          code = 0;
        }
        if (reason == null) {
          reason = '';
        }
        _didClose(code, reason);
      }
    }
  }

  bool send(String data) {
    if (readyState == CONNECTING) {
        throw 'INVALID_STATE_ERR';
    }
    if (readyState == OPEN) {
        _transport.doSend(utils.quote(data));
    }
    return true;
  }

  void _didClose([int code = 0, String reason = "", bool force = false]) {
    if (readyState != CONNECTING &&
        readyState != OPEN &&
        readyState != CLOSING) {
            throw 'INVALID_STATE_ERR';
    }
    if (_ir != null) {
//        _ir.nuke();
        _ir = null;
    }

    if (_transport != null) {
        _transport.doCleanup();
        _transport = null;
    }

    var close_event = new CloseEvent(
        code: code,
        reason: reason,
        wasClean: utils.userSetCode(code));

    if (!utils.userSetCode(code) &&
        readyState == CONNECTING && !force) {
        if (_tryNextProtocol(close_event)) {
            return;
        }
        close_event = new CloseEvent( code: 2000,
                                      reason: "All transports failed",
                                      wasClean: false,
                                      lastEvent: close_event );
    }
    readyState = CLOSED;

    Timer.run(() => dispatch(close_event));
  }

  void _dispatchOpen() {
    if (readyState == CONNECTING) {
        if (_transportTref != null) {
            _transportTref.cancel();
            _transportTref = null;
        }
        readyState = OPEN;
        dispatch("open");
    } else {
        // The server might have been restarted, and lost track of our
        // connection.
        _didClose(1006, "Server lost session");
    }
  }

  void _dispatchMessage(String data) {
    if (readyState != OPEN) {
      return;
    }
   dispatch(new MessageEvent(data));
  }

  void _dispatchHeartbeat() {
    if (readyState != OPEN) {
        return;
    }
    dispatch("heartbeat");
  }

  void _didMessage(String data) {
    var type = data[0];
    switch(type) {
    case 'o':
        _dispatchOpen();
        break;
    case 'a':
      var s = data.substring(1);
      if (s == null) s = '[]';
      var payload = convert.json.decode(s);
      for(var i=0; i < payload.length; i++){
          _dispatchMessage(payload[i]);
      }
      break;
    case 'm':
      var s = data.substring(1);
      if (s == null) s = 'null';
      var payload = convert.json.decode(s);
      _dispatchMessage(payload);
      break;
    case 'c':
      var s = data.substring(1);
      if (s == null) s = '[]';
      var payload = convert.json.decode(s);
      _didClose(payload[0], payload[1]);
      break;
    case 'h':
      _dispatchHeartbeat();
      break;
    }
  }

  bool _tryNextProtocol([CloseEvent closeEvent]) {
    if (protocol != null) {
        _debug('Closed transport: $protocol $closeEvent');
        protocol = null;
    }
    if (_transportTref != null) {
        _transportTref.cancel();
        _transportTref = null;
    }

    while(true) {

      if (_protocols.isEmpty) {
        return false;
      }

      protocol = _protocols.removeAt(0);

      // Some protocols require access to `body`, what if were in
      // the `head`?
      if (PROTOCOLS.containsKey(protocol) &&
          PROTOCOLS[protocol].needBody &&
          ( (html.document.body == null) || (html.document.readyState != null && html.document.readyState != 'complete'))
          ) {
          _protocols.insert(0, protocol);
          this.protocol = 'waiting-for-load';
          html.document.onLoad.listen( (_) => _tryNextProtocol());
          return true;
      }

      if (!PROTOCOLS.containsKey(protocol) ||
            !PROTOCOLS[protocol].enabled) {
          _debug('Skipping transport: $protocol');
      } else {
          // if roundTrips is passed in, we will use it
          // instead of the defaulted value for the protocol.
          var roundTrips = (this.roundTrips != null && this.roundTrips > 0)
                           ? this.roundTrips
                           : PROTOCOLS[protocol].roundTrips;
          var to = this.timeout;
          if (to == null || to < 1) {
            to = rto * roundTrips;
            if (to == 0) to = 5000;
          }
          _transportTref = new Timer(new Duration(milliseconds:to), () {
              if (readyState == CONNECTING) {
                  // I can't understand how it is possible to run
                  // this timer, when the state is CLOSED, but
                  // apparently in IE everythin is possible.
                  _didClose(2007, "Transport timeouted");
              }
          });

          var connid = utils.random_string(8);
          var trans_url = "$_baseUrl/$server/$connid";
          _debug('Opening transport: $protocol url:$trans_url RTO:$rto roundTrips:$roundTrips timeout:$to');
          _transport = PROTOCOLS[protocol].create(this, trans_url, baseUrl: _baseUrl, noCredentials: noCredentials);
          return true;
      }
    }
  }

  _applyInfo(Info info) {
    this.info = info;
    this.rto = utils.countRTO(rtt);
    final probed = utils.probeProtocols();
    _protocols = utils.detectProtocols(probed, protocolsWhitelist, info);
  }

  _debug(String msg) {
    if (debug) {
       print(msg);
    }
  }

}
