var ws_url = document.getElementById('ws_url').textContent;
var ws = new WebSocket(ws_url);
ws.onmessage = function (e) {
	var data = JSON.parse(e.data);
	var msg = '';
	if (data.action === 'chat') {
		msg = data.from + ': ' + data.msg;
	} else if (data.action === 'join') {
		msg = data.from + ' has joined';
	} else if (data.action === 'leave') {
		msg = data.from + ' has left';
	}
	document.getElementById('log').innerHTML += '<p>' + msg + '</p>';
};
function sendChat(input) { ws.send(JSON.stringify({'action': 'chat', 'msg': input.value})); input.value = '' }
window.onbeforeunload = function() {
	ws.send(JSON.stringify({'action': 'leave'}));
};
setInterval(function() {
	ws.send(JSON.stringify({'action': 'heartbeat'}));
}, 10000);
