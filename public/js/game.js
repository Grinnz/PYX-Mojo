var ws_url = document.getElementById('ws_url').textContent;
var ws = new WebSocket(ws_url);
ws.onmessage = function (e) {
	var data = JSON.parse(e.data);
	var msg = '';
	var ts = new Date(data.time * 1000).toLocaleTimeString();
	if (data.action === 'chat') {
		msg = data.from + ': ' + data.msg;
	} else if (data.action === 'join') {
		msg = data.from + ' has joined';
	} else if (data.action === 'leave') {
		msg = data.from + ' has left';
	}
	document.getElementById('log').innerHTML += '<p><span>[' + ts + ']</span> ' + msg + '</p>';
};
ws.onclose = function (e) {
	document.getElementById('log').innerHTML += '<p>Connection closed</p>';
};
function sendChat(input) { ws.send(JSON.stringify({'action': 'chat', 'msg': input.value})); input.value = '' }
window.onbeforeunload = function() {
	ws.send(JSON.stringify({'action': 'leave'}));
};
setInterval(function() {
	ws.send(JSON.stringify({'action': 'heartbeat'}));
}, 10000);
