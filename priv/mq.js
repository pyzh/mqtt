var match, pl = /\+/g, search = /([^&=]+)=?([^&]*)/g,
    decode = function (s) { return decodeURIComponent(s.replace(pl, " ")); },
    query = window.location.search.substring(1);
params = {}; while (match = search.exec(query)) params[decode(match[1])] = decode(match[2]);
l = location.pathname;
x = l.substring(l.lastIndexOf("/") + 1);
module = x.substring(0, x.lastIndexOf("."));
console.log("Room: " + params.room);
var clientId = undefined;
function get_topic(prefix) { return prefix + "/" + rnd() + "/" + module + "/anon/" + clientId; }

var subscribeOptions = {
    qos: 2,  // QoS
    invocationContext: { foo: true },  // Passed to success / failure callback
    onSuccess: function () { console.log("N2O Subscribed");  },
    onFailure: function (m) { console.log("N2O Subscription failed: " + message.errorMessage); },
    timeout: 2 };
var options = {
    timeout: 2,
    onFailure: function (m) { console.log("N2O Connection failed: " + m.errorMessage); },
    onSuccess: function ()  { console.log("N2O Connected");
                mqtt.subscribe('room/'+params.room, subscribeOptions); // index.erl:15 
                            } };
function rnd() { return Math.floor((Math.random() * 16)+1); }
ws = {
    send: function (payload) {
        var message = new Paho.MQTT.Message(payload);
        message.destinationName = get_topic("events");
        message.qos = 2;
        mqtt.send(message); } };

function MQTT_start() {
  mqtt = new Paho.MQTT.Client(host, 8083, '');
  mqtt.onConnectionLost = function (o) { console.log("connection lost: " + o.errorMessage); };
  mqtt.onMessageArrived = function (m) {
        if (undefined == clientId) {
            words = m.destinationName.split("/");
            clientId = words[1];
            ws.send(enc(tuple(atom('init'),bin(''))));
        } 
        var BERT = m.payloadBytes.buffer.slice(m.payloadBytes.byteOffset,
            m.payloadBytes.byteOffset + m.payloadBytes.length);
        try {
            erlang = dec(BERT);
            for (var i = 0; i < $bert.protos.length; i++) {
                p = $bert.protos[i]; if (p.on(erlang, p.do).status == "ok") return;
            }
        } catch (e) { console.log(e); }
        
        
    };

  mqtt.connect(options);
}

MQTT_start();
