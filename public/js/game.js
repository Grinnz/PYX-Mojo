var ws_url = document.getElementById('ws_url').textContent;
var ws = new WebSocket(ws_url);
ws.onmessage = function (e) {
	var data = JSON.parse(e.data);
	switch (data.action) {
	case 'game_state':
		console.log(data.state);
		break;
	case 'card_data':
		console.log(data.cards);
		break;
	case 'chat':
	case 'join':
	case 'leave':
		showChat(data);
		break;
	}
};
ws.onclose = function (e) {
	document.getElementById('log').innerHTML += '<p>Connection closed</p>';
};
function showChat(data) {
	var msg = '';
	switch (data.action) {
	case 'chat':
		msg = data.from + ': ' + data.msg;
		break;
	case 'join':
		msg = data.from + ' has joined';
		break;
	case 'leave':
		msg = data.from + ' has left';
		break;
	}
	var ts = new Date(data.time * 1000).toLocaleTimeString();
	document.getElementById('log').innerHTML += '<p><span>[' + ts + ']</span> ' + msg + '</p>';
}
function sendChat(input) { ws.send(JSON.stringify({'action': 'chat', 'msg': input.value})); input.value = '' }
function startGame(button) { ws.send(JSON.stringify({'action': 'start'})); button.disabled = true; }
window.onbeforeunload = function() {
	ws.send(JSON.stringify({'action': 'leave'}));
};
setInterval(function() {
	ws.send(JSON.stringify({'action': 'heartbeat'}));
}, 10000);
